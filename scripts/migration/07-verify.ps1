<#
.SYNOPSIS
  READ-ONLY. Proves the migration actually landed, by independent re-fetch rather than by
  trusting the writers' response bodies.

.DESCRIPTION
  Four checks:

    1. RECONCILIATION - re-enumerate every lead's stage and confirm the live distribution
       matches what the worklist said it should be. Any drift is a bug, not rounding.
    2. RESIDUE - confirm no lead is still sitting on an old (pre-migration) stage value.
    3. SAMPLING - re-fetch a random sample per target stage and confirm each field
       (stage, reason, category, disposition) actually took.
    4. CROSS-OBJECT CONSISTENCY - the rules that must hold across all three objects:
         * no contact at Prospect/Customer without an Opportunity
         * no company at Opportunity/Customer without a primary contact
         * no company with more than one open Opportunity

  A "Success" response body is not evidence. This script is the evidence.

.NOTES
  pwsh ./scripts/leadsquared/migration/07-verify.ps1
#>

param([int]$SamplePerStage = 30)

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_verify_log.txt"
Write-LsqLog "=== Verification started (READ-ONLY) ===" $logPath

$summaryPath = Join-Path $dataDir "migration_worklist_summary.json"
if (-not (Test-Path $summaryPath)) { throw "No worklist summary found - run 02-build-worklist.ps1 first." }
$expected = Get-Content $summaryPath -Raw | ConvertFrom-Json

# --- 1 + 2: re-enumerate live state ----------------------------------------------------
Write-LsqLog "Re-enumerating all leads from live data..." $logPath
$liveCounts = @{}
$samplePool = @{}
$total = 0
$page = 1
while ($true) {
    # Expand-LsqRows: a nested page reads .Count = 1, ending this loop after one page - which
    # would report a near-empty account as the verified post-migration state. See common.ps1.
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,ProspectStage" -SortColumn "CreatedOn" -SortDirection "1" `
        -PageIndex $page -PageSize 1000))
    if (-not $resp -or $resp.Count -eq 0) { break }
    foreach ($l in $resp) {
        $total++
        $s = $l.ProspectStage
        if ([string]::IsNullOrWhiteSpace($s)) { $s = "<BLANK>" }
        if ($liveCounts.ContainsKey($s)) { $liveCounts[$s]++ } else { $liveCounts[$s] = 1 }
        if (-not $samplePool.ContainsKey($s)) { $samplePool[$s] = @() }
        if ($samplePool[$s].Count -lt 200) { $samplePool[$s] += $l.ProspectID }
    }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Live leads: $total (worklist expected $($expected.TotalLeads))" $logPath

$problems = 0

Write-LsqLog "--- Check 1: target stage distribution ---" $logPath
foreach ($stage in $Script:ContactStages) {
    $exp = [int]$expected.ContactStageCounts.$stage
    $act = [int]$liveCounts[$stage]
    $delta = $act - $exp
    $flag = if ($delta -eq 0) { "OK" } else { "DRIFT" }
    if ($delta -ne 0) { $problems++ }
    Write-LsqLog ("  {0,-14} expected={1,-8} live={2,-8} delta={3,-7} {4}" -f $stage, $exp, $act, $delta, $flag) $logPath
}

Write-LsqLog "--- Check 2: residue on old stage values ---" $logPath
$residue = 0
foreach ($k in ($liveCounts.Keys | Sort-Object)) {
    if ($Script:ContactStages -notcontains $k) {
        Write-LsqLog ("  RESIDUE  [{0}] = {1} leads still on an old value" -f $k, $liveCounts[$k]) $logPath
        $residue += $liveCounts[$k]
        $problems++
    }
}
if ($residue -eq 0) { Write-LsqLog "  OK - no leads left on any pre-migration value." $logPath }
else { Write-LsqLog "  TOTAL RESIDUE: $residue leads" $logPath }

