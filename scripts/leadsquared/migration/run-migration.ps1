<#
.SYNOPSIS
  ONE COMMAND. Runs the entire stage restructure migration end to end, unattended.

.DESCRIPTION
  Sequence:
    1. Pre-flight   - config present, fields exist, manual UI steps confirmed, no other
                      script running against the API
    2. Worklist     - enumerate live values, assert map completeness, build worklists
    3. Backup       - full current-state snapshot (this is the rollback)
    4. Leads        - write new contact stages + reasons/categories/dispositions/segments
    5. Companies    - write new company stages + future-prospect reasons
    6. Opportunities- create deals for primary contacts at Prospect/Customer
    7. Verify       - independent re-fetch, reconciliation, cross-object consistency

  Steps run STRICTLY IN SEQUENCE and never concurrently. The LeadSquared rate limit is
  ACCOUNT-WIDE (20 calls/5s), and running two scripts at once has already caused 23 silent
  write failures on this account. Do not "speed it up" by parallelising.

  Every step is idempotent and checkpointed. If the run dies at 3am, re-running this same
  command resumes from where it stopped rather than starting over.

.PARAMETER Execute
  REQUIRED for any write. Without it the whole pipeline runs in dry-run: worklist and backup
  are real (both are read-only anyway), and every writer reports what it would do.

.PARAMETER SkipBackup
  Only for a resumed run where the backup already completed. Never use on a first run.

.PARAMETER ConfirmManualSteps
  Asserts the UI-only prerequisites in MANUAL_STEPS.md are done. -Execute refuses to run
  without it, because writing a stage value that does not exist in the dropdown fails on
  every single record.

.EXAMPLE
  # Rehearsal - safe any time, writes nothing:
  pwsh ./scripts/leadsquared/migration/run-migration.ps1

  # The real thing, unattended overnight:
  pwsh ./scripts/leadsquared/migration/run-migration.ps1 -Execute -ConfirmManualSteps
#>

param(
    [switch]$Execute,
    [switch]$SkipBackup,
    [switch]$ConfirmManualSteps
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_MASTER_log.txt"
$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
$started = Get-Date

Write-LsqLog "############################################################" $logPath
Write-LsqLog "### STAGE RESTRUCTURE MIGRATION - [$mode]" $logPath
Write-LsqLog "### Started $started" $logPath
Write-LsqLog "############################################################" $logPath

# ---------------------------------------------------------------------------------------
# Step 1: pre-flight
# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog ">>> STEP 1/7  Pre-flight checks" $logPath

$cfg = Import-LsqConfig
foreach ($k in @("LSQ_ACCESS_KEY", "LSQ_SECRET_KEY", "LSQ_API_HOST")) {
    if ([string]::IsNullOrWhiteSpace($cfg[$k])) { throw "Pre-flight FAILED: $k missing from config\.env" }
}
Write-LsqLog "  Config OK" $logPath

if ($Execute -and -not $ConfirmManualSteps) {
    Write-LsqLog "" $logPath
    Write-LsqLog "REFUSING TO RUN. -Execute requires -ConfirmManualSteps." $logPath
    Write-LsqLog "The UI-only steps below must be done FIRST - writing a stage value that does" $logPath
    Write-LsqLog "not exist in the dropdown fails on every record:" $logPath
    foreach ($s in $Script:ManualFieldSteps) { Write-LsqLog "  [ ] $s" $logPath }
    throw "Manual prerequisites not confirmed. See MANUAL_STEPS.md."
}

# A stale process left running old dot-sourced code will happily keep writing failures into
# the same log and make a fixed bug look unfixed. Check by command line, not process name -
# several unrelated powershell.exe processes exist for IDE tooling.
$others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'leadsquared' -and $_.ProcessId -ne $PID })
if ($others.Count -gt 0) {
    Write-LsqLog "  WARNING: $($others.Count) other LeadSquared script process(es) appear to be running:" $logPath
    foreach ($o in $others) { Write-LsqLog "    PID $($o.ProcessId): $($o.CommandLine)" $logPath }
    throw "Another script is using the API. The rate limit is account-wide - stop it before running this."
}
Write-LsqLog "  No competing API processes" $logPath

