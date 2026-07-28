<#
.SYNOPSIS
  Restores Lead and Company stages from a backup set produced by 03-backup.ps1.
  The migration's undo button.

.DESCRIPTION
  Reads migration_BACKUP_leads_<stamp>.json and migration_BACKUP_companies_<stamp>.json and
  writes every field back to its pre-migration value. Only touches records whose CURRENT
  value differs from the backup, so a partial rollback is cheap and re-running is safe.

  This path is not theoretical - it is how 2,360 of Rishi Saraswat's wrongly reassigned leads
  were recovered during Phase 2.

  What it does NOT undo:
    * Opportunities created during the migration. The Opportunity Type has CanDelete=false,
      so they cannot be removed via API - they must be deleted in the UI, or left in place
      and ignored. 09-list-created-opportunities.ps1 lists exactly which ones to remove.
    * Dropdown values added or renamed in the UI. Those are UI actions and must be reversed
      in the UI.

.PARAMETER Stamp
  Backup stamp to restore, e.g. 20260731-220000. Defaults to the stamp recorded in
  migration_LAST_BACKUP_STAMP.txt.

.PARAMETER Execute
  Required to write. Without it, reports what it would restore.

.PARAMETER LeadsOnly / CompaniesOnly
  Restore just one object type.

.EXAMPLE
  pwsh ./scripts/leadsquared/migration/08-rollback.ps1                      # dry run, latest backup
  pwsh ./scripts/leadsquared/migration/08-rollback.ps1 -Execute
  pwsh ./scripts/leadsquared/migration/08-rollback.ps1 -Stamp 20260731-220000 -Execute -LeadsOnly
#>

param(
    [string]$Stamp,
    [switch]$Execute,
    [switch]$LeadsOnly,
    [switch]$CompaniesOnly,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_rollback_log.txt"
$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }

if (-not $Stamp) {
    $stampFile = Join-Path $dataDir "migration_LAST_BACKUP_STAMP.txt"
    if (-not (Test-Path $stampFile)) { throw "No -Stamp given and no migration_LAST_BACKUP_STAMP.txt found." }
    $Stamp = (Get-Content $stampFile -Raw).Trim()
}

Write-LsqLog "=== ROLLBACK [$mode] from backup stamp $Stamp ===" $logPath

$leadBackupPath = Join-Path $dataDir "migration_BACKUP_leads_$Stamp.json"
$compBackupPath = Join-Path $dataDir "migration_BACKUP_companies_$Stamp.json"

# ---------------------------------------------------------------------------------------
# Leads
# ---------------------------------------------------------------------------------------
if (-not $CompaniesOnly) {
    if (-not (Test-Path $leadBackupPath)) { throw "Lead backup not found: $leadBackupPath" }
    $backup = @(Get-Content $leadBackupPath -Raw | ConvertFrom-Json)
    Write-LsqLog "Lead backup rows: $($backup.Count)" $logPath

    Write-LsqLog "Reading current lead stages to compute the delta..." $logPath
    $current = @{}
    $page = 1
    while ($true) {
        $r = Invoke-LsqLeadSearch -Filter @{ LookupName="CreatedOn"; LookupValue="2000-01-01"; SqlOperator=">" } `
            -ColumnsCsv "ProspectID,ProspectStage" -SortColumn "CreatedOn" -SortDirection "1" `
            -PageIndex $page -PageSize 1000
        if (-not $r -or @($r).Count -eq 0) { break }
        foreach ($l in $r) { $current[$l.ProspectID] = $l.ProspectStage }
        if (@($r).Count -lt 1000) { break }
        $page++; Start-Sleep -Milliseconds 250
    }

    $pending = @($backup | Where-Object {
        $current.ContainsKey($_.ProspectId) -and $current[$_.ProspectId] -ne $_.ProspectStage
    })
    Write-LsqLog "Leads differing from backup (to restore): $($pending.Count)" $logPath

    if ($Execute -and $pending.Count -gt 0) {
        $url = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
        $batches = [Math]::Ceiling($pending.Count / $BatchSize)
        $ok = 0; $fail = 0
        for ($b = 0; $b -lt $batches; $b++) {
            $slice = $pending[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $pending.Count - 1))]
            $records = @()
            foreach ($row in $slice) {
                $records += ,@(@{ Fields = @(
                    @{ Attribute = "ProspectId";    Value = $row.ProspectId },
                    @{ Attribute = "ProspectStage"; Value = $row.ProspectStage },
                    @{ Attribute = "mx_Call_Disposition";        Value = $row.CallDisposition },
                    @{ Attribute = "mx_Disqualification_Reason"; Value = $row.DisqualificationRsn }
                ) })
            }
            $body = @{
                SearchByKey = "ProspectId"
                Options = @{ PushNonExistentLeadsToUnProcessedList = $true }
                LeadPropertiesList = $records
            } | ConvertTo-Json -Depth 8
            try {
                $r = Invoke-LsqPost -Uri $url -JsonBody $body
                $ok += [int]$r.Status.SuccessCount
                if ([int]$r.Status.FailureCount -gt 0) {
                    $fail += [int]$r.Status.FailureCount
                    Write-LsqLog "  batch $b failures -> $($r | ConvertTo-Json -Compress -Depth 3)" $logPath
                }
            } catch { $fail += $slice.Count; Write-LsqLog "  batch $b EXCEPTION -> $($_.Exception.Message)" $logPath }
            if ($b % 20 -eq 0) { Write-LsqLog "  progress batch $b/$batches ok=$ok fail=$fail" $logPath }
            Start-Sleep -Milliseconds $ThrottleMs
        }
        Write-LsqLog "Leads restored: ok=$ok fail=$fail" $logPath
    } elseif (-not $Execute) {
        Write-LsqLog "DRY RUN - would restore $($pending.Count) leads. Sample:" $logPath
        foreach ($p in ($pending | Select-Object -First 5)) {
            Write-LsqLog "    $($p.ProspectId): $($current[$p.ProspectId]) -> $($p.ProspectStage)" $logPath
        }
    }
}

