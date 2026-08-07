<#
.SYNOPSIS
  Re-fetches the Opportunities that 03-backup.ps1 failed to read, and merges them into the
  Opportunity backup file so the rollback set has no silent holes.

.DESCRIPTION
  03-backup.ps1's Opportunity phase catches per-lead read errors and continues, so a transient
  network failure becomes a MISSING RECORD in the backup rather than a failed run. On
  2026-07-30 that produced 19 gaps from Akamai DNS rotation (api-in21.leadsquared.com resolves
  to a rotating edge IP; resolution fails outright for a few seconds during a change).

  A backup with holes is worse than a short one, because it looks complete. This script reads
  the failed lead IDs straight out of the backup log, re-fetches only those, and merges the
  results into the existing Opportunity backup JSON.

  Reads only. Safe to run repeatedly - it re-reads the log each time and skips leads whose
  opportunities are already present in the backup file.

.NOTES
  pwsh ./scripts/leadsquared/migration/03b-backfill-opportunity-backup-gaps.ps1
#>

param(
    [string]$Stamp,
    [int]$ThrottleMs = 300
)

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_backup_log.txt"

if (-not $Stamp) {
    $latest = Get-ChildItem (Join-Path $dataDir "migration_BACKUP_opportunities_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No migration_BACKUP_opportunities_*.json found - run 03-backup.ps1 first." }
    if ($latest.Name -match 'migration_BACKUP_opportunities_(.+)\.json$') { $Stamp = $matches[1] }
}
$oppPath = Join-Path $dataDir "migration_BACKUP_opportunities_$Stamp.json"
if (-not (Test-Path $oppPath)) { throw "Opportunity backup not found: $oppPath" }

Write-LsqLog "=== Backfilling Opportunity backup gaps (stamp $Stamp) ===" $logPath

# Failed lead IDs come from the log the backup itself wrote - not a hand-kept list.
$failedIds = @(Get-Content $logPath |
    Select-String -Pattern 'Opportunity read failed for lead ([0-9a-fA-F\-]{36})' |
    ForEach-Object { $_.Matches[0].Groups[1].Value } |
    Select-Object -Unique)
Write-LsqLog "Distinct failed lead IDs in log: $($failedIds.Count)" $logPath
if ($failedIds.Count -eq 0) { Write-LsqLog "Nothing to backfill." $logPath; return }

$existing = @(Expand-LsqRows (Get-Content $oppPath -Raw | ConvertFrom-Json))
Write-LsqLog "Existing Opportunity backup rows: $($existing.Count)" $logPath
$haveLead = @{}
foreach ($e in $existing) { $haveLead["$($e.ProspectId)"] = $true }

$todo = @($failedIds | Where-Object { -not $haveLead.ContainsKey($_) })
Write-LsqLog "Leads still missing from the backup: $($todo.Count)" $logPath

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$added = New-Object System.Collections.Generic.List[object]
$stillFailing = @()
foreach ($leadId in $todo) {
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$leadId&opportunityType=12000"
    try {
        # Invoke-LsqWithRetry handles the DNS-rotation failures that caused these gaps.
        $r = Invoke-LsqWithRetry -What "opps for $leadId" -Action {
            Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -ErrorAction Stop
        }
        if ($r.RecordCount -gt 0) {
            foreach ($o in $r.List) {
                $f = @{}
                foreach ($fld in $o.Fields) { $f[$fld.SchemaName] = $fld.Value }
                [void]$added.Add([pscustomobject]@{
                    ProspectId    = $leadId
                    OpportunityId = $o.OpportunityId
                    Status        = $f["Status"]
                    Stage         = $f["mx_Custom_2"]
                    Name          = $f["mx_Custom_1"]
                })
            }
        }
    } catch {
        $stillFailing += $leadId
        Write-LsqLog "  STILL FAILING $leadId -> $($_.Exception.Message)" $logPath
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

if ($added.Count -gt 0) {
    $merged = @($existing) + @($added)
    $merged | ConvertTo-Json -Depth 4 | Set-Content -Path $oppPath
    Write-LsqLog "Backfilled $($added.Count) Opportunity rows -> $oppPath (total now $($merged.Count))" $logPath
} else {
    Write-LsqLog "No new Opportunity rows recovered." $logPath
}

if ($stillFailing.Count -gt 0) {
    Write-LsqLog "WARNING: $($stillFailing.Count) lead(s) still unreadable - the Opportunity backup has gaps for these:" $logPath
    foreach ($x in $stillFailing) { Write-LsqLog "    $x" $logPath }
    throw "Opportunity backup still has $($stillFailing.Count) gap(s). Re-run this script before relying on the rollback set."
}
Write-LsqLog "=== Opportunity backup gap backfill complete - no gaps remain ===" $logPath
