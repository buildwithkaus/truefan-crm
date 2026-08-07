<#
.SYNOPSIS
  Creates Opportunities for contacts that are at a deal stage NOW but do not have one.

.DESCRIPTION
  06-create-opportunities.ps1 works from the migration worklist - a snapshot. Contacts have
  moved since (reps working, plus 12-reconcile-contacts.ps1), so contacts sitting at Prospect
  or Customer today may have no Opportunity behind them. STAGE_RESTRUCTURE_PLAN section 2 says
  a Contact at Prospect means a deal exists, so those are inconsistent records.

  Works from live state (the 11-audit snapshot) instead of the worklist.

  Rules applied:
    * Only PRIMARY contacts may own an Opportunity (plan section 3, rule 1). A non-primary
      contact at a deal stage is a data problem, not something to create a second deal for -
      those are reported, never written, because creating one would fragment the account into
      multiple "deals" and inflate pipeline. That is the exact failure rule 6 exists to prevent.
    * Contact Prospect -> Opportunity Open / Prospect.
      Contact Customer -> Opportunity Won / Payment Received.
    * Check-before-create against GetOpportunitiesOfLead: the Capture API reports
      "IsUnique":true even for genuine duplicates, so a blind run double-creates.
    * mx_Custom_1 (Opportunity Name) is MANDATORY and is set to the CompanyName, matching what
      the Phase 3 backfill used.

.PARAMETER Execute
  Required to write. Without it, reports what it would create.

.NOTES
  pwsh ./scripts/leadsquared/migration/14-create-missing-opportunities.ps1
  pwsh ./scripts/leadsquared/migration/14-create-missing-opportunities.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$ThrottleMs = 400
)

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir  = Join-Path $PSScriptRoot "..\..\data"
$logPath  = Join-Path $dataDir "migration_missing_opportunities_log.txt"
$snapPath = Join-Path $dataDir "migration_audit_state.json"
$checkpointPath = Join-Path $dataDir "migration_missing_opp_checkpoint.txt"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Missing Opportunity creation [$mode] ===" $logPath

if (-not (Test-Path $snapPath)) { throw "Snapshot missing: $snapPath - run 11-audit-post-migration.ps1 first." }
$snap = @(Expand-LsqRows (Get-Content $snapPath -Raw | ConvertFrom-Json))
if ($snap.Count -lt 80000) { throw "Snapshot has only $($snap.Count) leads - refusing to run from a truncated snapshot." }

$dealStage = @{ "Prospect" = @{ Status = "Open"; Stage = "Prospect" }
                "Customer" = @{ Status = "Won";  Stage = "Payment Received" } }

$candidates = New-Object System.Collections.Generic.List[object]
$nonPrimaryAtDeal = New-Object System.Collections.Generic.List[object]
foreach ($l in $snap) {
    $s = "$($l.Stage)"
    if (-not $dealStage.ContainsKey($s)) { continue }
    if ($l.IsPrimary) { [void]$candidates.Add($l) } else { [void]$nonPrimaryAtDeal.Add($l) }
}
Write-LsqLog "Contacts at a deal stage: primary=$($candidates.Count)  non-primary=$($nonPrimaryAtDeal.Count)" $logPath
if ($nonPrimaryAtDeal.Count -gt 0) {
    Write-LsqLog "NOTE: non-primary contacts at a deal stage are NOT given an Opportunity (plan rule 1/6)." $logPath
    Write-LsqLog "      They are listed in the log for rep review - add as stakeholder or transfer primary." $logPath
    foreach ($x in ($nonPrimaryAtDeal | Select-Object -First 25)) { Write-LsqLog "      non-primary $($x.ProspectId) stage=$($x.Stage) company=$($x.CompanyId)" $logPath }
}

