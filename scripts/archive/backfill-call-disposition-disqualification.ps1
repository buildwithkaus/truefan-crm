<#
.SYNOPSIS
  Phase 5 step 2: backfill the new mx_Call_Disposition and mx_Disqualification_Reason
  Lead fields from the historical ProspectStage value, without touching ProspectStage
  itself (additive-only migration, see CLAUDE.md and memory/06-stage-taxonomy-design.md).

.DESCRIPTION
  For each ProspectStage value that maps to Call Disposition or Disqualification Reason,
  fetches every Lead currently on that value and bulk-writes the same string into the new
  field. ProspectStage is read-only in this script - never updated. Reps keep using the
  live field unchanged until Phase 5 step 3 (post rep-training cutover).

  LeadManagement.svc/Leads.Get pagination caps at 1000 rows/page regardless of requested
  PageSize - always paginate with PageIndex until a page returns fewer than 1000 rows,
  never trust a single large-PageSize call (see PROJECT_PLAN.md Phase 5 sizing history).

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/backfill-call-disposition-disqualification.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "call-disposition-disqualification_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

$dispositionValues = @("RNR", "Didn't Picked", "Call me Later", "Switched Off/Not Reachable", "Wrong Number", "Follow Up")
$disqualValues = @("Low Budget", "Supply Issue", "Conflict", "No Requirement of Celeb in Ads", "Does not want AI", "Just Enquiring No Intent", "Invalid/Junk", "Not Active After First Conversation", "B2B-Disqualified")

function Get-LeadIdsForStage($stageValue) {
    $ids = @()
    $page = 1
    while ($true) {
        $resp = Invoke-LsqLeadSearch -Filter @{ LookupName = "ProspectStage"; LookupValue = $stageValue; SqlOperator = "=" } -ColumnsCsv "ProspectID" -PageIndex $page -PageSize 1000
        if (-not $resp -or $resp.Count -eq 0) { break }
        $ids += $resp | ForEach-Object { $_.ProspectID }
        if ($resp.Count -lt 1000) { break }
        $page++
        Start-Sleep -Milliseconds 300
    }
    return $ids
}

Write-Log "=== Backfill run started ==="

# Build the full {ProspectId, Attribute, Value} worklist before writing anything
$worklist = @()
foreach ($v in $dispositionValues) {
    $ids = Get-LeadIdsForStage $v
    Write-Log "Call Disposition source '$v': $($ids.Count) leads"
    foreach ($id in $ids) { $worklist += [pscustomobject]@{ ProspectId = $id; Attribute = "mx_Call_Disposition"; Value = $v } }
}
foreach ($v in $disqualValues) {
    $ids = Get-LeadIdsForStage $v
    Write-Log "Disqualification Reason source '$v': $($ids.Count) leads"
    foreach ($id in $ids) { $worklist += [pscustomobject]@{ ProspectId = $id; Attribute = "mx_Disqualification_Reason"; Value = $v } }
}
Write-Log "Worklist built: $($worklist.Count) total lead updates"

# Backup the worklist before writing anything (rollback record, gitignored)
$worklist | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dataDir "call-disposition-disqualification_worklist_BACKUP.json")

$url = "$base/LeadManagement.svc/Lead/Bulk/UpdateV2?accessKey=$accessKey&secretKey=$secretKey"
$successTotal = 0; $failTotal = 0
$batches = [Math]::Ceiling($worklist.Count / 25)
for ($b = 0; $b -lt $batches; $b++) {
    $chunk = $worklist | Select-Object -Skip ($b * 25) -First 25
    $leadPropsList = $chunk | ForEach-Object {
        @{ Fields = @(
            @{ Attribute = "ProspectId"; Value = $_.ProspectId },
            @{ Attribute = $_.Attribute; Value = $_.Value }
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
    if ($b % 20 -eq 0) { Write-Log "Backfill progress: batch $b/$batches  success=$successTotal fail=$failTotal" }
    Start-Sleep -Milliseconds 1100
}
Write-Log "Backfill DONE. success=$successTotal fail=$failTotal total=$($worklist.Count)"
Write-Log "=== Run complete ==="
