<#
.SYNOPSIS
  Writes the new contact stage (plus disqualification reason/category, call disposition,
  segment) onto every lead, from migration_worklist_leads.json.

.DESCRIPTION
  Uses LeadManagement.svc/Lead/Bulk/UpdateV2 - 25 records per call, matched on ProspectId.
  Idempotent and resumable: a checkpoint file records the last completed batch index, so a
  killed run resumes rather than restarting.

  Only writes leads whose stage actually needs to change, so re-running is cheap.

.PARAMETER Execute
  Required to write. Without it the script reports what it would do and exits.

.PARAMETER BatchSize
  Records per API call. 25 is the documented maximum for UpdateV2.

.PARAMETER ThrottleMs
  Delay between calls. The account cap is 20 calls/5s ACCOUNT-WIDE, and bulk endpoints are
  ~5 calls/5s. 1100ms is deliberately conservative - do not lower it, and do not run any
  other script against the API at the same time (a concurrent run once caused 23 silent
  write failures).

.NOTES
  pwsh ./scripts/leadsquared/migration/04-migrate-leads.ps1            # dry run
  pwsh ./scripts/leadsquared/migration/04-migrate-leads.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_leads_log.txt"
$checkpointPath = Join-Path $dataDir "migration_leads_checkpoint.txt"
$worklistPath = Join-Path $dataDir "migration_worklist_leads.json"

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "=== Lead stage migration [$mode] ===" $logPath

if (-not (Test-Path $worklistPath)) { throw "Worklist missing. Run 02-build-worklist.ps1 first." }
$work = Get-Content $worklistPath -Raw | ConvertFrom-Json
Write-LsqLog "Worklist rows: $($work.Count)" $logPath

# Skip rows that are already correct - makes the run idempotent and much cheaper on re-run.
$pending = @($work | Where-Object { $_.OldStage -ne $_.NewContactStage })
$alreadyCorrect = $work.Count - $pending.Count
Write-LsqLog "Already at target stage (skipped): $alreadyCorrect" $logPath
Write-LsqLog "Rows needing a write: $($pending.Count)" $logPath

$batches = [Math]::Ceiling($pending.Count / $BatchSize)
$estMin = [Math]::Round(($batches * $ThrottleMs) / 60000, 1)
Write-LsqLog "Batches of $BatchSize : $batches  (estimated ~$estMin min at ${ThrottleMs}ms)" $logPath

if (-not $Execute) {
    $dist = $pending | Group-Object NewContactStage | Sort-Object Count -Descending
    Write-LsqLog "--- Would write these target stages ---" $logPath
    foreach ($g in $dist) { Write-LsqLog ("  {0,-14} {1}" -f $g.Name, $g.Count) $logPath }
    Write-LsqLog "DRY RUN complete - nothing written. Re-run with -Execute." $logPath
    return
}

$startBatch = 0
if (Test-Path $checkpointPath) {
    $startBatch = [int](Get-Content $checkpointPath -Raw).Trim()
    Write-LsqLog "Resuming from batch $startBatch (checkpoint found)." $logPath
}

$url = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
$okCount = 0; $failCount = 0

for ($b = $startBatch; $b -lt $batches; $b++) {
    $slice = $pending[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $pending.Count - 1))]

    $records = @()
    foreach ($row in $slice) {
        $fields = @(
            @{ Attribute = "ProspectId";    Value = $row.ProspectId }
            @{ Attribute = "ProspectStage"; Value = $row.NewContactStage }
        )
        if ($row.Reason)      { $fields += @{ Attribute = "mx_Disqualification_Reason";   Value = $row.Reason } }
        if ($row.Category)    { $fields += @{ Attribute = "mx_Disqualification_Category"; Value = $row.Category } }
        if ($row.Disposition) { $fields += @{ Attribute = "mx_Call_Disposition";          Value = $row.Disposition } }
        if ($row.Segment)     { $fields += @{ Attribute = "mx_Segment";                   Value = $row.Segment } }
        if ($row.NeedsContactResourcing) { $fields += @{ Attribute = "mx_Needs_Contact_Resourcing"; Value = "Yes" } }
        $records += ,@(@{ Fields = $fields })
    }

    $body = @{
        SearchByKey        = "ProspectId"
        Options            = @{ PushNonExistentLeadsToUnProcessedList = $true }
        LeadPropertiesList = $records
    } | ConvertTo-Json -Depth 8

    try {
        # UTF-8 byte body: lead/company text can contain non-ASCII which the plain string
        # form mis-encodes into a hard 400. See CLAUDE.md.
        $r = Invoke-LsqPost -Uri $url -JsonBody $body
        $s = $r.Status.SuccessCount
        $f = $r.Status.FailureCount
        $okCount += [int]$s
        if ([int]$f -gt 0) {
            $failCount += [int]$f
            Write-LsqLog "Batch $b : $f failure(s) -> $($r | ConvertTo-Json -Compress -Depth 4)" $logPath
        }
    } catch {
        $failCount += $slice.Count
        Write-LsqLog "Batch $b EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }

    Set-Content -Path $checkpointPath -Value ($b + 1)
    if ($b % 20 -eq 0) {
        Write-LsqLog "Progress: batch $b/$batches  ok=$okCount fail=$failCount" $logPath
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Lead migration DONE. ok=$okCount fail=$failCount of $($pending.Count) pending." $logPath
if ($failCount -eq 0) {
    Remove-Item $checkpointPath -ErrorAction SilentlyContinue
    Write-LsqLog "Checkpoint cleared (clean run)." $logPath
} else {
    Write-LsqLog "Checkpoint retained - re-run to retry failures." $logPath
}
Write-LsqLog "=== Lead stage migration complete [$mode] ===" $logPath
