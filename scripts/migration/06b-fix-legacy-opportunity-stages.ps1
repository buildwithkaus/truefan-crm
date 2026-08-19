<#
.SYNOPSIS
  DONE 2026-07-29 (4,404 records). DO NOT RE-RUN - see the WARNING below.

  Moves EXISTING Opportunities off the two stage values the Phase 3 backfill hardcoded
  ("Requirement Gathering", "Payment Recieved") onto the new canonical values ("Prospect",
  "Payment Received"), by direct write - because the UI rename cannot do this.

.WARNING
  RE-RUNNING THIS SCRIPT TODAY WOULD DESTROY THE WARM PIPELINE.

  Its $LegacyMap rewrites "Requirement Gathering" -> "Prospect". That was correct on
  2026-07-29, when every Opportunity in the account sat on that value because Phase 3 had
  hardcoded it. It is WRONG now: "Requirement Gathering" has since been re-established as a
  real, current, WARM stage on the Opportunity object, ranked between Prospect and In
  Discussion (gotcha 26, and $Script:OpportunityStageRank in scripts/lib/schema.ps1).

  There are ~90 live deals on it. Re-running this would silently demote every one of them to
  the first stage and erase the distinction between "we are gathering requirements" and "we
  have not spoken yet" - unrecoverably, since the previous value is not stored anywhere.

  The "Payment Recieved" -> "Payment Received" half is still valid; 2 records remain on the
  typo. If you need only that, run with -Execute -TypoOnly.

  Guarded by -IAcceptTheRequirementGatheringRisk since 2026-08-14.

