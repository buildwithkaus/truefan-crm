<#
.SYNOPSIS
  Incident rollback: Rishi Saraswat (active rep, memory/04-active-rep-roster.md) was
  wrongly included in the original 30-name "departed owners" list used for Phase 2
  (see memory/05-departed-owner-reassignment.md). His 2,360 leads had OwnerId set to
  Admin by that migration and need to be restored to him.

.DESCRIPTION
  Reads data/departed_owner_leads_BACKUP.json, filters to OrigOwnerName == "Rishi
  Saraswat", and bulk-restores OwnerId to his real OwnerId
  (f033a0b3-1dd5-11f1-bd10-0a70299d455d) for every one of those leads. This is the
  historically-correct owner per the backup taken before Phase 2 ran, not a guess.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/rollback-rishi-leads.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']
$rishiId = "f033a0b3-1dd5-11f1-bd10-0a70299d455d"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "rollback-rishi_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

$backup = Get-Content (Join-Path $dataDir "departed_owner_leads_BACKUP.json") -Raw | ConvertFrom-Json
$rishiLeads = $backup | Where-Object { $_.OrigOwnerName -eq "Rishi Saraswat" }
Write-Log "=== Rollback run started. Rishi leads to restore: $($rishiLeads.Count) ==="

$url = "$base/LeadManagement.svc/Lead/Bulk/UpdateV2?accessKey=$accessKey&secretKey=$secretKey"
$successTotal = 0; $failTotal = 0
$batches = [Math]::Ceiling($rishiLeads.Count / 25)
for ($b = 0; $b -lt $batches; $b++) {
    $chunk = $rishiLeads | Select-Object -Skip ($b * 25) -First 25
    $leadPropsList = $chunk | ForEach-Object {
        @{ Fields = @(
            @{ Attribute = "ProspectId"; Value = $_.Id },
            @{ Attribute = "OwnerId"; Value = $rishiId }
        ) }
    }
    $body = @{ SearchByKey = "ProspectId"; Options = @{ PushNonExistentLeadsToUnProcessedList = $true }; LeadPropertiesList = @($leadPropsList) } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json"
        $successTotal += $resp.Status.SuccessCount
        $failTotal += $resp.Status.FailureCount
        if ($resp.Status.FailureCount -gt 0) { Write-Log "Batch $b : FAILURES -> $($resp | ConvertTo-Json -Depth 5 -Compress)" }
    } catch {
        $failTotal += $chunk.Count
        Write-Log "Batch $b : EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)"
    }
    if ($b % 10 -eq 0) { Write-Log "Rollback progress: batch $b/$batches  success=$successTotal fail=$failTotal" }
    Start-Sleep -Milliseconds 1100
}
Write-Log "Rollback DONE. success=$successTotal fail=$failTotal total=$($rishiLeads.Count)"
Write-Log "=== Run complete ==="
