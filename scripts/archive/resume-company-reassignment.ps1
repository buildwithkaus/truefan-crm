<#
.SYNOPSIS
  Resume Phase 2's Company reassignment after the Rishi Saraswat incident
  (see memory/05-departed-owner-reassignment.md). Companies-only - does NOT touch Leads,
  since Leads are already complete and correct (including the Rishi rollback) and
  re-running Reassign-Leads from the original script would silently undo that rollback.

.DESCRIPTION
  Reads data/departed_owner_companies_BACKUP_corrected.json (the original 10,972-row
  backup with the 1,868 rows mislabeled "Piyush Das Pattnaik" - actually Rishi Saraswat's
  real OwnerId - excluded). Skips any company already confirmed Admin-owned (from the
  partial run that got to 3,800/10,972 before being paused), so this only writes to
  companies that still need it.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/resume-company-reassignment.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']
$adminOwnerId = "b5c423b7-096f-11ef-8d08-0261eba56ddf"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "reassignment_resume_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

$corrected = Get-Content (Join-Path $dataDir "departed_owner_companies_BACKUP_corrected.json") -Raw | ConvertFrom-Json
Write-Log "=== Resume run started. Corrected worklist: $($corrected.Count) companies ==="

# Find which are already Admin-owned (from the partial run before the pause), skip those
$adminOwnedIds = @{}
$page = 1
while ($true) {
    $resp = Invoke-LsqCompanySearch -FilterBy @{ LookupName = "OwnerId"; LookupValue = $adminOwnerId; SqlOperator = "=" } -PageIndex $page -PageSize 1000 -ColumnsCsv "CompanyId"
    if (-not $resp.Companies -or $resp.Companies.Count -eq 0) { break }
    foreach ($c in $resp.Companies) {
        $props = @{}
        foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
        if ($props.CompanyId) { $adminOwnedIds[$props.CompanyId] = $true }
    }
    if ($resp.Companies.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 200
}
Write-Log "Currently Admin-owned companies (already done, will skip): $($adminOwnedIds.Count)"

$remaining = $corrected | Where-Object { -not $adminOwnedIds.ContainsKey($_.CompanyId) }
Write-Log "Remaining to process: $($remaining.Count)"

$successTotal = 0; $failTotal = 0; $i = 0
foreach ($c in $remaining) {
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
    if ($i % 200 -eq 0) { Write-Log "Resume progress: $i/$($remaining.Count)  success=$successTotal fail=$failTotal" }
    Start-Sleep -Milliseconds 400
}
Write-Log "Resume DONE. success=$successTotal fail=$failTotal total=$($remaining.Count)"
Write-Log "=== Run complete ==="