.DESCRIPTION
  MANUAL_STEPS.md step 4 assumed renaming the live Opportunity Stage dropdown would carry
  every existing Opportunity across for free (STAGE_RESTRUCTURE_PLAN.md section 7.1). That
  assumption was wrong for exactly the two values that matter most: LSQ refuses to rename or
  delete a dropdown option that is currently in use ("This option is currently in use and
  can't be deleted"). A live sample taken 2026-07-29 (37/37 Opportunities checked) showed the
  ENTIRE existing Opportunity population sitting on "Requirement Gathering" (Open) or
  "Payment Recieved" (Won) - both are exactly what apply-opportunity-backfill.ps1 hardcoded
  when it created all 4,404 Opportunities during Phase 3. So the two blocked values are not
  an edge case; they are most/all of the population, and 06-create-opportunities.ps1 (which
  only CREATES new Opportunities) never touches them.

  This script finds every Opportunity still on one of the two legacy values and rewrites
  mx_Custom_2 directly via OpportunityManagement.svc/Update (Status is left untouched - Open
  stays Open, Won stays Won, only the Stage label changes). Once this has run and nothing
  references the legacy values anymore, they can optionally be deleted from the dropdown in
  the UI (not required - CLAUDE.md's "don't delete until migration verified" applies here
  too).

  Candidates are every Lead with IsPrimaryContact=1 (mirrors the approach 03-backup.ps1 uses
  for Opportunity enumeration - there is no bulk Opportunity read endpoint, so this is one
  GetOpportunitiesOfLead call per candidate).

  Idempotent and resumable via a checkpoint file. Records already on a canonical value are
  skipped for free on every re-run.

.PARAMETER Execute
  Required to write. Without it, reports what it would change.

.NOTES
  pwsh ./scripts/leadsquared/migration/06b-fix-legacy-opportunity-stages.ps1            # dry run
  pwsh ./scripts/leadsquared/migration/06b-fix-legacy-opportunity-stages.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$ThrottleMs = 400,

    # Rewrite ONLY the "Payment Recieved" typo, leaving "Requirement Gathering" alone. This is
    # the only half of this script that is still safe to run.
    [switch]$TypoOnly,

    # Required to run the "Requirement Gathering" -> "Prospect" half. Read the WARNING above
    # before passing it: there is no undo.
    [switch]$IAcceptTheRequirementGatheringRisk
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_legacy_opportunity_stages_log.txt"
$checkpointPath = Join-Path $dataDir "migration_legacy_opportunity_stages_checkpoint.txt"
$worklistPath = Join-Path $dataDir "migration_worklist_legacy_opportunity_stages.json"

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "=== Fix legacy Opportunity stage values [$mode] ===" $logPath

# The two values Phase 3 hardcoded, and where they go. Status is unchanged in both cases -
# only the mx_Custom_2 label moves.
#
# The "Requirement Gathering" entry is now DANGEROUS and is gated. See the WARNING in the
# header: that value is a live warm stage today, not a legacy artifact, and rewriting it
# demotes ~90 real deals with no way back.
$LegacyMap = @{
    "Requirement Gathering" = "Prospect"
    "Payment Recieved"      = "Payment Received"
}

if ($TypoOnly) {
    $LegacyMap.Remove("Requirement Gathering")
    Write-LsqLog "TYPO-ONLY MODE: 'Requirement Gathering' excluded; only the 'Payment Recieved' typo will be rewritten." $logPath
} elseif (-not $IAcceptTheRequirementGatheringRisk) {
    throw @"
REFUSING TO RUN. This script's mapping rewrites 'Requirement Gathering' -> 'Prospect'.

That was correct on 2026-07-29. It is wrong now: 'Requirement Gathering' is a live WARM stage
on the Opportunity object (~90 deals, gotcha 26), not a legacy value, and this rewrite would
demote every one of them to the first stage with no undo.

  -TypoOnly                             fix only the 'Payment Recieved' typo (safe)
  -IAcceptTheRequirementGatheringRisk   run the full original mapping anyway
"@
}

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# ---------------------------------------------------------------------------------------
# Build (or reuse) the worklist - enumerate every primary-contact lead's Opportunities and
# keep the ones sitting on a legacy value. Read-only.
# ---------------------------------------------------------------------------------------
if (Test-Path $worklistPath) {
    Write-LsqLog "Reusing existing worklist at $worklistPath (delete it to force a fresh enumeration)." $logPath
    # Expand-LsqRows + shape assert: if this ever collapses to a single nested row, the write
    # loop below would run ONCE with $row holding the whole array, build one malformed body, and
    # report "DONE ok=0 fail=1 of 1" as though it had processed everything. Cheap to assert.
    $work = @(Expand-LsqRows (Get-Content $worklistPath -Raw | ConvertFrom-Json))
    $badRows = @($work | Where-Object { [string]::IsNullOrWhiteSpace($_.OpportunityId) -or @($_.OpportunityId).Count -ne 1 })
    if ($badRows.Count -gt 0) {
        throw "Worklist at $worklistPath did not load as flat single-value rows ($($badRows.Count) bad of $($work.Count)). Refusing to write from a malformed worklist - delete the file and re-run the scan."
    }
    Write-LsqLog "Worklist loaded: $($work.Count) rows." $logPath
} else {
    # Candidates are the IsPrimaryContact=1 leads, fetched with a SERVER-SIDE filter (5 pages
    # instead of 87). An earlier session distrusted this filter because it appeared to stop at
    # a suspiciously round ~1000 - that was the Expand-LsqRows nesting bug (CLAUDE.md eighth
    # gotcha), not the filter. With the shape normalised it paginates cleanly to 4,404.
    #
    # CLAUDE.md's #1 rule is that a filter can be silently ignored and a zero/short result must
    # be distrusted, so this does not take the count on faith. It proves three things every run:
    #   1. negative control - a value that must match nothing actually returns nothing (if the
    #      filter were ignored we would get unfiltered rows here, not zero);
    #   2. every returned row really is a primary contact (filter honoured, not ignored);
    #   3. no duplicate ProspectIDs across pages (paging advanced rather than repeating).
    # Plus an absolute floor: the Phase 3 backfill created 4,404 Opportunities against 4,404
    # primary contacts, so a materially smaller number means an incomplete read, not real data.
    Write-LsqLog "Negative control: IsPrimaryContact=9 must return 0 rows..." $logPath
    $negControl = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName = "IsPrimaryContact"; LookupValue = "9"; SqlOperator = "=" } `
        -ColumnsCsv "ProspectID,IsPrimaryContact" -PageIndex 1 -PageSize 1000))
    if ($negControl.Count -ne 0) {
        throw "Negative control FAILED: IsPrimaryContact=9 returned $($negControl.Count) rows instead of 0. The server-side filter is being ignored, so an IsPrimaryContact=1 result cannot be trusted either. Refusing to build a worklist."
    }
    Write-LsqLog "  negative control OK (0 rows)." $logPath

    $MinExpectedPrimaryContacts = 4000
    $candidates = @()
    $notPrimary = 0
    $page = 1
    Write-LsqLog "Enumerating primary contacts (server-side IsPrimaryContact=1)..." $logPath
    while ($true) {
        $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName = "IsPrimaryContact"; LookupValue = "1"; SqlOperator = "=" } `
            -ColumnsCsv "ProspectID,IsPrimaryContact" -PageIndex $page -PageSize 1000))
        if ($resp.Count -eq 0) { break }
        foreach ($l in $resp) {
            if (-not (Test-LsqTrue $l.IsPrimaryContact)) { $notPrimary++ }
            $candidates += $l.ProspectID
        }
        Write-LsqLog "  page $page -> $($resp.Count) rows (running total $($candidates.Count))" $logPath
        if ($resp.Count -lt 1000) { break }
        $page++
        Start-Sleep -Milliseconds 250
    }

    if ($notPrimary -gt 0) {
        throw "Server-side filter returned $notPrimary row(s) that are NOT primary contacts - the filter was ignored. Refusing to build a worklist from an unfiltered read."
    }
    $distinctCandidates = @($candidates | Select-Object -Unique)
    if ($distinctCandidates.Count -ne $candidates.Count) {
        throw "Pagination returned duplicate ProspectIDs ($($candidates.Count) rows, $($distinctCandidates.Count) distinct) - paging repeated a page instead of advancing. Refusing to build a worklist."
    }
    if ($candidates.Count -lt $MinExpectedPrimaryContacts) {
        throw "Only $($candidates.Count) primary contacts found, expected ~4404 (Phase 3 created 4,404 Opportunities against them). Refusing to build a worklist from an incomplete scan - do not trust '0 Opportunities need a fix' as a real result."
    }
    Write-LsqLog "Primary-contact leads found: $($candidates.Count) (all verified primary, no duplicates)" $logPath

    $work = @()
    $i = 0
    $otherValues = @{}
    foreach ($leadId in $candidates) {
        $i++
        $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$leadId&opportunityType=12000"
        try {
            $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
            if ($r.RecordCount -gt 0) {
                foreach ($o in $r.List) {
                    $stage = $o.mx_Custom_2
                    if ($LegacyMap.ContainsKey($stage)) {
                        $work += [pscustomobject]@{
                            ProspectId    = $leadId
                            OpportunityId = $o.OpportunityId
                            OldStage      = $stage
                            NewStage      = $LegacyMap[$stage]
                        }
                    } elseif ($Script:OpportunityStageRank.Keys -notcontains $stage) {
                        # Anything not in the canonical set AND not one of the two known legacy
                        # values is an unmapped value we have not accounted for - surface it
                        # loudly rather than silently skip it (the exact failure CLAUDE.md warns
                        # about: a value nobody wrote a rule for should not disappear quietly).
                        if (-not $otherValues.ContainsKey($stage)) { $otherValues[$stage] = 0 }
                        $otherValues[$stage]++
                    }
                }
            }
        } catch {
            Write-LsqLog "Lead $leadId : Opportunity read EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
        }
        if ($i % 200 -eq 0) { Write-LsqLog "Scanned $i/$($candidates.Count) leads, found $($work.Count) legacy-stage Opportunities so far" $logPath }
        Start-Sleep -Milliseconds $ThrottleMs
    }

    if ($otherValues.Count -gt 0) {
        Write-LsqLog "WARNING - Opportunity stage values found that are neither legacy nor canonical:" $logPath
        foreach ($kv in $otherValues.GetEnumerator()) { Write-LsqLog "  [$($kv.Key)] : $($kv.Value)" $logPath }
        Write-LsqLog "These need a human decision before this script's mapping can be called complete." $logPath
    }

    $work | ConvertTo-Json -Depth 4 | Set-Content -Path $worklistPath
    Write-LsqLog "Worklist built: $($work.Count) Opportunities need a stage fix. Saved to $worklistPath" $logPath
}