# Company names for the mandatory Opportunity Name.
$companyNameOf = @{}
$compBackup = @(Get-ChildItem (Join-Path $dataDir "migration_BACKUP_companies_*.json") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($compBackup.Count -eq 0) { throw "No company backup found - needed for the mandatory Opportunity Name." }
foreach ($c in @(Expand-LsqRows (Get-Content $compBackup[0].FullName -Raw | ConvertFrom-Json))) {
    $cid = "$($c.CompanyId)"
    if ($cid) { $companyNameOf[$cid] = "$($c.CompanyName)" }
}
Write-LsqLog "Company names available: $($companyNameOf.Count)" $logPath

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$startIdx = 0
if ($Execute -and (Test-Path $checkpointPath)) {
    $startIdx = [int](Get-Content $checkpointPath -Raw).Trim()
    Write-LsqLog "Resuming from index $startIdx." $logPath
}

$has = 0; $missing = 0; $created = 0; $failed = 0; $noName = 0; $readFail = 0
$toCreate = New-Object System.Collections.Generic.List[object]

for ($i = $startIdx; $i -lt $candidates.Count; $i++) {
    $l = $candidates[$i]
    $id = "$($l.ProspectId)"
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$id&opportunityType=12000"
    try {
        $r = Invoke-LsqWithRetry -What "opps for $id" -Action {
            Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -ErrorAction Stop
        }
        if ($r.RecordCount -gt 0) { $has++ }
        else {
            $missing++
            [void]$toCreate.Add($l)
        }
    } catch {
        $readFail++
        Write-LsqLog "Lead $id : opportunity read failed -> $($_.Exception.Message)" $logPath
    }
    if ($i % 100 -eq 0) { Write-LsqLog "Checked $i/$($candidates.Count) has=$has missing=$missing readFail=$readFail" $logPath }
    Start-Sleep -Milliseconds 250
}

Write-LsqLog "" $logPath
Write-LsqLog "Primary contacts WITH an Opportunity   : $has" $logPath
Write-LsqLog "Primary contacts WITHOUT an Opportunity: $missing" $logPath
Write-LsqLog "Opportunity reads that failed          : $readFail" $logPath
$byStage = $toCreate | Group-Object Stage
foreach ($g in $byStage) { Write-LsqLog ("   would create for contact stage {0,-12} {1}" -f $g.Name, $g.Count) $logPath }

if (-not $Execute) { Write-LsqLog "REPORT ONLY - nothing written. Re-run with -Execute." $logPath; return }
if ($toCreate.Count -eq 0) { Write-LsqLog "Nothing to create." $logPath; return }

$captureUrl = "$base/OpportunityManagement.svc/Capture?accessKey=$ak&secretKey=$sk"
$j = 0
foreach ($l in $toCreate) {
    $j++
    $id = "$($l.ProspectId)"
    $cname = ""
    if ($companyNameOf.ContainsKey("$($l.CompanyId)")) { $cname = $companyNameOf["$($l.CompanyId)"] }
    if ([string]::IsNullOrWhiteSpace($cname)) {
        $noName++
        Write-LsqLog "Lead $id : no CompanyName for $($l.CompanyId) - skipped (Opportunity Name is mandatory)" $logPath
        continue
    }
    $d = $dealStage["$($l.Stage)"]
    $body = @{
        LeadDetails = @(
            @{ Attribute = "ProspectID";             Value = $id },
            @{ Attribute = "SearchBy";               Value = "ProspectId" },
            @{ Attribute = "__UseUserDefinedGuid__"; Value = "true" }
        )
        Opportunity = @{
            OpportunityEventCode       = 12000
            OpportunityNote            = "Created by post-migration reconciliation"
            UpdateEmptyFields          = $true
            DoNotPostDuplicateActivity = $false
            DoNotChangeOwner           = $false
            Fields = @(
                @{ SchemaName = "Status";      Value = $d.Status },
                @{ SchemaName = "mx_Custom_1"; Value = $cname },
                @{ SchemaName = "mx_Custom_2"; Value = $d.Stage }
            )
        }
    } | ConvertTo-Json -Depth 8
    try {
        $r = Invoke-LsqPost -Uri $captureUrl -JsonBody $body
        if ($r.CreatedOpportunityId) { $created++ }
        else { $failed++; Write-LsqLog "Lead $id : Opportunity FAILURE -> $($r | ConvertTo-Json -Compress -Depth 3)" $logPath }
    } catch {
        $failed++
        Write-LsqLog "Lead $id : Opportunity EXCEPTION -> $($_.Exception.Message)" $logPath
    }
    if ($j % 50 -eq 0) { Write-LsqLog "Created $created / attempted $j (failed=$failed)" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "DONE. created=$created failed=$failed noName=$noName of $($toCreate.Count) needed." $logPath
if ($failed -eq 0) { Remove-Item $checkpointPath -ErrorAction SilentlyContinue }
Write-LsqLog "=== Missing Opportunity creation complete [$mode] ===" $logPath
