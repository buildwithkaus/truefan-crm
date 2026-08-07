<#
.SYNOPSIS
  Phase 4, read-only step 1: build the Company enrichment map from Lead-side fields,
  and compare against current Company field values to size the actual write workload.

.DESCRIPTION
  Per memory/02-company-schema-audit.md's reparenting table, several Company fields are
  meant to be backfilled from data that already exists on the Leads under that company
  (linked via Lead.RelatedCompanyId). This script:
    1. Paginates all Leads, pulling RelatedCompanyId + the 7 source mx_ fields.
    2. Builds a per-CompanyId map, taking the first non-empty value per field across all
       Leads under that company (data is duplicated per-contact, not conflicting).
    3. Paginates all Companies, pulling current values of the 7 target fields.
    4. Diffs: only companies where the target field is currently empty AND the source has
       a non-empty value get queued for update. This avoids clobbering the ~11% of
       Website values already filled (see memory/02) and avoids a wasted Company.Update
       call for companies with nothing new to add.
  Writes the resulting worklist to data/company_enrichment_worklist.json (gitignored) for
  review before any write happens - this script makes zero writes.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/build-company-enrichment-map.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "company_enrichment_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

# Lead source field -> Company target field.
# mx_Industry_Type -> Industry and mx_Company_revenue -> AnnualRevenue are EXCLUDED here -
# smoke-tested 2026-07-27 and confirmed format-incompatible (Industry is a strict Company
# dropdown rejecting free text like "Dairy business"; AnnualRevenue expects a Decimal but
# Lead data is bucketed range text like "0 to 10 cr"). See memory/02-company-schema-audit.md
# and PROJECT_PLAN.md Phase 4 for the open decision needed before these two can backfill.
$fieldMap = @{
    "mx_CIN"              = "CIN_Company"
    "mx_Budget"           = "Budget_Company"
    "mx_Website_URL"      = "Website"
    "mx_Business_Model"   = "mx_business_model"
    "mx_Qualified_Business" = "qualified_business"
}
$sourceCols = ($fieldMap.Keys -join ",") + ",RelatedCompanyId,ProspectID"

# mx_Business_Model on the Lead side is overwhelmingly free text (industry descriptions),
# not a clean B2B/B2C classification - confirmed 2026-07-27 (only 369 of 86,627 leads have
# an exact "B2B"/"B2C" value). Only pass through the clean values; skip everything else
# rather than let a bad value block the whole Company.Update call for that record.
function Test-ValidSourceValue($srcField, $val) {
    if ($srcField -eq "mx_Business_Model") {
        return $val -match '^(?i)(B2B|B2C)$'
    }
    return $true
}

Write-Log "=== Build run started ==="

# Step 1: paginate all Leads, build per-company first-non-empty-value map
$companyData = @{}
$page = 1
$leadCount = 0
while ($true) {
    $resp = Invoke-LsqLeadSearch -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } -ColumnsCsv $sourceCols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000
    if (-not $resp -or $resp.Count -eq 0) { break }
    foreach ($lead in $resp) {
        $cid = $lead.RelatedCompanyId
        if ([string]::IsNullOrWhiteSpace($cid)) { continue }
        if (-not $companyData.ContainsKey($cid)) { $companyData[$cid] = @{} }
        foreach ($srcField in $fieldMap.Keys) {
            $val = $lead.$srcField
            if (-not [string]::IsNullOrWhiteSpace($val) -and $val -ne "null" -and -not $companyData[$cid].ContainsKey($srcField) -and (Test-ValidSourceValue $srcField $val)) {
                if ($srcField -eq "mx_Business_Model") { $val = $val.ToUpper() }
                $companyData[$cid][$srcField] = $val
            }
        }
    }
    $leadCount += $resp.Count
    if ($page % 10 -eq 0) { Write-Log "Leads processed: $leadCount (page $page)" }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 200
}
Write-Log "Lead pagination DONE. Total leads processed: $leadCount. Companies with at least one source value: $($companyData.Count)"

# Step 2: paginate all Companies, get current values of target fields
$targetCols = ($fieldMap.Values -join ",") + ",CompanyId"
$currentCompanyData = @{}
$page = 1
$companyCount = 0
while ($true) {
    $resp = Invoke-LsqCompanySearch -PageIndex $page -PageSize 1000 -ColumnsCsv $targetCols
    if (-not $resp.Companies -or $resp.Companies.Count -eq 0) { break }
    foreach ($c in $resp.Companies) {
        $props = @{}
        foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
        if ($props.ContainsKey("CompanyId")) { $currentCompanyData[$props["CompanyId"]] = $props }
    }
    $companyCount += $resp.Companies.Count
    if ($page % 10 -eq 0) { Write-Log "Companies processed: $companyCount (page $page)" }
    if ($resp.Companies.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 200
}
Write-Log "Company pagination DONE. Total companies processed: $companyCount"

# Step 3: diff - only queue a field if target is currently empty and source has a value
$worklist = @()
foreach ($cid in $companyData.Keys) {
    $current = $currentCompanyData[$cid]
    if (-not $current) { continue }
    $updates = @{}
    foreach ($srcField in $fieldMap.Keys) {
        $targetField = $fieldMap[$srcField]
        $newVal = $companyData[$cid][$srcField]
        $curVal = $current[$targetField]
        $curEmpty = [string]::IsNullOrWhiteSpace($curVal) -or $curVal -eq "null"
        if ($newVal -and $curEmpty) { $updates[$targetField] = $newVal }
    }
    if ($updates.Count -gt 0) {
        $worklist += [pscustomobject]@{ CompanyId = $cid; Updates = $updates }
    }
}
Write-Log "Diff DONE. Companies queued for update: $($worklist.Count) out of $($currentCompanyData.Count) total companies"

$worklist | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dataDir "company_enrichment_worklist.json")
Write-Log "Worklist written to data/company_enrichment_worklist.json"
Write-Log "=== Build run complete (no writes made) ==="
