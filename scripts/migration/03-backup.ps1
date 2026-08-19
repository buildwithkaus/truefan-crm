<#
.SYNOPSIS
  READ-ONLY. Captures the current stage state of every Lead, Company and Opportunity before
  the migration writes anything. This file IS the rollback - do not skip it.

.DESCRIPTION
  Writes timestamped backups to data/:
    migration_BACKUP_leads_<stamp>.json          ProspectId + current ProspectStage + the
                                                 three fields the migration overwrites
    migration_BACKUP_companies_<stamp>.json      CompanyId + current Stage
    migration_BACKUP_opportunities_<stamp>.json  per-lead opportunity stage state

  Rollback is re-running the writers with source and target swapped against these files.
  That path is tested, not theoretical - it is how 2,360 of Rishi Saraswat's wrongly
  reassigned leads were recovered during Phase 2.

.NOTES
  pwsh ./scripts/leadsquared/migration/03-backup.ps1
  Safe at any time - reads only. Takes a few minutes.
#>

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "migration_backup_log.txt"

Write-LsqLog "=== Backup started (READ-ONLY) stamp=$stamp ===" $logPath

# A FAILED request must never be mistaken for "end of data". These loops stop when a page comes
# back short or empty, so a transient network error - which returns nothing - silently ends the
# backup early and looks exactly like a clean finish. Hit live 2026-07-29: a DNS failure at page
# 25 ended the run at 25,000 leads. The size guard below caught that one, but a blip at page 85
# would have yielded ~85,000 - over the 80,000 threshold - and written a silently incomplete
# backup that passed every check. So: retry, and if a page genuinely cannot be fetched, ABORT
# the whole backup rather than return a short one.
function Get-LeadPageOrThrow {
    param([int]$PageIndex, [int]$MaxAttempts = 5)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $failure = $null
        $result = $null
        try {
            # Expand-LsqRows: the page can also arrive nested one level deeper, where .Count
            # reads 1 - same silent-undercount family. See common.ps1.
            $result = Invoke-LsqLeadSearch -ErrorAction Stop `
                -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
                -ColumnsCsv "ProspectID,ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason,IsPrimaryContact,RelatedCompanyId" `
                -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $PageIndex -PageSize 1000
        } catch {
            $failure = $_
        }
        if (-not $failure) { return @(Expand-LsqRows $result) }
        Write-LsqLog "  lead page $PageIndex attempt $attempt/$MaxAttempts FAILED -> $($failure.Exception.Message)" $logPath
        if ($attempt -eq $MaxAttempts) {
            throw "Backup ABORTED: lead page $PageIndex failed $MaxAttempts times (last error: $($failure.Exception.Message)). Refusing to treat a failed request as the end of the data - that would produce a short backup that looks complete."
        }
        Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
    }
}

# --- Leads -----------------------------------------------------------------------------
# List, not @(). "$arr += x" reallocates and copies the whole array each time, so appending
# ~87,000 leads is O(n^2) - that alone took 8 minutes of pure CPU on 2026-07-30 with the API
# idle. List[object].Add() is amortised O(1).
$leadBackup = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Get-LeadPageOrThrow -PageIndex $page)
    if (-not $resp -or $resp.Count -eq 0) { break }
    foreach ($l in $resp) {
        [void]$leadBackup.Add([pscustomobject]@{
            ProspectId          = $l.ProspectID
            ProspectStage       = $l.ProspectStage
            CallDisposition     = $l.mx_Call_Disposition
            DisqualificationRsn = $l.mx_Disqualification_Reason
            IsPrimaryContact    = $l.IsPrimaryContact
            CompanyId           = $l.RelatedCompanyId
        })
    }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
# This backup is the ONLY thing 08-rollback can restore from, so a silently-short capture is
# unrecoverable: the migration would proceed believing it had a safety net that covers 1 record.
# memory/01 puts the account at 86,628 leads (2026-07-28); allow for churn, not a large shortfall.
$MinExpectedLeads = 80000
if ($leadBackup.Count -lt $MinExpectedLeads) {
    throw "Lead backup captured only $($leadBackup.Count) of ~86628 expected leads. REFUSING to write a partial backup - a migration run against this file would have no usable rollback. Re-run; if it repeats, do not proceed with the migration."
}
$leadPath = Join-Path $dataDir "migration_BACKUP_leads_$stamp.json"
$leadBackup | ConvertTo-Json -Depth 4 | Set-Content -Path $leadPath
Write-LsqLog "Leads backed up: $($leadBackup.Count) -> $leadPath" $logPath