if ($Execute) {
    $meta = Invoke-RestMethod -Uri (Get-LsqUrl "LeadManagement.svc/LeadsMetaData.Get") -Method Get
    $have = @{}
    foreach ($f in $meta) { $have[$f.SchemaName] = $true }
    $missing = @()
    foreach ($f in $Script:NewLeadFields) { if (-not $have.ContainsKey($f.SchemaName)) { $missing += $f.SchemaName } }
    if ($missing.Count -gt 0) {
        throw "Pre-flight FAILED: Lead fields not created yet: $($missing -join ', '). Run 01-create-fields.ps1 -Execute first."
    }
    Write-LsqLog "  All required Lead fields exist" $logPath
}

# ---------------------------------------------------------------------------------------
# Helper to run a step and fail loudly
# ---------------------------------------------------------------------------------------
function Invoke-Step {
    param([string]$Number, [string]$Name, [string]$Script, [string[]]$Arguments = @())
    Write-LsqLog "" $logPath
    Write-LsqLog ">>> STEP $Number  $Name" $logPath
    $stepStart = Get-Date
    $path = Join-Path $PSScriptRoot $Script
    & $path @Arguments
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Step $Number ($Name) exited with code $LASTEXITCODE" }
    $mins = [Math]::Round(((Get-Date) - $stepStart).TotalMinutes, 1)
    Write-LsqLog "<<< STEP $Number complete in $mins min" $logPath
}

$writeArgs = if ($Execute) { @("-Execute") } else { @() }

# ---------------------------------------------------------------------------------------
# Steps 2-7
# ---------------------------------------------------------------------------------------
Invoke-Step "2/7" "Build worklists (read-only, aborts on any unmapped value)" "02-build-worklist.ps1"

if ($SkipBackup) {
    Write-LsqLog "" $logPath
    Write-LsqLog ">>> STEP 3/7  Backup SKIPPED by request" $logPath
} else {
    Invoke-Step "3/7" "Backup current state (this is the rollback)" "03-backup.ps1"
}

Invoke-Step "4/7" "Migrate Lead stages"      "04-migrate-leads.ps1"        $writeArgs
Invoke-Step "5/7" "Migrate Company stages"   "05-migrate-companies.ps1"    $writeArgs
Invoke-Step "6/7" "Create Opportunities"     "06-create-opportunities.ps1" $writeArgs

if ($Execute) {
    Invoke-Step "7/7" "Verify (independent re-fetch)" "07-verify.ps1"
} else {
    Write-LsqLog "" $logPath
    Write-LsqLog ">>> STEP 7/7  Verification skipped - nothing was written in dry run" $logPath
}

# ---------------------------------------------------------------------------------------
$elapsed = [Math]::Round(((Get-Date) - $started).TotalMinutes, 1)
Write-LsqLog "" $logPath
Write-LsqLog "############################################################" $logPath
Write-LsqLog "### MIGRATION [$mode] FINISHED in $elapsed min" $logPath
if ($Execute) {
    Write-LsqLog "### Read migration_verify_log.txt before briefing reps." $logPath
    $stampFile = Join-Path $dataDir "migration_LAST_BACKUP_STAMP.txt"
    if (Test-Path $stampFile) {
        Write-LsqLog "### Rollback set: migration_BACKUP_*_$((Get-Content $stampFile -Raw).Trim()).json" $logPath
    }
} else {
    Write-LsqLog "### Nothing was written. Review the worklists in data/, then re-run with:" $logPath
    Write-LsqLog "###   -Execute -ConfirmManualSteps" $logPath
}
Write-LsqLog "############################################################" $logPath
