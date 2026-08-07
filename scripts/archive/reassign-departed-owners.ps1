<#
.SYNOPSIS
  One-time migration: reassign all Leads and Companies owned by departed reps to Admin.

.DESCRIPTION
  Reads the pre-captured backup files (original owner is preserved there for audit/rollback)
  and reassigns OwnerId to Admin for every record.

  Leads   -> LeadManagement.svc/Lead/Bulk/UpdateV2 (25 records/call, ~1 call/sec pacing)
  Companies -> CompanyManagement.svc/Company.Update (single record/call - the bulk Company
               endpoint only matches by CompanyName and is create-OR-update, which risks
               silently creating a duplicate company on any name mismatch. Not worth the risk
               when we already have exact CompanyId for every record.)

  Both mechanisms were verified on live test records before this script was written:
  a single-record update + independent re-fetch confirmed the owner actually changed.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/reassign-departed-owners.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']
$adminOwnerId = "b5c423b7-096f-11ef-8d08-0261eba56ddf"  # Admin, admin.sales@true-fan.in

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$leadBackupPath = Join-Path $dataDir "departed_owner_leads_BACKUP.json"
$companyBackupPath = Join-Path $dataDir "departed_owner_companies_BACKUP.json"
$logPath = Join-Path $dataDir "reassignment_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

# ---------- Leads: bulk, 25/call ----------
function Reassign-Leads {
    $leads = Get-Content $leadBackupPath -Raw | ConvertFrom-Json
    Write-Log "Starting Lead reassignment: $($leads.Count) records"
    $url = "$base/LeadManagement.svc/Lead/Bulk/UpdateV2?accessKey=$accessKey&secretKey=$secretKey"
    $successTotal = 0; $failTotal = 0
    $batches = [Math]::Ceiling($leads.Count / 25)
    for ($b = 0; $b -lt $batches; $b++) {
        $chunk = $leads | Select-Object -Skip ($b * 25) -First 25
        $leadPropsList = $chunk | ForEach-Object {
            @{ Fields = @(
                @{ Attribute = "ProspectId"; Value = $_.Id },
                @{ Attribute = "OwnerId"; Value = $adminOwnerId }
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
        if ($b % 20 -eq 0) { Write-Log "Lead progress: batch $b/$batches  success=$successTotal fail=$failTotal" }
        Start-Sleep -Milliseconds 1100   # stay under bulk rate limit (5 calls/5s)
    }
    Write-Log "Lead reassignment DONE. success=$successTotal fail=$failTotal total=$($leads.Count)"
}

# ---------- Companies: single-record, no safe bulk path ----------
function Reassign-Companies {
    $companies = Get-Content $companyBackupPath -Raw | ConvertFrom-Json
    Write-Log "Starting Company reassignment: $($companies.Count) records"
    $successTotal = 0; $failTotal = 0
    $i = 0
    foreach ($c in $companies) {
        $i++
        $url = "$base/CompanyManagement.svc/Company.Update?accessKey=$accessKey&secretKey=$secretKey&companyId=$($c.CompanyId)"
        $body = '{"CompanyProperties":[{"Attribute":"OwnerId","Value":"' + $adminOwnerId + '"}]}'
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json"
            if ($resp.Status -eq "Success") { $successTotal++ } else { $failTotal++; Write-Log "Company $($c.CompanyId): unexpected response $($resp | ConvertTo-Json -Compress)" }
        } catch {
            $failTotal++
            Write-Log "Company $($c.CompanyId): EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)"
        }
        if ($i % 200 -eq 0) { Write-Log "Company progress: $i/$($companies.Count)  success=$successTotal fail=$failTotal" }
        Start-Sleep -Milliseconds 400
    }
    Write-Log "Company reassignment DONE. success=$successTotal fail=$failTotal total=$($companies.Count)"
}

Write-Log "=== Departed-owner reassignment run started ==="
Reassign-Leads
Reassign-Companies
Write-Log "=== Run complete ==="
