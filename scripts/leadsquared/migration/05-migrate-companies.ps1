<#
.SYNOPSIS
  Writes the new Company stage (plus Future Prospect reason and the contact-resourcing flag)
  from migration_worklist_companies.json.

.DESCRIPTION
  Uses CompanyManagement.svc/Company.Update, which matches on the internal CompanyId and is
  precise. The BULK company endpoint is deliberately NOT used: it matches on CompanyName and
  is create-OR-update, so a name mismatch silently creates a duplicate company. Single-record
  updates are slower but safe.

  This is the slowest step in the migration - one API call per company. Two mitigations:
    * Rows already at their target stage are skipped entirely.
    * If the UI rename of the most common value has been done first (see MANUAL_STEPS.md),
      the majority of companies are already correct and are skipped here for free.

  Idempotent and resumable via a checkpoint file.

.PARAMETER Execute
  Required to write.

.PARAMETER ThrottleMs
  300ms respects the account-wide 20 calls/5s cap with headroom. Do not run anything else
  against the API concurrently.

.NOTES
  pwsh ./scripts/leadsquared/migration/05-migrate-companies.ps1            # dry run
  pwsh ./scripts/leadsquared/migration/05-migrate-companies.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$ThrottleMs = 300
)

. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_companies_log.txt"
$checkpointPath = Join-Path $dataDir "migration_companies_checkpoint.txt"
$worklistPath = Join-Path $dataDir "migration_worklist_companies.json"

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "=== Company stage migration [$mode] ===" $logPath

if (-not (Test-Path $worklistPath)) { throw "Worklist missing. Run 02-build-worklist.ps1 first." }
$work = @(Get-Content $worklistPath -Raw | ConvertFrom-Json)
Write-LsqLog "Worklist rows: $($work.Count)" $logPath

# Read current stages so rows already correct can be skipped. This is what makes the UI
# rename optimisation pay off - after a rename most rows need no write at all.
Write-LsqLog "Reading current company stages to compute the delta..." $logPath
$current = @{}
$page = 1
while ($true) {
    $resp = Invoke-LsqCompanySearch -CompanyTypeName "Company" -PageIndex $page -PageSize 1000
    if (-not $resp.Companies -or $resp.Companies.Count -eq 0) { break }
    foreach ($c in $resp.Companies) {
        $props = @{}
        foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
        if ($props.CompanyId) { $current[$props.CompanyId] = $props.Stage }
    }
    if ($resp.Companies.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 300
}
Write-LsqLog "Current stages read for $($current.Count) companies." $logPath

$pending = @($work | Where-Object {
    -not $current.ContainsKey($_.CompanyId) -or $current[$_.CompanyId] -ne $_.NewStage
})
Write-LsqLog "Already at target stage (skipped): $($work.Count - $pending.Count)" $logPath
Write-LsqLog "Companies needing a write: $($pending.Count)" $logPath

$estMin = [Math]::Round(($pending.Count * $ThrottleMs) / 60000, 1)
Write-LsqLog "Estimated run time: ~$estMin min at ${ThrottleMs}ms per record" $logPath

if (-not $Execute) {
    $dist = $pending | Group-Object NewStage | Sort-Object Count -Descending
    Write-LsqLog "--- Would write these target stages ---" $logPath
    foreach ($g in $dist) { Write-LsqLog ("  {0,-18} {1}" -f $g.Name, $g.Count) $logPath }
    Write-LsqLog "" $logPath
    Write-LsqLog "TIP: the largest bucket above is the one to apply as a UI RENAME of the" $logPath
    Write-LsqLog "existing 'Prospect' value before running this - it removes those writes entirely." $logPath
    Write-LsqLog "DRY RUN complete - nothing written. Re-run with -Execute." $logPath
    return
}

$startIdx = 0
if (Test-Path $checkpointPath) {
    $startIdx = [int](Get-Content $checkpointPath -Raw).Trim()
    Write-LsqLog "Resuming from index $startIdx (checkpoint found)." $logPath
}

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
$okCount = 0; $failCount = 0

for ($i = $startIdx; $i -lt $pending.Count; $i++) {
    $row = $pending[$i]

    $fields = @("{`"Attribute`":`"Stage`",`"Value`":`"$($row.NewStage)`"}")
    if ($row.FutureProspectReason) {
        $fields += "{`"Attribute`":`"Future_Prospect_Reason`",`"Value`":`"$($row.FutureProspectReason)`"}"
    }
    if ($row.NeedsContactResourcing) {
        $fields += "{`"Attribute`":`"Needs_Contact_Resourcing`",`"Value`":`"Yes`"}"
    }
    # Built as a literal string, not via ConvertTo-Json: PowerShell 5.1 collapses a
    # single-element array into a bare object, which this API rejects. See CLAUDE.md.
    $body = "[" + ($fields -join ",") + "]"

    $url = "$base/CompanyManagement.svc/Company.Update?accessKey=$ak&secretKey=$sk&companyId=$($row.CompanyId)"
    try {
        $r = Invoke-LsqPost -Uri $url -JsonBody $body
        if ($r.Status -eq "Success") { $okCount++ }
        else { $failCount++; Write-LsqLog "Company $($row.CompanyId) FAILURE -> $($r | ConvertTo-Json -Compress)" $logPath }
    } catch {
        $failCount++
        Write-LsqLog "Company $($row.CompanyId) EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }

    Set-Content -Path $checkpointPath -Value ($i + 1)
    if ($i % 250 -eq 0) { Write-LsqLog "Progress: $i/$($pending.Count)  ok=$okCount fail=$failCount" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Company migration DONE. ok=$okCount fail=$failCount of $($pending.Count)." $logPath
if ($failCount -eq 0) {
    Remove-Item $checkpointPath -ErrorAction SilentlyContinue
    Write-LsqLog "Checkpoint cleared (clean run)." $logPath
} else {
    Write-LsqLog "Checkpoint retained - re-run to retry failures." $logPath
}
Write-LsqLog "=== Company stage migration complete [$mode] ===" $logPath
