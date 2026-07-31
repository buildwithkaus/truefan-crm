<#
.SYNOPSIS
  Finds leads that should carry a Previous Contact Stage but came back empty, and writes them.

.DESCRIPTION
  10-apply-previous-stage.ps1 advances its checkpoint even when a batch fails, so a re-run
  resumes PAST the failure rather than retrying it. On 2026-07-31 batch 2731 failed with a DNS
  error (the machine had just woken from sleep and the network was not up yet), stranding 25
  leads - 0.03% of 87,038.

  Re-running the whole backfill to recover 25 records would cost an hour. This works from LIVE
  state instead: read the field for every lead in the worklist, keep the ones that are empty
  but should have a value, and write only those. Idempotent, and it catches any gap - not just
  the one we know about.

.PARAMETER Execute
  Required to write. Without it, reports the gap count only.

.NOTES
  pwsh ./scripts/leadsquared/migration/10b-fill-previous-stage-gaps.ps1
  pwsh ./scripts/leadsquared/migration/10b-fill-previous-stage-gaps.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100,
    [string]$SchemaName = "mx_Previous_Contact_Stage"
)

. "$PSScriptRoot\..\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_previous_stage_log.txt"
$workPath = Join-Path $dataDir "migration_worklist_previous_stage.json"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Previous Stage gap fill [$mode] ===" $logPath

if (-not (Test-Path $workPath)) { throw "Missing $workPath - run 09-build-previous-stage-map.ps1 first." }
$work = @(Expand-LsqRows (Get-Content $workPath -Raw | ConvertFrom-Json))
$want = @{}
foreach ($w in $work) {
    $id = "$($w.ProspectId)"
    if ($id -and -not $want.ContainsKey($id)) { $want[$id] = "$($w.PreviousStage)" }
}
Write-LsqLog "Leads that should carry a previous stage: $($want.Count)" $logPath

# Read live state for the field across the whole account.
$MinExpectedLeads = 80000
$live = @{}
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,$SchemaName" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { $live["$($l.ProspectID)"] = "$($l.$SchemaName)" }
    if ($page % 20 -eq 0) { Write-LsqLog "  scanned $($live.Count) leads..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Live leads read: $($live.Count)" $logPath
if ($live.Count -lt $MinExpectedLeads) {
    throw "Read only $($live.Count) leads, expected ~87,000. Refusing to judge gaps from an incomplete scan - it would invent thousands of false gaps and rewrite them."
}

$gaps = New-Object System.Collections.Generic.List[object]
$notInLive = 0
foreach ($id in $want.Keys) {
    if (-not $live.ContainsKey($id)) { $notInLive++; continue }
    if ([string]::IsNullOrWhiteSpace($live[$id])) {
        [void]$gaps.Add([pscustomobject]@{ ProspectId = $id; PreviousStage = $want[$id] })
    }
}
Write-LsqLog "Leads in the worklist but no longer in the account: $notInLive" $logPath
Write-LsqLog "GAPS (should have a previous stage, but field is empty): $($gaps.Count)" $logPath

if ($gaps.Count -eq 0) {
    Write-LsqLog "No gaps - every lead carries its previous stage." $logPath
    Write-LsqLog "=== Gap fill complete [$mode] ===" $logPath
    return
}

if (-not $Execute) {
    $dist = $gaps | Group-Object PreviousStage | Sort-Object Count -Descending
    foreach ($g in ($dist | Select-Object -First 10)) { Write-LsqLog ("   would set {0,-34} {1}" -f $g.Name, $g.Count) $logPath }
    Write-LsqLog "REPORT ONLY - nothing written. Re-run with -Execute." $logPath
    return
}

function ConvertTo-JsonScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return ($Value | ConvertTo-Json)
}

$url = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
$batches = [Math]::Ceiling($gaps.Count / $BatchSize)
$okCount = 0; $failCount = 0
for ($b = 0; $b -lt $batches; $b++) {
    $slice = @($gaps[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $gaps.Count - 1))])
    $recJson = foreach ($row in $slice) {
        '{"Fields":[' +
            '{"Attribute":"ProspectId","Value":' + (ConvertTo-JsonScalar "$($row.ProspectId)") + '},' +
            '{"Attribute":"' + $SchemaName + '","Value":' + (ConvertTo-JsonScalar "$($row.PreviousStage)") + '}' +
        ']}'
    }
    $body = '{"SearchByKey":"ProspectId","Options":{"PushNonExistentLeadsToUnProcessedList":true},' +
            '"LeadPropertiesList":[' + (@($recJson) -join ',') + ']}'
    try {
        $r = Invoke-LsqPost -Uri $url -JsonBody $body
        $okCount   += [int]$r.Status.SuccessCount
        $failCount += [int]$r.Status.FailureCount
        if ([int]$r.Status.FailureCount -gt 0) { Write-LsqLog "Batch $b : $($r.Status.FailureCount) failure(s) -> $($r | ConvertTo-Json -Compress -Depth 4)" $logPath }
    } catch {
        $failCount += $slice.Count
        Write-LsqLog "Batch $b EXCEPTION -> $($_.Exception.Message)" $logPath
    }
    Start-Sleep -Milliseconds $ThrottleMs
}
Write-LsqLog "Gap fill DONE. ok=$okCount fail=$failCount of $($gaps.Count)." $logPath
Write-LsqLog "Re-run in report mode to confirm zero gaps remain." $logPath
Write-LsqLog "=== Gap fill complete [$mode] ===" $logPath