$dist = $work | Group-Object OldStage | Sort-Object Count -Descending
Write-LsqLog "--- Legacy stage distribution ---" $logPath
foreach ($g in $dist) { Write-LsqLog ("  {0,-24} {1}" -f $g.Name, $g.Count) $logPath }

if (-not $Execute) {
    Write-LsqLog "DRY RUN complete - nothing written. Re-run with -Execute." $logPath
    return
}

# ---------------------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------------------
$startIdx = 0
if (Test-Path $checkpointPath) {
    $startIdx = [int](Get-Content $checkpointPath -Raw).Trim()
    Write-LsqLog "Resuming from index $startIdx (checkpoint found)." $logPath
}

$updateUrl = "$base/OpportunityManagement.svc/Update?accessKey=$ak&secretKey=$sk"
$okCount = 0; $failCount = 0

for ($i = $startIdx; $i -lt $work.Count; $i++) {
    $row = $work[$i]

    # Confirmed shape via apidocs.leadsquared.com/update-an-opportunity/ (2026-07-29) - NOT
    # the {Opportunity:{...}, LeadDetails:[...]} shape test-automations-live.ps1 guessed,
    # which throws ArgumentNullException("source") on every call because it was never run
    # live (the automations it tests have not been built yet). The real endpoint is flat:
    # ProspectOpportunityId + a Fields array, no wrapper object.
    $body = @{
        ProspectOpportunityId = $row.OpportunityId
        OpportunityNote       = "Stage restructure: legacy value cleanup ($($row.OldStage) -> $($row.NewStage))"
        Fields = @(
            @{ SchemaName = "mx_Custom_2"; Value = $row.NewStage }
        )
    } | ConvertTo-Json -Depth 5

    try {
        $r = Invoke-LsqPost -Uri $updateUrl -JsonBody $body
        if ($r.Status -eq "Success") { $okCount++ }
        else { $failCount++; Write-LsqLog "Opportunity $($row.OpportunityId) FAILURE -> $($r | ConvertTo-Json -Compress)" $logPath }
    } catch {
        $failCount++
        Write-LsqLog "Opportunity $($row.OpportunityId) EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }

    Set-Content -Path $checkpointPath -Value ($i + 1)
    if ($i % 200 -eq 0) { Write-LsqLog "Progress: $i/$($work.Count) ok=$okCount fail=$failCount" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Legacy Opportunity stage fix DONE. ok=$okCount fail=$failCount of $($work.Count)." $logPath
if ($failCount -eq 0) {
    Remove-Item $checkpointPath -ErrorAction SilentlyContinue
    Write-LsqLog "Checkpoint cleared (clean run)." $logPath
} else {
    Write-LsqLog "Checkpoint retained - re-run to retry failures." $logPath
}
Write-LsqLog "=== Fix legacy Opportunity stage values complete [$mode] ===" $logPath
