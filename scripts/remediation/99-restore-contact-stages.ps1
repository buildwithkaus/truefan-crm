<#
.SYNOPSIS
  Put contacts back on the stage they held before a cleanup run moved them.

.DESCRIPTION
  The counterpart to 06-delete-forecastless-and-demote.ps1's contact write. Unlike the deal
  deletion, this one IS a true undo: the contact still exists and ProspectStage is just a
  field, so writing the recorded previous value restores the exact prior state.

  Why it exists before it is needed: moving contacts off Prospect is visible to every rep the
  moment they open their book, and on 2026-08-11 a bulk stage move put 2,729 contacts in the
  wrong place and had to be reversed the next day. An undo written after the fact is written
  under pressure.

  Reads the stage file written by 06 (data/contact_stage_demoted_<stamp>.json). Verifies the
  first restore by an independent re-fetch before continuing.

.EXAMPLE
  powershell.exe -File scripts\remediation\99-restore-contact-stages.ps1 -StageFile data\contact_stage_demoted_X.json
  powershell.exe -File scripts\remediation\99-restore-contact-stages.ps1 -StageFile ... -Execute

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31).
#>

param(
    [Parameter(Mandatory)][string]$StageFile,
    [switch]$Execute,
    [int]$MaxRecords = 0,
    [int]$ThrottleMs = 250
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_cleanup_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Restore contact stages [$mode] ===" $logPath

if (-not (Test-Path $StageFile)) { throw "Stage file not found: $StageFile" }
$rows = @((Read-Utf8Json $StageFile).Demoted)
Write-LsqLog "Stage file: $StageFile ($($rows.Count) contact(s))" $logPath
if ($rows.Count -eq 0) { Write-LsqLog "Nothing to restore." $logPath; return }

$rows | Group-Object FromStage | ForEach-Object { Write-LsqLog ("  would restore to {0,-16} {1}" -f $_.Name, $_.Count) $logPath }

if (-not $Execute) {
    Write-LsqLog "DRY RUN - nothing written. Re-run with -Execute." $logPath
    return
}

$queue = $rows
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }

$ok = 0; $failed = 0
$isFirst = $true
foreach ($r in $queue) {
    $lid = "$($r.ProspectId)"
    $target = "$($r.FromStage)"
    if (-not $target) { $failed++; Write-LsqLog "  FAIL $lid - no previous stage recorded" $logPath; continue }
    try {
        # Lead.Update via the shared helper - the bulk shape returns 400 (see common.ps1).
        $null = Set-LsqLeadFields -ProspectId $lid -Fields @{ ProspectStage = $target }

        if ($isFirst) {
            Start-Sleep -Seconds 6
            $lr = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
            $now = if ($lr.Count -gt 0) { "$($lr[0].ProspectStage)" } else { "<not found>" }
            if ($now -ne $target) { throw "Contact $lid reads '$now', expected '$target'. Stopping before record 2." }
            Write-LsqLog "  PROOF: contact $lid restored to '$target', verified by re-fetch." $logPath
            $isFirst = $false
        }
        $ok++
    } catch {
        $failed++
        Write-LsqLog "  FAIL $lid -> $($_.Exception.Message)" $logPath
        if ($isFirst) { throw "The first restore FAILED. Stopping." }
    }
    if (($ok + $failed) % 50 -eq 0) { Write-LsqLog "  restored $ok, failed $failed" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "" $logPath
Write-LsqLog "=== restore done: ok=$ok failed=$failed ===" $logPath
Write-LsqLog "NOTE: this restores the CONTACT stage only. Deals deleted alongside are separate -" $logPath
Write-LsqLog "recreate those with 99-restore-opportunities.ps1 from the matching deleted-deal file." $logPath
