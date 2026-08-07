<#
.SYNOPSIS
  Moves leads that were DIALLED but never connected out of Fresh and into Engaged.

.DESCRIPTION
  Decision 2026-07-31 (Kaustubh). "Fresh" is the bucket reps hunt in for new accounts to call.
  Under the original mapping it also held every lead that had been dialled without reaching a
  human - 17,019 of them - so the pool reps needed was buried in leads they had already chased.

  Fresh now means "nobody has dialled this yet". A dialled-but-unconnected lead moves to Engaged,
  with the reason it did not connect preserved in Call Disposition.

  Scope: leads at Fresh whose Call Disposition is one of the un-connected outcomes. Which
  outcomes those are is DERIVED from $StageMap (the legacy values that mapped to Engaged with a
  disposition), not hardcoded, so the schema stays the single source of truth.

  Leads at Fresh with NO disposition are untouched - they are the genuinely un-dialled pool this
  change exists to protect.

.PARAMETER Execute
  Required to write. Without it, reports the split.

.NOTES
  pwsh ./scripts/leadsquared/migration/17-move-unconnected-to-engaged.ps1
  pwsh ./scripts/leadsquared/migration/17-move-unconnected-to-engaged.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_unconnected_to_engaged_log.txt"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Move dialled-but-unconnected Fresh leads to Engaged [$mode] ===" $logPath

# Dispositions that now belong to Engaged, derived from the schema rather than typed out.
$engagedDispositions = @{}
foreach ($k in $Script:StageMap.Keys) {
    $m = $Script:StageMap[$k]
    if ($m.Contact -eq "Engaged" -and $m.Disposition) { $engagedDispositions["$($m.Disposition)"] = $true }
}
Write-LsqLog "Dispositions that belong to Engaged: $(($engagedDispositions.Keys | Sort-Object) -join ' | ')" $logPath

$MinExpectedLeads = 80000
$all = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $r = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,ProspectStage,mx_Call_Disposition" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($r.Count -eq 0) { break }
    foreach ($l in $r) { [void]$all.Add($l) }
    if ($page % 20 -eq 0) { Write-LsqLog "  scanned $($all.Count)..." $logPath }
    if ($r.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Leads scanned: $($all.Count)" $logPath
if ($all.Count -lt $MinExpectedLeads) { throw "Only $($all.Count) leads enumerated - refusing to act on an incomplete scan." }

$seen = @{}
$work = New-Object System.Collections.Generic.List[object]
$byDisp = @{}
$freshUntouched = 0
foreach ($l in $all) {
    $id = "$($l.ProspectID)"
    if (-not $id -or $seen.ContainsKey($id)) { continue }   # dedupe: a duplicate id fails the whole batch
    $seen[$id] = $true
    if ("$($l.ProspectStage)" -ne "Fresh") { continue }
    $d = "$($l.mx_Call_Disposition)"
    if ([string]::IsNullOrWhiteSpace($d)) { $freshUntouched++; continue }
    if (-not $engagedDispositions.ContainsKey($d)) { continue }
    if ($byDisp.ContainsKey($d)) { $byDisp[$d]++ } else { $byDisp[$d] = 1 }
    [void]$work.Add($id)
}

Write-LsqLog "" $logPath
Write-LsqLog "=== SPLIT ===" $logPath
Write-LsqLog ("  Fresh, never dialled (STAYS Fresh)   : {0}" -f $freshUntouched) $logPath
Write-LsqLog ("  Fresh, dialled (MOVES to Engaged)    : {0}" -f $work.Count) $logPath
foreach ($k in ($byDisp.Keys | Sort-Object { -$byDisp[$_] })) { Write-LsqLog ("      {0,-34} {1}" -f $k, $byDisp[$k]) $logPath }

if ($work.Count -eq 0) { Write-LsqLog "Nothing to move." $logPath; return }
if (-not $Execute) { Write-LsqLog "REPORT ONLY - nothing written. Re-run with -Execute." $logPath; return }

function ConvertTo-JsonScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return ($Value | ConvertTo-Json)
}

$url = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
$batches = [Math]::Ceiling($work.Count / $BatchSize)
$ok = 0; $fail = 0
Write-LsqLog "Writing $($work.Count) leads in $batches batches (~$([Math]::Round(($batches*$ThrottleMs)/60000,0)) min)" $logPath
for ($b = 0; $b -lt $batches; $b++) {
    $slice = @($work[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $work.Count - 1))])
    $recJson = foreach ($id in $slice) {
        '{"Fields":[' +
            '{"Attribute":"ProspectId","Value":' + (ConvertTo-JsonScalar $id) + '},' +
            '{"Attribute":"ProspectStage","Value":"Engaged"}' +
        ']}'
    }
    $body = '{"SearchByKey":"ProspectId","Options":{"PushNonExistentLeadsToUnProcessedList":true},' +
            '"LeadPropertiesList":[' + (@($recJson) -join ',') + ']}'
    try {
        $r = Invoke-LsqPost -Uri $url -JsonBody $body
        $ok   += [int]$r.Status.SuccessCount
        $fail += [int]$r.Status.FailureCount
        if ([int]$r.Status.FailureCount -gt 0) { Write-LsqLog "Batch $b : $($r.Status.FailureCount) failure(s) -> $($r | ConvertTo-Json -Compress -Depth 4)" $logPath }
    } catch {
        $fail += $slice.Count
        Write-LsqLog "Batch $b EXCEPTION -> $($_.Exception.Message)" $logPath
    }
    if ($b % 20 -eq 0) { Write-LsqLog "Progress: batch $b/$batches ok=$ok fail=$fail" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}
Write-LsqLog "DONE. ok=$ok fail=$fail of $($work.Count)." $logPath
Write-LsqLog "NEXT: company stages now lag - run 13-reconcile-companies.ps1 (report first)." $logPath
Write-LsqLog "=== Move complete [$mode] ===" $logPath
