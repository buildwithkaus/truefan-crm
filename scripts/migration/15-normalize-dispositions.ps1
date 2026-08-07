<#
.SYNOPSIS
  Rewrites every stored Call Disposition to the exact value held in the live mx_Call_Disposition
  dropdown, so reps can select and filter on it.

.DESCRIPTION
  The migration wrote disposition values from the plan's naming ("RNR (5+ dials)",
  "Follow Up (pitch delivered)", "Switched Off / Not Reachable"). Those are not options in the
  field's own dropdown, and LeadSquared stores an unknown string rather than rejecting it - so
  20,274 leads ended up holding values reps could neither pick nor filter by.

  Decision (Kaustubh, 2026-07-31): keep the six dropdown options that already exist and match
  the DATA to them, rather than adding new options. Two of the plan's names were also dropped
  as unsupported by the source data - the legacy "RNR" value never recorded a dial count, and
  "Follow Up" does not establish that a pitch was delivered.

  This script does NOT hardcode the target names. It reads the live dropdown, maps each stored
  value onto the option it corresponds to, and refuses to run if any stored value cannot be
  mapped - so a value nobody accounted for halts the run instead of being silently rewritten.

.PARAMETER Execute
  Required to write. Without it, reports the mapping and the counts.

.NOTES
  pwsh ./scripts/leadsquared/migration/15-normalize-dispositions.ps1
  pwsh ./scripts/leadsquared/migration/15-normalize-dispositions.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_disposition_normalise_log.txt"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Call Disposition normalisation [$mode] ===" $logPath

# --- the live dropdown is the source of truth for the target names ----------------------
$meta = Invoke-RestMethod -Uri (Get-LsqUrl "LeadManagement.svc/LeadsMetaData.Get") -Method Get
$field = @($meta | Where-Object { "$($_.SchemaName)" -eq "mx_Call_Disposition" })
if ($field.Count -eq 0) { throw "mx_Call_Disposition not found in live schema." }
$options = @($field[0].Options | ForEach-Object { "$($_.Value)" } | Where-Object { $_ -ne "" })
if ($options.Count -eq 0) { throw "mx_Call_Disposition has no dropdown options - refusing to normalise against an empty list." }
Write-LsqLog "Live dropdown options ($($options.Count)):" $logPath
foreach ($o in $options) { Write-LsqLog "   [$o]" $logPath }

# Match a stored value to an option by collapsing case, spaces and punctuation. That is enough
# to pair "Switched Off / Not Reachable" with "Switched Off/Not Reachable" and "Call Me Later"
# with "Call me Later", without hardcoding either.
function Get-MatchKey {
    param([string]$Value)
    return (($Value -replace '[^A-Za-z0-9]', '')).ToLower()
}
$optionByKey = @{}
foreach ($o in $options) { $optionByKey[(Get-MatchKey $o)] = $o }

# Values the plan introduced that carry a qualifier the dropdown does not have. These need an
# explicit pairing because stripping punctuation alone will not match them.
$qualifierStrip = @{
    (Get-MatchKey "RNR (5+ dials)")              = "RNR"
    (Get-MatchKey "Follow Up (pitch delivered)") = "Follow Up"
}

# --- enumerate live -----------------------------------------------------------------------
$MinExpectedLeads = 80000
$all = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,mx_Call_Disposition" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$all.Add($l) }
    if ($page % 20 -eq 0) { Write-LsqLog "  scanned $($all.Count)..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Leads scanned: $($all.Count)" $logPath
if ($all.Count -lt $MinExpectedLeads) { throw "Only $($all.Count) leads enumerated - refusing to normalise from an incomplete scan." }

# --- decide the target for every stored value ---------------------------------------------
$work = New-Object System.Collections.Generic.List[object]
$plan = @{}
$unmappable = @{}
# Dedupe by ProspectId: enumeration can return the same lead on two pages, and LeadSquared
# rejects a BATCH containing the same id twice ("2 Duplicate Lead(s) provided"), taking the
# good records down with it. That cost 4 records on the first run of this script.
$seen = @{}
foreach ($l in $all) {
    $leadId = "$($l.ProspectID)"
    if (-not $leadId -or $seen.ContainsKey($leadId)) { continue }
    $seen[$leadId] = $true

    $cur = "$($l.mx_Call_Disposition)"
    if ([string]::IsNullOrWhiteSpace($cur)) { continue }
    if ($options -contains $cur) { continue }        # already exactly an option

    $key = Get-MatchKey $cur
    $target = $null
    if ($qualifierStrip.ContainsKey($key))  { $target = $qualifierStrip[$key] }
    elseif ($optionByKey.ContainsKey($key)) { $target = $optionByKey[$key] }

    if (-not $target) {
        if (-not $unmappable.ContainsKey($cur)) { $unmappable[$cur] = 0 }
        $unmappable[$cur]++
        continue
    }
    $pk = "$cur -> $target"
    if ($plan.ContainsKey($pk)) { $plan[$pk]++ } else { $plan[$pk] = 1 }
    [void]$work.Add([pscustomobject]@{ ProspectId = "$($l.ProspectID)"; Value = $target })
}

Write-LsqLog "" $logPath
Write-LsqLog "=== NORMALISATION PLAN ===" $logPath
foreach ($k in ($plan.Keys | Sort-Object { -$plan[$_] })) { Write-LsqLog ("   {0,-62} {1}" -f $k, $plan[$k]) $logPath }
Write-LsqLog ("   leads to write: {0}" -f $work.Count) $logPath

if ($unmappable.Count -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "STOP - stored values that match no dropdown option:" $logPath
    foreach ($k in $unmappable.Keys) { Write-LsqLog ("   [{0}] = {1}" -f $k, $unmappable[$k]) $logPath }
    throw "$($unmappable.Count) disposition value(s) cannot be mapped to a dropdown option. Add the option or extend the mapping - refusing to guess."
}

if ($work.Count -eq 0) { Write-LsqLog "Nothing to normalise - every stored value is already a dropdown option." $logPath; return }
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
    $recJson = foreach ($row in $slice) {
        '{"Fields":[' +
            '{"Attribute":"ProspectId","Value":' + (ConvertTo-JsonScalar "$($row.ProspectId)") + '},' +
            '{"Attribute":"mx_Call_Disposition","Value":' + (ConvertTo-JsonScalar "$($row.Value)") + '}' +
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
Write-LsqLog "Normalisation DONE. ok=$ok fail=$fail of $($work.Count)." $logPath
Write-LsqLog "Re-run in report mode to confirm every stored value is now a dropdown option." $logPath
Write-LsqLog "=== Call Disposition normalisation complete [$mode] ===" $logPath