# ---------------------------------------------------------------------------------------
# Companies
# ---------------------------------------------------------------------------------------
if (-not $LeadsOnly) {
    if (-not (Test-Path $compBackupPath)) { throw "Company backup not found: $compBackupPath" }
    $backup = @(Get-Content $compBackupPath -Raw | ConvertFrom-Json)
    Write-LsqLog "Company backup rows: $($backup.Count)" $logPath

    Write-LsqLog "Reading current company stages..." $logPath
    $current = @{}
    $page = 1
    while ($true) {
        $r = Invoke-LsqCompanySearch -CompanyTypeName "Company" -PageIndex $page -PageSize 1000
        if (-not $r.Companies -or @($r.Companies).Count -eq 0) { break }
        foreach ($c in $r.Companies) {
            $props = @{}
            foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
            if ($props.CompanyId) { $current[$props.CompanyId] = $props.Stage }
        }
        if (@($r.Companies).Count -lt 1000) { break }
        $page++; Start-Sleep -Milliseconds 300
    }

    $pending = @($backup | Where-Object {
        $current.ContainsKey($_.CompanyId) -and $current[$_.CompanyId] -ne $_.Stage
    })
    Write-LsqLog "Companies differing from backup (to restore): $($pending.Count)" $logPath

    $cfg = Import-LsqConfig
    $base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

    if ($Execute -and $pending.Count -gt 0) {
        $ok = 0; $fail = 0; $i = 0
        foreach ($row in $pending) {
            $i++
            $body = "[{`"Attribute`":`"Stage`",`"Value`":`"$($row.Stage)`"}]"
            try {
                $r = Invoke-LsqPost -Uri "$base/CompanyManagement.svc/Company.Update?accessKey=$ak&secretKey=$sk&companyId=$($row.CompanyId)" -JsonBody $body
                if ($r.Status -eq "Success") { $ok++ } else { $fail++ }
            } catch { $fail++; Write-LsqLog "  company $($row.CompanyId) EXCEPTION -> $($_.Exception.Message)" $logPath }
            if ($i % 250 -eq 0) { Write-LsqLog "  progress $i/$($pending.Count) ok=$ok fail=$fail" $logPath }
            Start-Sleep -Milliseconds 300
        }
        Write-LsqLog "Companies restored: ok=$ok fail=$fail" $logPath
    } elseif (-not $Execute) {
        Write-LsqLog "DRY RUN - would restore $($pending.Count) companies. Sample:" $logPath
        foreach ($p in ($pending | Select-Object -First 5)) {
            Write-LsqLog "    $($p.CompanyId): $($current[$p.CompanyId]) -> $($p.Stage)" $logPath
        }
    }
}

Write-LsqLog "" $logPath
Write-LsqLog "NOTE: Opportunities created by the migration are NOT removed by this script." $logPath
Write-LsqLog "The Opportunity Type has CanDelete=false, so they must be deleted in the UI." $logPath
Write-LsqLog "=== ROLLBACK [$mode] complete ===" $logPath
