<#
.SYNOPSIS
  READ-ONLY. Enumerates every lead in the live account, maps each to its new contact stage,
  rolls those up to a company stage via the primary-contact rule, and writes three worklists
  for the writer scripts to consume. Performs NO writes.

.DESCRIPTION
  This is the step that makes the migration safe. It:

    1. Paginates ALL leads and tallies the ProspectStage values actually stored (never
       probes a guessed list - see CLAUDE.md, 20,076 leads were once silently skipped
       exactly that way).
    2. ABORTS if any live value has no entry in $StageMap. An unmapped or newly-added
       dropdown value halts the migration rather than being dropped.
    3. Reconciles: sum of per-value counts must equal the total lead count.
    4. Resolves the two "infer" values (SaaS, FB Lead - Website) from activity history,
       using the same rule the live system will use going forward: any activity at all
       means Engaged, none means Fresh.
    5. Applies the primary-contact rule to derive each company's stage.
    6. Detects collisions (several contacts at one account landing on Prospect) and picks
       one primary by most-recent activity, flagging the rest for rep review.

  Outputs to data/:
    migration_worklist_leads.json          - per-lead target stage + reason/disposition/segment
    migration_worklist_companies.json      - per-company target stage + reason
    migration_worklist_opportunities.json  - opportunities to create
    migration_worklist_collisions.json     - accounts needing a human decision
    migration_worklist_summary.json        - counts, for the verify step to check against

.NOTES
  Run from repo root:  pwsh ./scripts/leadsquared/migration/02-build-worklist.ps1
  Takes a few minutes (~87 pages of 1,000 leads). Safe to run any time, including in
  business hours - it only reads.
#>

. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_worklist_log.txt"

Write-LsqLog "=== Worklist build started (READ-ONLY) ===" $logPath

# ---------------------------------------------------------------------------------------
# Step 1: enumerate every lead
# ---------------------------------------------------------------------------------------

# List, not @(). PowerShell arrays are immutable: "$arr += x" reallocates and copies the ENTIRE
# array every time, so appending 86,628 leads one at a time is O(n^2) and costs many minutes of
# pure CPU with the API sitting idle. List[object].Add() is amortised O(1).
$leads = New-Object System.Collections.Generic.List[object]
$valueCounts = @{}
$page = 1
$total = 0

Write-LsqLog "Paginating all leads..." $logPath
while ($true) {
    # Expand-LsqRows: a nested page reads .Count = 1, ending this loop after one page and
    # producing a worklist covering a single lead - which the whole migration then runs from.
    # See common.ps1.
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,ProspectStage,RelatedCompanyId,OwnerId,OwnerIdName,IsPrimaryContact,ProspectActivityDate_Max" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if (-not $resp -or $resp.Count -eq 0) { break }

    foreach ($l in $resp) {
        $total++
        $stage = $l.ProspectStage
        if ([string]::IsNullOrWhiteSpace($stage)) { $stage = "<BLANK>" }
        if ($valueCounts.ContainsKey($stage)) { $valueCounts[$stage]++ } else { $valueCounts[$stage] = 1 }

        [void]$leads.Add([pscustomobject]@{
            ProspectId       = $l.ProspectID
            OldStage         = $stage
            CompanyId        = $l.RelatedCompanyId
            OwnerId          = $l.OwnerId
            OwnerName        = $l.OwnerIdName
            # Returns the STRING "1"/"0" - see Test-LsqTrue in common.ps1. Comparing against
            # $true/"true" here would mark all 4,404 real primary contacts as non-primary.
            IsPrimaryContact = (Test-LsqTrue $l.IsPrimaryContact)
            LastActivity     = $l.ProspectActivityDate_Max
        })
    }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}

Write-LsqLog "Total leads enumerated: $total" $logPath
Write-LsqLog "Distinct ProspectStage values found: $($valueCounts.Count)" $logPath

# ---------------------------------------------------------------------------------------
# Step 2: reconcile, then assert the map covers every live value. ABORT if not.
# ---------------------------------------------------------------------------------------

# Absolute-size guard FIRST. The $sum -eq $total check below only proves internal consistency,
# which a truncated scan passes trivially (1 == 1) - it cannot tell a complete enumeration from
# a one-page one. memory/01 puts the account at 86,628 leads (2026-07-28).
$MinExpectedLeads = 80000
if ($total -lt $MinExpectedLeads) {
    Write-LsqLog "FATAL: only $total leads enumerated, expected ~86628." $logPath
    throw "Lead enumeration returned $total leads, far short of the ~86628 in the account. Refusing to build a migration worklist from an incomplete scan. Re-run; if it repeats, stop and investigate before migrating."
}

