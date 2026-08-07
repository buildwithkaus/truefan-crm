<#
.SYNOPSIS
  Phase 3, read-only step: for every Company at Stage=Opportunity or Stage=Customer,
  find the primary-contact Lead (most recent ProspectActivityDate_Max) that should own
  the backfilled Opportunity.

.DESCRIPTION
  IsPrimaryContact is confirmed unused on every Lead today (memory/01-lead-schema-audit.md,
  re-verified 2026-07-27 with a working negative control). Per Kaustubh's decision
  2026-07-27, the primary contact is picked as the Lead under each qualifying Company with
  the most recent ProspectActivityDate_Max (the true last-activity signal, not ModifiedOn).

  One paginated pass over all Leads (cheap) beats one lookup per Company (4,431 calls).
  Writes data/opportunity_backfill_worklist.json for review before any write happens -
  this script makes zero writes.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/build-opportunity-backfill-map.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_backfill_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

Write-Log "=== Build run started ==="

# Step 1: get target Companies (Stage=Opportunity or Customer)
$targetCompanies = @{}
foreach ($stage in @("Opportunity","Customer")) {
    $page = 1
    while ($true) {
        $resp = Invoke-LsqCompanySearch -FilterBy @{ LookupName='Stage'; LookupValue=$stage; SqlOperator='=' } -PageIndex $page -PageSize 1000 -ColumnsCsv "CompanyId,CompanyName"
        if (-not $resp.Companies -or $resp.Companies.Count -eq 0) { break }
        foreach ($c in $resp.Companies) {
            $props = @{}
            foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
            if ($props.CompanyId) { $targetCompanies[$props.CompanyId] = @{ CompanyName = $props.CompanyName; Stage = $stage } }
        }
        if ($resp.Companies.Count -lt 1000) { break }
        $page++
        Start-Sleep -Milliseconds 200
    }
}
Write-Log "Target companies (Stage=Opportunity or Customer): $($targetCompanies.Count)"

# Step 2: paginate all Leads, track the max-activity lead per target CompanyId
$bestLeadPerCompany = @{}
$page = 1
$leadCount = 0
while ($true) {
    $resp = Invoke-LsqLeadSearch -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } -ColumnsCsv "ProspectID,RelatedCompanyId,OwnerId,OwnerIdName,ProspectActivityDate_Max" -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000
    if (-not $resp -or $resp.Count -eq 0) { break }
    foreach ($lead in $resp) {
        $cid = $lead.RelatedCompanyId
        if ([string]::IsNullOrWhiteSpace($cid) -or -not $targetCompanies.ContainsKey($cid)) { continue }
        $actDate = $lead.ProspectActivityDate_Max
        if ([string]::IsNullOrWhiteSpace($actDate)) { continue }
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParse($actDate, [ref]$parsed)) { continue }
        if (-not $bestLeadPerCompany.ContainsKey($cid) -or $parsed -gt $bestLeadPerCompany[$cid].ActivityDate) {
            $bestLeadPerCompany[$cid] = @{ ProspectId = $lead.ProspectID; OwnerId = $lead.OwnerId; OwnerIdName = $lead.OwnerIdName; ActivityDate = $parsed }
        }
    }
    $leadCount += $resp.Count
    if ($page % 20 -eq 0) { Write-Log "Leads processed: $leadCount (page $page)" }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 200
}
Write-Log "Lead pagination DONE. Total leads processed: $leadCount"
Write-Log "Companies with a resolvable primary contact: $($bestLeadPerCompany.Count) out of $($targetCompanies.Count)"

# Step 3: build worklist
$worklist = @()
foreach ($cid in $targetCompanies.Keys) {
    if (-not $bestLeadPerCompany.ContainsKey($cid)) { continue }
    $best = $bestLeadPerCompany[$cid]
    $worklist += [pscustomobject]@{
        CompanyId = $cid
        CompanyName = $targetCompanies[$cid].CompanyName
        Stage = $targetCompanies[$cid].Stage
        ProspectId = $best.ProspectId
        OwnerId = $best.OwnerId
        OwnerIdName = $best.OwnerIdName
    }
}
Write-Log "Worklist built: $($worklist.Count) companies ready for Opportunity backfill"
$worklist | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dataDir "opportunity_backfill_worklist.json")
Write-Log "Worklist written to data/opportunity_backfill_worklist.json"
Write-Log "=== Build run complete (no writes made) ==="
