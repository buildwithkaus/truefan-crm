<#
.SYNOPSIS
  Creates the "Previous Stage (Legacy)" Lead field and backfills every lead's pre-migration
  ProspectStage into it, so reps can still filter accounts the way they used to.

.DESCRIPTION
  Run 09-build-previous-stage-map.ps1 first - it produces the worklist and the exact dropdown
  option list, both generated from the pre-migration snapshots rather than typed by hand.

  The field is a dropdown so it works in LeadSquared's filter/Smart View UI the same way the
  old stage field did. Its options are exactly the 28 values that actually occur in the data,
  so no lead can end up holding a value the dropdown does not offer (the trap that would have
  hit 140 Opportunities on 2026-07-29).

  Idempotent: the field is skipped if it already exists, and the backfill is checkpointed.

.PARAMETER Execute
  Required to create the field or write any data.

.NOTES
  pwsh ./scripts/leadsquared/migration/09-build-previous-stage-map.ps1
  pwsh ./scripts/leadsquared/migration/10-apply-previous-stage.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100,
    # Created manually in the UI on 2026-07-30 as a TEXT field (Textbox, MaxLength 50), not a
    # dropdown. Text needs no option list, and the longest legacy value is 35 chars, so every
    # value fits. The trade-off is that Smart View filters require typing the value rather than
    # picking it from a list.
    [string]$SchemaName = "mx_Previous_Contact_Stage",
    [string]$DisplayName = "Previous Contact Stage"
)

. "$PSScriptRoot\..\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_previous_stage_log.txt"
$checkpointPath = Join-Path $dataDir "migration_previous_stage_checkpoint.txt"
$workPath = Join-Path $dataDir "migration_worklist_previous_stage.json"
$optPath  = Join-Path $dataDir "migration_previous_stage_options.json"

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "=== Previous Stage field + backfill [$mode] ===" $logPath

foreach ($p in @($workPath, $optPath)) {
    if (-not (Test-Path $p)) { throw "Missing $p - run 09-build-previous-stage-map.ps1 first." }
}

$work = @(Expand-LsqRows (Get-Content $workPath -Raw | ConvertFrom-Json))
$options = @(Expand-LsqRows (Get-Content $optPath -Raw | ConvertFrom-Json))
Write-LsqLog "Worklist rows: $($work.Count)   distinct options: $($options.Count)" $logPath
if ($work.Count -lt 50000) {
    throw "Previous-stage worklist has only $($work.Count) rows, expected ~87,000. Refusing to run from a truncated worklist."
}

# ---------------------------------------------------------------------------------------
# 1. Create the field if it does not exist.
# ---------------------------------------------------------------------------------------
$meta = Invoke-RestMethod -Uri (Get-LsqUrl "LeadManagement.svc/LeadsMetaData.Get") -Method Get
$have = @{}
foreach ($f in $meta) { $have["$($f.SchemaName)"] = $true }

if ($have.ContainsKey($SchemaName)) {
    Write-LsqLog "Field $SchemaName already exists - skipping creation." $logPath
} elseif (-not $Execute) {
    Write-LsqLog "WOULD CREATE $SchemaName ('$DisplayName', Select) with $($options.Count) options" $logPath
} else {
    # CreateLeadField needs: OptionsJson as a real ARRAY (not a stringified one), each option
    # carrying an explicit 1-based Order, and RenderTypeTextValue. Omitting any of the three
    # fails with a 400 or a bare 500 - all three learned the hard way on 2026-07-30.
    $ord = 0
    $payload = @{
        SchemaName          = $SchemaName
        DisplayName         = $DisplayName
        DataType            = "Select"
        IsMandatory         = $false
        RenderTypeTextValue = "Dropdown"
        OptionsJson         = @($options | ForEach-Object { $ord++; @{ Value = "$_"; Order = $ord } })
    }
    $r = Invoke-LsqPost -Uri (Get-LsqUrl "LeadManagement.svc/CreateLeadField") -JsonBody ($payload | ConvertTo-Json -Depth 6)
    Write-LsqLog "CREATED $SchemaName -> $($r | ConvertTo-Json -Compress)" $logPath

    # Confirm against live metadata - a create that reports success but did not register would
    # make every backfill write fail with "Non-existent field(s) provided".
    Start-Sleep -Seconds 5
    $meta2 = Invoke-RestMethod -Uri (Get-LsqUrl "LeadManagement.svc/LeadsMetaData.Get") -Method Get
    $ok = @($meta2 | Where-Object { "$($_.SchemaName)" -eq $SchemaName }).Count -gt 0
    if (-not $ok) { throw "Field $SchemaName does not appear in live metadata after creation. Aborting before the backfill." }
    Write-LsqLog "Verified $SchemaName exists in live schema." $logPath
}

if (-not $Execute) {
    $dist = $work | Group-Object PreviousStage | Sort-Object Count -Descending
    foreach ($g in ($dist | Select-Object -First 10)) { Write-LsqLog ("   would set {0,-34} {1}" -f $g.Name, $g.Count) $logPath }
    Write-LsqLog "DRY RUN complete - nothing written. Re-run with -Execute." $logPath
    return
}

# ---------------------------------------------------------------------------------------
# 2. Backfill.
# ---------------------------------------------------------------------------------------
function ConvertTo-JsonScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return ($Value | ConvertTo-Json)
}

$startBatch = 0
if (Test-Path $checkpointPath) {
    $startBatch = [int](Get-Content $checkpointPath -Raw).Trim()
    Write-LsqLog "Resuming from batch $startBatch." $logPath
}

# Dedupe: a ProspectId appearing twice in one batch makes LeadSquared reject BOTH copies
# ("2 Duplicate Lead(s) provided") - that stranded 22 leads during the main lead migration.
$seen = @{}
$rows = New-Object System.Collections.Generic.List[object]
foreach ($w in $work) {
    $id = "$($w.ProspectId)"
    if (-not $id -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    [void]$rows.Add($w)
}
Write-LsqLog "Unique leads to write: $($rows.Count)" $logPath

$url = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
$batches = [Math]::Ceiling($rows.Count / $BatchSize)
$okCount = 0; $failCount = 0
Write-LsqLog "Writing in $batches batches of $BatchSize (~$([Math]::Round(($batches * $ThrottleMs)/60000,1)) min)" $logPath

for ($b = $startBatch; $b -lt $batches; $b++) {
    $slice = @($rows[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $rows.Count - 1))])
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
        if ([int]$r.Status.FailureCount -gt 0) {
            Write-LsqLog "Batch $b : $($r.Status.FailureCount) failure(s) -> $($r | ConvertTo-Json -Compress -Depth 4)" $logPath
        }
    } catch {
        $failCount += $slice.Count
        Write-LsqLog "Batch $b EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }
    Set-Content -Path $checkpointPath -Value ($b + 1)
    if ($b % 20 -eq 0) { Write-LsqLog "Progress: batch $b/$batches ok=$okCount fail=$failCount" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Previous Stage backfill DONE. ok=$okCount fail=$failCount of $($rows.Count)." $logPath
if ($failCount -eq 0) { Remove-Item $checkpointPath -ErrorAction SilentlyContinue; Write-LsqLog "Checkpoint cleared (clean run)." $logPath }
Write-LsqLog "=== Previous Stage complete [$mode] ===" $logPath
