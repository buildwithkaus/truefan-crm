<#
.SYNOPSIS
  Writes the mapped Lead fields (disqualification reason/category, call disposition, segment)
  for leads that 04-migrate-leads SKIPPED because their stage did not change.

.DESCRIPTION
  04-migrate-leads.ps1 builds its work set as:

      $pending = $work | Where-Object { $_.OldStage -ne $_.NewContactStage }

  That is wrong. The same write also carries mx_Disqualification_Reason,
  mx_Disqualification_Category, mx_Call_Disposition, mx_Segment and
  mx_Needs_Contact_Resourcing. A lead whose STAGE is unchanged can still need every one of
  those fields.

  The legacy value "Disqualified" maps to the new value "Disqualified" - the identical string -
  so 25,520 leads were classed "already at target stage (skipped)" and silently never received
  a reason or category. Found by 07-verify on 2026-07-31: of 62,611 live Disqualified leads,
  25,631 were missing reason/category and 25,631 of those were inside the migration cohort.

  This works from LIVE state: for every lead in the worklist that should carry a mapped value,
  read what is actually there and write only the ones that are empty. Idempotent - re-run until
  it reports zero gaps.

.PARAMETER Execute
  Required to write. Without it, reports the gap counts only.

.NOTES
  pwsh ./scripts/leadsquared/migration/04c-fill-mapped-field-gaps.ps1
  pwsh ./scripts/leadsquared/migration/04c-fill-mapped-field-gaps.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

. "$PSScriptRoot\..\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_leads_fieldgap_log.txt"
$worklistPath = Join-Path $dataDir "migration_worklist_leads.json"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Mapped-field gap fill [$mode] ===" $logPath

if (-not (Test-Path $worklistPath)) { throw "Worklist missing: $worklistPath" }
$work = @(Expand-LsqRows (Get-Content $worklistPath -Raw | ConvertFrom-Json))
if ($work.Count -lt 50000) { throw "Worklist loaded only $($work.Count) rows, expected ~87,000. Refusing to run from a truncated worklist." }

# Intended values per lead, deduped.
$want = @{}
foreach ($w in $work) {
    $id = "$($w.ProspectId)"
    if (-not $id -or $want.ContainsKey($id)) { continue }
    $want[$id] = $w
}
Write-LsqLog "Worklist leads: $($want.Count)" $logPath

# Live state for the mapped fields.
$MinExpectedLeads = 80000
$live = @{}
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,mx_Disqualification_Reason,mx_Disqualification_Category,mx_Call_Disposition,mx_Segment,mx_Needs_Contact_Resourcing" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { $live["$($l.ProspectID)"] = $l }
    if ($page % 20 -eq 0) { Write-LsqLog "  scanned $($live.Count) leads..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Live leads read: $($live.Count)" $logPath
if ($live.Count -lt $MinExpectedLeads) {
    throw "Read only $($live.Count) leads, expected ~87,000. Refusing to judge gaps from an incomplete scan - it would invent tens of thousands of false gaps."
}

# A gap = the worklist says a field should have a value, and live is empty. Existing values are
# never overwritten: a rep may have set something better since the migration.
$gaps = New-Object System.Collections.Generic.List[object]
$counts = @{ Reason = 0; Category = 0; Disposition = 0; Segment = 0; Resourcing = 0 }
foreach ($id in $want.Keys) {
    if (-not $live.ContainsKey($id)) { continue }
    $w = $want[$id]; $l = $live[$id]
    $need = @{}
    if ($w.Reason      -and [string]::IsNullOrWhiteSpace("$($l.mx_Disqualification_Reason)"))   { $need["mx_Disqualification_Reason"]   = "$($w.Reason)";      $counts.Reason++ }
    if ($w.Category    -and [string]::IsNullOrWhiteSpace("$($l.mx_Disqualification_Category)")) { $need["mx_Disqualification_Category"] = "$($w.Category)";    $counts.Category++ }
    if ($w.Disposition -and [string]::IsNullOrWhiteSpace("$($l.mx_Call_Disposition)"))          { $need["mx_Call_Disposition"]          = "$($w.Disposition)"; $counts.Disposition++ }
    if ($w.Segment     -and [string]::IsNullOrWhiteSpace("$($l.mx_Segment)"))                   { $need["mx_Segment"]                   = "$($w.Segment)";     $counts.Segment++ }
    if ($w.NeedsContactResourcing -and [string]::IsNullOrWhiteSpace("$($l.mx_Needs_Contact_Resourcing)")) { $need["mx_Needs_Contact_Resourcing"] = "Yes";      $counts.Resourcing++ }
    if ($need.Count -gt 0) { [void]$gaps.Add([pscustomobject]@{ ProspectId = $id; Fields = $need }) }
}

Write-LsqLog "--- gaps by field ---" $logPath
foreach ($k in $counts.Keys) { Write-LsqLog ("   {0,-14} {1}" -f $k, $counts[$k]) $logPath }
Write-LsqLog "Leads needing at least one field: $($gaps.Count)" $logPath

if ($gaps.Count -eq 0) {
    Write-LsqLog "No gaps - every migrated lead carries its mapped fields." $logPath
    Write-LsqLog "=== Gap fill complete [$mode] ===" $logPath
    return
}
if (-not $Execute) {
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
Write-LsqLog "Writing in $batches batches of $BatchSize (~$([Math]::Round(($batches*$ThrottleMs)/60000,0)) min)" $logPath

for ($b = 0; $b -lt $batches; $b++) {
    $slice = @($gaps[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $gaps.Count - 1))])
    $recJson = foreach ($row in $slice) {
        $fields = New-Object System.Collections.Generic.List[string]
        [void]$fields.Add('{"Attribute":"ProspectId","Value":' + (ConvertTo-JsonScalar "$($row.ProspectId)") + '}')
        foreach ($k in $row.Fields.Keys) {
            [void]$fields.Add('{"Attribute":"' + $k + '","Value":' + (ConvertTo-JsonScalar "$($row.Fields[$k])") + '}')
        }
        '{"Fields":[' + ($fields -join ',') + ']}'
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
    if ($b % 20 -eq 0) { Write-LsqLog "Progress: batch $b/$batches ok=$okCount fail=$failCount" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}
Write-LsqLog "Gap fill DONE. ok=$okCount fail=$failCount of $($gaps.Count)." $logPath
Write-LsqLog "Re-run in report mode to confirm zero gaps." $logPath
Write-LsqLog "=== Gap fill complete [$mode] ===" $logPath
