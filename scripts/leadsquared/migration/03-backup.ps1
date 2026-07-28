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

. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "migration_backup_log.txt"

Write-LsqLog "=== Backup started (READ-ONLY) stamp=$stamp ===" $logPath

# --- Leads -----------------------------------------------------------------------------
$leadBackup = @()
$page = 1
while ($true) {
    $resp = Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason,IsPrimaryContact,RelatedCompanyId" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000
    if (-not $resp -or $resp.Count -eq 0) { break }
    foreach ($l in $resp) {
        $leadBackup += [pscustomobject]@{
            ProspectId          = $l.ProspectID
            ProspectStage       = $l.ProspectStage
            CallDisposition     = $l.mx_Call_Disposition
            DisqualificationRsn = $l.mx_Disqualification_Reason
            IsPrimaryContact    = $l.IsPrimaryContact
            CompanyId           = $l.RelatedCompanyId
        }
    }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
$leadPath = Join-Path $dataDir "migration_BACKUP_leads_$stamp.json"
$leadBackup | ConvertTo-Json -Depth 4 | Set-Content -Path $leadPath
Write-LsqLog "Leads backed up: $($leadBackup.Count) -> $leadPath" $logPath

# --- Companies -------------------------------------------------------------------------
# Company.Get's Include_CSV is picky about exact field names; fetch full records and read
# companyPropertyList instead of guessing a column list.
$companyBackup = @()
$page = 1
while ($true) {
    $resp = Invoke-LsqCompanySearch -CompanyTypeName "Company" -PageIndex $page -PageSize 1000
    if (-not $resp.Companies -or $resp.Companies.Count -eq 0) { break }
    foreach ($c in $resp.Companies) {
        $props = @{}
        foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
        $companyBackup += [pscustomobject]@{
            CompanyId   = $props.CompanyId
            CompanyName = $props.CompanyName
            Stage       = $props.Stage
            OwnerName   = $props.OwnerName
        }
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
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
foreach ($leadId in $candidates) {
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$leadId&opportunityType=12000"
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
        if ($r.RecordCount -gt 0) {
            foreach ($o in $r.List) {
                $f = @{}
                foreach ($fld in $o.Fields) { $f[$fld.SchemaName] = $fld.Value }
                $oppBackup += [pscustomobject]@{
                    ProspectId    = $leadId
                    OpportunityId = $o.OpportunityId
                    Status        = $f["Status"]
                    Stage         = $f["mx_Custom_2"]
                    Name          = $f["mx_Custom_1"]
                }
            }
        }
    } catch {
        Write-LsqLog "Opportunity read failed for lead $leadId -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }
    Start-Sleep -Milliseconds 300
}
$oppPath = Join-Path $dataDir "migration_BACKUP_opportunities_$stamp.json"
$oppBackup | ConvertTo-Json -Depth 4 | Set-Content -Path $oppPath
Write-LsqLog "Opportunities backed up: $($oppBackup.Count) -> $oppPath" $logPath

# Record the stamp so the orchestrator and any rollback can find this backup set.
Set-Content -Path (Join-Path $dataDir "migration_LAST_BACKUP_STAMP.txt") -Value $stamp
Write-LsqLog "=== Backup complete. Stamp $stamp recorded. ===" $logPath