$sum = 0
foreach ($k in $valueCounts.Keys) { $sum += $valueCounts[$k] }
if ($sum -ne $total) {
    Write-LsqLog "FATAL: reconciliation failed - value counts sum to $sum but $total leads were read." $logPath
    throw "Reconciliation failed. Do not proceed."
}
Write-LsqLog "Reconciliation OK: $sum == $total" $logPath

foreach ($k in ($valueCounts.Keys | Sort-Object)) {
    Write-LsqLog ("  [{0}] = {1}" -f $k, $valueCounts[$k]) $logPath
}

$unmapped = Test-StageMapCompleteness -LiveValues ([string[]]$valueCounts.Keys)
if ($unmapped.Count -gt 0) {
    Write-LsqLog "FATAL: $($unmapped.Count) live ProspectStage value(s) have NO mapping in 00-schema.ps1:" $logPath
    foreach ($u in $unmapped) { Write-LsqLog "    UNMAPPED -> [$u]  ($($valueCounts[$u]) leads)" $logPath }
    throw "Unmapped stage values found. Add them to `$StageMap in 00-schema.ps1 and re-run. Refusing to migrate a partial worklist."
}
Write-LsqLog "Map completeness OK - every live value has a mapping." $logPath

# ---------------------------------------------------------------------------------------
# Step 3: resolve each lead's target stage
# ---------------------------------------------------------------------------------------

$leadWork = New-Object System.Collections.Generic.List[object]   # see the $leads note above
foreach ($lead in $leads) {
    $m = Get-StageMapping -OldValue $lead.OldStage
    $contact = $null; $company = $null; $oppStage = $null

    if ($m.Infer) {
        # Same rule the live system uses going forward: any activity at all means the
        # contact has been touched, so Engaged; otherwise Fresh.
        if (-not [string]::IsNullOrWhiteSpace($lead.LastActivity)) {
            $contact = "Engaged"; $company = "Nurture"
        } else {
            $contact = "Fresh"; $company = "Fresh"
        }
    } else {
        $contact = $m.Contact
        $company = $m.Company
        $oppStage = $m.OppStage
    }

    [void]$leadWork.Add([pscustomobject]@{
        ProspectId             = $lead.ProspectId
        CompanyId              = $lead.CompanyId
        OwnerId                = $lead.OwnerId
        OwnerName              = $lead.OwnerName
        OldStage               = $lead.OldStage
        NewContactStage        = $contact
        TargetCompanyStage     = $company
        OppStage               = $oppStage
        Reason                 = $m.Reason
        Category               = $m.Category
        Disposition            = $m.Disposition
        Segment                = $m.Segment
        NeedsContactResourcing = [bool]$m.NeedsContactResourcing
        IsPrimaryContact       = $lead.IsPrimaryContact
        LastActivity           = $lead.LastActivity
    })
}

$byNew = $leadWork | Group-Object NewContactStage | Sort-Object Count -Descending
Write-LsqLog "--- Target contact stage distribution ---" $logPath
foreach ($g in $byNew) { Write-LsqLog ("  {0,-14} {1}" -f $g.Name, $g.Count) $logPath }

# ---------------------------------------------------------------------------------------
# Step 4: roll up to company stage via the primary-contact rule
# ---------------------------------------------------------------------------------------

# Rank for the no-primary-contact fallback: the company reflects its furthest-along contact.
# Fresh outranks Future Prospect deliberately - an account with one un-worked contact and one
# disqualified contact is still workable, not written off.
$companyRank = @{ "Customer" = 5; "Opportunity" = 4; "Nurture" = 3; "Fresh" = 2; "Future Prospect" = 1 }

$noCompany = ($leadWork | Where-Object { [string]::IsNullOrWhiteSpace($_.CompanyId) }).Count
Write-LsqLog "Leads with no RelatedCompanyId (cannot drive a company stage): $noCompany" $logPath

# Lists, not @() - $companyWork alone appends ~71,467 times. See the $leads note above.
$companyWork = New-Object System.Collections.Generic.List[object]
$oppWork     = New-Object System.Collections.Generic.List[object]
$collisions  = New-Object System.Collections.Generic.List[object]

$grouped = $leadWork | Where-Object { -not [string]::IsNullOrWhiteSpace($_.CompanyId) } | Group-Object CompanyId
Write-LsqLog "Distinct companies represented: $($grouped.Count)" $logPath