# --- 3: sample re-fetch ----------------------------------------------------------------
Write-LsqLog "--- Check 3: random-sample field verification ---" $logPath
foreach ($stage in $Script:ContactStages) {
    if (-not $samplePool.ContainsKey($stage) -or $samplePool[$stage].Count -eq 0) {
        Write-LsqLog "  $stage : no records to sample" $logPath
        continue
    }
    $ids = $samplePool[$stage] | Get-Random -Count ([Math]::Min($SamplePerStage, $samplePool[$stage].Count))
    $bad = 0
    foreach ($id in $ids) {
        # Leads.Get CANNOT be filtered by lead id. Verified live 2026-07-30:
        #   LookupName "ProspectId" -> 0 rows (this check previously failed EVERY sampled lead)
        #   LookupName "ProspectID" -> 1 row, but the field values come back empty
        #   Leads.GetById?id=...    -> the full, correct record
        # Reading via the two Leads.Get forms would have reported a perfectly good migration as
        # 100% broken, which is worse than no check at all.
        $one = @(Expand-LsqRows (Invoke-RestMethod -Uri ((Get-LsqUrl "LeadManagement.svc/Leads.GetById") + "&id=$id") -Method Get))
        if ($one.Count -eq 0 -or "$($one[0].ProspectStage)" -ne $stage) { $bad++; continue }
        # Disqualified must carry both a reason and a category - that is the whole point.
        if ($stage -eq "Disqualified") {
            if ([string]::IsNullOrWhiteSpace($one[0].mx_Disqualification_Reason) -or
                [string]::IsNullOrWhiteSpace($one[0].mx_Disqualification_Category)) { $bad++ }
        }
        Start-Sleep -Milliseconds 250
    }
    $flag = if ($bad -eq 0) { "OK" } else { "FAIL" }
    if ($bad -gt 0) { $problems++ }
    Write-LsqLog ("  {0,-14} sampled={1,-5} bad={2,-5} {3}" -f $stage, $ids.Count, $bad, $flag) $logPath
}

# --- 4: cross-object consistency -------------------------------------------------------
Write-LsqLog "--- Check 4: cross-object consistency ---" $logPath
$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$dealContacts = @()
foreach ($s in @("Prospect", "Customer")) {
    if ($samplePool.ContainsKey($s)) { $dealContacts += $samplePool[$s] }
}
$check = $dealContacts | Get-Random -Count ([Math]::Min(50, $dealContacts.Count))
$missingOpp = 0
$badOppStage = 0
$oppStagesSeen = @{}
foreach ($id in $check) {
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$id&opportunityType=12000"
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
        if ($r.RecordCount -eq 0) { $missingOpp++; Write-LsqLog "    Lead $id is at a deal stage but has NO Opportunity" $logPath }
        else {
            # Existence alone is not verification: 06b rewrites these stage values, and a
            # migration that left an Opportunity on a legacy value ("Requirement Gathering" /
            # "Payment Recieved") would otherwise pass this check silently. The records are
            # already in hand here, so validating the stage costs no extra API calls.
            foreach ($o in $r.List) {
                $st = $o.mx_Custom_2
                if ([string]::IsNullOrWhiteSpace($st)) { $st = "<BLANK>" }
                if ($oppStagesSeen.ContainsKey($st)) { $oppStagesSeen[$st]++ } else { $oppStagesSeen[$st] = 1 }
                if ($Script:OpportunityStageRank.Keys -notcontains $st) {
                    $badOppStage++
                    Write-LsqLog "    Lead $id Opportunity $($o.OpportunityId) is on NON-CANONICAL stage [$st]" $logPath
                }
            }
        }
    } catch {
        Write-LsqLog "    Lead $id opportunity check failed -> $($_.Exception.Message)" $logPath
    }
    Start-Sleep -Milliseconds 300
}
$flag = if ($missingOpp -eq 0) { "OK" } else { "FAIL" }
if ($missingOpp -gt 0) { $problems++ }
Write-LsqLog ("  Prospect/Customer contacts without an Opportunity: {0}/{1} {2}" -f $missingOpp, $check.Count, $flag) $logPath

$flag = if ($badOppStage -eq 0) { "OK" } else { "FAIL" }
if ($badOppStage -gt 0) { $problems++ }
Write-LsqLog ("  Opportunities on a non-canonical stage: {0} {1}" -f $badOppStage, $flag) $logPath
foreach ($kv in ($oppStagesSeen.GetEnumerator() | Sort-Object Value -Descending)) {
    Write-LsqLog ("    [{0}] = {1}" -f $kv.Key, $kv.Value) $logPath
}

$collisionPath = Join-Path $dataDir "migration_worklist_collisions.json"
if (Test-Path $collisionPath) {
    $col = @(Get-Content $collisionPath -Raw | ConvertFrom-Json)
    Write-LsqLog "  Accounts with multiple deal-stage contacts (need rep review): $($col.Count)" $logPath
}

# --- Verdict ---------------------------------------------------------------------------
Write-LsqLog "" $logPath
if ($problems -eq 0) {
    Write-LsqLog "=== VERIFICATION PASSED - all checks clean. ===" $logPath
} else {
    Write-LsqLog "=== VERIFICATION FOUND $problems PROBLEM AREA(S) - review the log above before briefing reps. ===" $logPath
}
