<#
.SYNOPSIS
  Builds the worklist for a "Previous Stage" Lead field holding each lead's PRE-MIGRATION
  ProspectStage, so reps can still find accounts the way they used to.

.DESCRIPTION
  The restructure replaced 28 legacy ProspectStage values with 5 lifecycle stages. Reps had
  years of muscle memory around filtering on the old values ("show me my RNRs", "show me Low
  Budget") and that is gone. This preserves it as a separate, read-only-ish field rather than
  reintroducing the old taxonomy into the live stage field.

  The old values are recovered from two PRE-migration snapshots, unioned:
    * data/migration_BACKUP_leads_<stamp>.json  - captured 07:40, before any lead was written
    * data/migration_worklist_leads.json        - built 09:12, carries OldStage per lead
  The backup is authoritative where both have a lead; the worklist fills gaps.

  Read-only. Produces data/migration_worklist_previous_stage.json plus the exact distinct
  value list to use as the field's dropdown options (generated from live data, never
  hand-written - see CLAUDE.md).

.NOTES
  pwsh ./scripts/leadsquared/migration/09-build-previous-stage-map.ps1
#>

param(
    [string]$BackupStamp = "20260730-074038"
)

. "$PSScriptRoot\..\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_previous_stage_log.txt"
$outPath = Join-Path $dataDir "migration_worklist_previous_stage.json"

Write-LsqLog "=== Building Previous Stage map (READ-ONLY) ===" $logPath

$backupPath = Join-Path $dataDir "migration_BACKUP_leads_$BackupStamp.json"
if (-not (Test-Path $backupPath)) { throw "Lead backup not found: $backupPath" }

$prev = @{}   # ProspectId -> pre-migration ProspectStage

$backup = @(Expand-LsqRows (Get-Content $backupPath -Raw | ConvertFrom-Json))
Write-LsqLog "Backup rows (pre-migration snapshot): $($backup.Count)" $logPath
foreach ($b in $backup) {
    $id = "$($b.ProspectId)"
    $s  = "$($b.ProspectStage)"
    if ($id -and -not [string]::IsNullOrWhiteSpace($s)) { $prev[$id] = $s }
}
Write-LsqLog "From backup: $($prev.Count) leads with a known previous stage" $logPath

# Fill gaps from the worklist (leads created between the backup and the worklist build).
$wlPath = Join-Path $dataDir "migration_worklist_leads.json"
$added = 0
if (Test-Path $wlPath) {
    $wl = @(Expand-LsqRows (Get-Content $wlPath -Raw | ConvertFrom-Json))
    Write-LsqLog "Worklist rows: $($wl.Count)" $logPath
    foreach ($w in $wl) {
        $id = "$($w.ProspectId)"
        $s  = "$($w.OldStage)"
        if (-not $id -or [string]::IsNullOrWhiteSpace($s) -or $s -eq "<BLANK>") { continue }
        if (-not $prev.ContainsKey($id)) { $prev[$id] = $s; $added++ }
    }
}
Write-LsqLog "Filled $added additional leads from the worklist" $logPath
Write-LsqLog "TOTAL leads with a previous stage: $($prev.Count)" $logPath

# Distinct values - these become the dropdown options. Generated from real data, not typed out.
$counts = @{}
foreach ($v in $prev.Values) { if ($counts.ContainsKey($v)) { $counts[$v]++ } else { $counts[$v] = 1 } }
Write-LsqLog "" $logPath
Write-LsqLog "--- distinct previous-stage values ($($counts.Count)) ---" $logPath
foreach ($k in ($counts.Keys | Sort-Object { -$counts[$_] })) {
    Write-LsqLog ("   [{0}] = {1}" -f $k, $counts[$k]) $logPath
}

$work = New-Object System.Collections.Generic.List[object]
foreach ($id in $prev.Keys) {
    [void]$work.Add([pscustomobject]@{ ProspectId = $id; PreviousStage = $prev[$id] })
}
$work | ConvertTo-Json -Depth 3 | Set-Content -Path $outPath
Write-LsqLog "" $logPath
Write-LsqLog "Worklist written: $($work.Count) rows -> $outPath" $logPath

# Emit the option list in the exact shape 10-apply needs, so the field definition and the data
# can never drift apart.
$optPath = Join-Path $dataDir "migration_previous_stage_options.json"
@($counts.Keys | Sort-Object) | ConvertTo-Json | Set-Content -Path $optPath
Write-LsqLog "Dropdown options written: $($counts.Count) -> $optPath" $logPath
Write-LsqLog "=== Previous Stage map complete ===" $logPath