# --- Companies -------------------------------------------------------------------------
# Company.Get's Include_CSV is picky about exact field names; fetch full records and read
# companyPropertyList instead of guessing a column list.
function Get-CompanyPageOrThrow {
    param([int]$PageIndex, [int]$MaxAttempts = 5)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $failure = $null
        $result = $null
        try {
            $result = Invoke-LsqCompanySearch -ErrorAction Stop -CompanyTypeName "Company" -PageIndex $PageIndex -PageSize 1000
        } catch {
            $failure = $_
        }
        if (-not $failure) { return $result }
        Write-LsqLog "  company page $PageIndex attempt $attempt/$MaxAttempts FAILED -> $($failure.Exception.Message)" $logPath
        if ($attempt -eq $MaxAttempts) {
            throw "Backup ABORTED: company page $PageIndex failed $MaxAttempts times (last error: $($failure.Exception.Message)). Refusing to treat a failed request as the end of the data."
        }
        Start-Sleep -Seconds ([Math]::Min(30, 5 * $attempt))
    }
}

$companyBackup = New-Object System.Collections.Generic.List[object]   # see the $leadBackup note
$page = 1
while ($true) {
    $resp = Get-CompanyPageOrThrow -PageIndex $page
    if (-not $resp.Companies -or $resp.Companies.Count -eq 0) { break }
    foreach ($c in $resp.Companies) {
        $props = @{}
        foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
        [void]$companyBackup.Add([pscustomobject]@{
            CompanyId   = $props.CompanyId
            CompanyName = $props.CompanyName
            Stage       = $props.Stage
            OwnerName   = $props.OwnerName
        })
    }
    if ($resp.Companies.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 300
}
$compPath = Join-Path $dataDir "migration_BACKUP_companies_$stamp.json"
$companyBackup | ConvertTo-Json -Depth 4 | Set-Content -Path $compPath
Write-LsqLog "Companies backed up: $($companyBackup.Count) -> $compPath" $logPath

# --- Opportunities ---------------------------------------------------------------------
# Opportunities are reached per-lead. Only leads that actually have one are worth querying,
# so this uses the worklist if present, otherwise the leads flagged IsPrimaryContact.
$oppBackup = @()
$oppSourcePath = Join-Path $dataDir "migration_worklist_opportunities.json"
$candidates = @()
if (Test-Path $oppSourcePath) {
    $candidates = (Get-Content $oppSourcePath -Raw | ConvertFrom-Json) | ForEach-Object { $_.ProspectId }
    Write-LsqLog "Opportunity candidates from worklist: $($candidates.Count)" $logPath
} else {
    $candidates = ($leadBackup | Where-Object { Test-LsqTrue $_.IsPrimaryContact }).ProspectId
    Write-LsqLog "No worklist found; using $($candidates.Count) IsPrimaryContact leads as candidates." $logPath
}

$cfg = Import-LsqConfig
# Read through Get-LsqOpportunitiesOfLead. This block used to walk $o.Fields, which
# GetOpportunitiesOfLead does not return - only GetOpportunityDetails does (gotcha 45). Every
# Status/Stage/Name below was therefore null, so the backup this rollback depends on was
# structurally empty while reporting a healthy row count. Fixed 2026-08-14.
$oppReadFailures = @()
foreach ($leadId in $candidates) {
    try {
        foreach ($o in (Get-LsqOpportunitiesOfLead -ProspectId $leadId -Config $cfg)) {
            $oppBackup += [pscustomobject]@{
                ProspectId    = $leadId
                OpportunityId = $o.OpportunityId
                Status        = $o.Status
                Stage         = $o.OppStage
                Name          = $o.Name
                OwnerId       = $o.OwnerId
            }
        }
    } catch {
        $oppReadFailures += $leadId
        Write-LsqLog "Opportunity read failed for lead $leadId -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }
    Start-Sleep -Milliseconds 300
}

# A backup with holes is worse than no backup, because it looks complete. 03b exists to fill
# these; say so loudly rather than letting the count below imply a clean run.
if ($oppReadFailures.Count -gt 0) {
    Write-LsqLog "WARNING: $($oppReadFailures.Count) lead(s) failed the opportunity read. This backup has HOLES - run 03b-backfill-opportunity-backup-gaps.ps1 before trusting it for rollback." $logPath
}

# Guard against a backup that silently captured nothing readable (hard rule 4). Every row
# carrying a null Stage is the exact signature of the $o.Fields bug returning.
$nullStage = @($oppBackup | Where-Object { [string]::IsNullOrWhiteSpace($_.Stage) }).Count
if ($oppBackup.Count -gt 0 -and $nullStage -eq $oppBackup.Count) {
    throw "All $($oppBackup.Count) backed-up opportunities have a blank Stage. That is the gotcha-45 signature, not a real account state. Refusing to write a useless backup."
}
$oppPath = Join-Path $dataDir "migration_BACKUP_opportunities_$stamp.json"
$oppBackup | ConvertTo-Json -Depth 4 | Set-Content -Path $oppPath
Write-LsqLog "Opportunities backed up: $($oppBackup.Count) -> $oppPath" $logPath

# Record the stamp so the orchestrator and any rollback can find this backup set.
Set-Content -Path (Join-Path $dataDir "migration_LAST_BACKUP_STAMP.txt") -Value $stamp
Write-LsqLog "=== Backup complete. Stamp $stamp recorded. ===" $logPath
