<#
.SYNOPSIS
  Phase 4, write step: apply the enrichment worklist built by
  build-company-enrichment-map.ps1 to the live Company records.

.DESCRIPTION
  Reads data/company_enrichment_worklist.json (CompanyId + a dict of field->value to
  backfill, already diffed against current state so every entry is a genuinely-empty
  field getting a value for the first time - see build-company-enrichment-map.ps1).
  One Company.Update call per company, carrying all its field updates in a single
  CompanyProperties array (fewer calls than one-call-per-field).

  Do not run this concurrently with another script hitting CompanyManagement.svc/
  Company.Update (e.g. reassign-departed-owners.ps1) - both share the same rate-limit
  bucket and will throttle each other. Confirm the other job's log shows "Run complete"
  first.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/apply-company-enrichment.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$worklistPath = Join-Path $dataDir "company_enrichment_worklist.json"
$logPath = Join-Path $dataDir "company_enrichment_apply_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

# UTF-8-safe POST - non-ASCII characters (accents, deg/reg symbols, etc, common in real
# Website/CIN/Budget source values) get mis-encoded by plain Invoke-RestMethod under
# Windows PowerShell 5.1, producing genuine (non-retryable) 400s from the server's UTF-8
# JSON parser. See CLAUDE.md "Fourth gotcha". Fixed here before running at scale.
function Invoke-LsqPostUtf8 {
    param([string]$Uri, [string]$JsonBody)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
    return Invoke-RestMethod -Uri $Uri -Method Post -Body $bytes -ContentType "application/json; charset=utf-8"
}

$worklist = Get-Content $worklistPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Log "=== Apply run started. Companies to update: $($worklist.Count) ==="

$successTotal = 0; $failTotal = 0; $i = 0
foreach ($item in $worklist) {
    $i++
    $props = $item.Updates.PSObject.Properties | ForEach-Object { @{ Attribute = $_.Name; Value = $_.Value } }
    $body = @{ CompanyProperties = @($props) } | ConvertTo-Json -Depth 6
    $url = "$base/CompanyManagement.svc/Company.Update?accessKey=$accessKey&secretKey=$secretKey&companyId=$($item.CompanyId)"
    try {
        $resp = Invoke-LsqPostUtf8 -Uri $url -JsonBody $body
        if ($resp.Status -eq "Success") { $successTotal++ } else { $failTotal++; Write-Log "Company $($item.CompanyId): unexpected response $($resp | ConvertTo-Json -Compress)" }
    } catch {
        $failTotal++
        Write-Log "Company $($item.CompanyId): EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)"
    }
    if ($i % 200 -eq 0) { Write-Log "Apply progress: $i/$($worklist.Count)  success=$successTotal fail=$failTotal" }
    Start-Sleep -Milliseconds 400
}
Write-Log "Apply DONE. success=$successTotal fail=$failTotal total=$($worklist.Count)"
Write-Log "=== Run complete ==="