foreach ($g in $grouped) {
    $members = $g.Group
    $prospects = @($members | Where-Object { $_.NewContactStage -eq "Prospect" -or $_.NewContactStage -eq "Customer" })

    # Choose the primary contact. Prefer an existing IsPrimaryContact flag that is also a
    # deal-stage contact; otherwise the deal-stage contact with the most recent activity.
    $primary = $null
    if ($prospects.Count -gt 0) {
        $flagged = @($prospects | Where-Object { $_.IsPrimaryContact })
        if ($flagged.Count -ge 1) {
            $primary = $flagged | Sort-Object LastActivity -Descending | Select-Object -First 1
        } else {
            $primary = $prospects | Sort-Object LastActivity -Descending | Select-Object -First 1
        }

        if ($prospects.Count -gt 1) {
            [void]$collisions.Add([pscustomobject]@{
                CompanyId       = $g.Name
                ChosenPrimary   = $primary.ProspectId
                OtherProspects  = @($prospects | Where-Object { $_.ProspectId -ne $primary.ProspectId } | ForEach-Object { $_.ProspectId })
                Count           = $prospects.Count
                Note            = "Several contacts at this account map to a deal stage. One opportunity created on the chosen primary; the others are flagged for rep review (add as stakeholder or transfer primary)."
            })
        }
    }

    if ($primary) {
        $targetStage = $primary.TargetCompanyStage
        $reason = $primary.Reason
        $category = $primary.Category
    } else {
        # No deal-stage contact: company reflects its furthest-along contact.
        $best = $members | Sort-Object { $companyRank[$_.TargetCompanyStage] } -Descending | Select-Object -First 1
        $targetStage = $best.TargetCompanyStage
        $reason = $best.Reason
        $category = $best.Category
    }

    $needsResourcing = ($members | Where-Object { $_.NeedsContactResourcing }).Count -gt 0 -and $targetStage -eq "Nurture"

    [void]$companyWork.Add([pscustomobject]@{
        CompanyId              = $g.Name
        NewStage               = $targetStage
        FutureProspectReason   = if ($targetStage -eq "Future Prospect") { $category } else { $null }
        FutureProspectDetail   = if ($targetStage -eq "Future Prospect") { $reason } else { $null }
        NeedsContactResourcing = $needsResourcing
        PrimaryContactId       = if ($primary) { $primary.ProspectId } else { $null }
        ContactCount           = $members.Count
    })

    # One opportunity per account, on the primary contact only.
    if ($primary -and $primary.OppStage) {
        [void]$oppWork.Add([pscustomobject]@{
            CompanyId  = $g.Name
            ProspectId = $primary.ProspectId
            OwnerId    = $primary.OwnerId
            OppStage   = $primary.OppStage
            Status     = if ($primary.OppStage -in @("Payment Received", "Customer")) { "Won" } else { "Open" }
        })
    }
}

$byCompanyStage = $companyWork | Group-Object NewStage | Sort-Object Count -Descending
Write-LsqLog "--- Target company stage distribution ---" $logPath
foreach ($g in $byCompanyStage) { Write-LsqLog ("  {0,-18} {1}" -f $g.Name, $g.Count) $logPath }
Write-LsqLog "Opportunities to create (pre-dedupe): $($oppWork.Count)" $logPath
Write-LsqLog "Collision accounts needing rep review: $($collisions.Count)" $logPath

# ---------------------------------------------------------------------------------------
# Step 5: write worklists
# ---------------------------------------------------------------------------------------

$summary = [pscustomobject]@{
    BuiltAt                = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    TotalLeads             = $total
    DistinctOldValues      = $valueCounts.Count
    OldValueCounts         = $valueCounts
    ContactStageCounts     = @{}
    CompanyStageCounts     = @{}
    LeadsWithoutCompany    = $noCompany
    CompaniesRepresented   = $grouped.Count
    OpportunitiesToCreate  = $oppWork.Count
    CollisionAccounts      = $collisions.Count
}
foreach ($g in $byNew) { $summary.ContactStageCounts[$g.Name] = $g.Count }
foreach ($g in $byCompanyStage) { $summary.CompanyStageCounts[$g.Name] = $g.Count }

$leadWork    | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dataDir "migration_worklist_leads.json")
$companyWork | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dataDir "migration_worklist_companies.json")
$oppWork     | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dataDir "migration_worklist_opportunities.json")
$collisions  | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dataDir "migration_worklist_collisions.json")
$summary     | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dataDir "migration_worklist_summary.json")

Write-LsqLog "Worklists written to $dataDir" $logPath
Write-LsqLog "=== Worklist build complete. NOTHING WAS WRITTEN to LeadSquared. ===" $logPath
Write-LsqLog "Review migration_worklist_summary.json and _collisions.json before running any writer." $logPath
