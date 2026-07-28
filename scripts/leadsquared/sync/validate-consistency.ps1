<#
.SYNOPSIS
  READ-ONLY drift detector. Finds records that violate the funnel rules, so problems surface
  as a report rather than as a rep noticing something odd months later.

.DESCRIPTION
  The sync engine can fail quietly - a rate-limit blip, a bad record, a stopped scheduled
  task. This is the independent check that it is actually working. Run it nightly.

  Violations detected:
    V1  Contact at Prospect/Customer with NO Opportunity
    V2  Company at Opportunity/Customer with no primary contact
    V3  Account with MORE THAN ONE contact flagged IsPrimaryContact (deal fragmentation)
    V4  Contact stage and its Opportunity stage disagree
    V5  Company stage does not match its primary contact's stage
    V6  Contact Disqualified but missing a reason or category
    V7  Contact at a live stage whose company is still Fresh

.NOTES
  pwsh ./scripts/leadsquared/sync/validate-consistency.ps1
  Writes a report to data/consistency_report_<stamp>.json plus a log summary.
#>

param([int]$ThrottleMs = 300)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\sync-rules.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "consistency_log.txt"
$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

Write-LsqLog "=== Consistency validation started (READ-ONLY) ===" $logPath

# --- Load every lead once --------------------------------------------------------------
$cols = "ProspectID,ProspectStage,RelatedCompanyId,IsPrimaryContact,mx_Disqualification_Reason,mx_Disqualification_Category"
$leads = @()
$page = 1
while ($true) {
    $r = Invoke-LsqLeadSearch -Filter @{ LookupName="CreatedOn"; LookupValue="2000-01-01"; SqlOperator=">" } `
        -ColumnsCsv $cols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000
    if (-not $r -or @($r).Count -eq 0) { break }
    $leads += @($r)
    if (@($r).Count -lt 1000) { break }
    $page++; Start-Sleep -Milliseconds 250
}
Write-LsqLog "Leads loaded: $($leads.Count)" $logPath

# --- Load every company once -----------------------------------------------------------
$companyStage = @{}
$page = 1
while ($true) {
    $r = Invoke-LsqCompanySearch -CompanyTypeName "Company" -PageIndex $page -PageSize 1000
    if (-not $r.Companies -or @($r.Companies).Count -eq 0) { break }
    foreach ($c in $r.Companies) {
        $props = @{}
        foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
        if ($props.CompanyId) { $companyStage[$props.CompanyId] = $props.Stage }
    }
    if (@($r.Companies).Count -lt 1000) { break }
    $page++; Start-Sleep -Milliseconds 300
}
Write-LsqLog "Companies loaded: $($companyStage.Count)" $logPath

$violations = @()
function Add-Violation { param($Code, $Severity, $Id, $Detail)
    $script:violations += [pscustomobject]@{ Code=$Code; Severity=$Severity; RecordId=$Id; Detail=$Detail }
}

# --- V3 / V2 / V5 / V7: account-level checks -------------------------------------------
$byCompany = $leads | Where-Object { -not [string]::IsNullOrWhiteSpace($_.RelatedCompanyId) } | Group-Object RelatedCompanyId
foreach ($g in $byCompany) {
    $cid = $g.Name
    $stage = $companyStage[$cid]
    $primaries = @($g.Group | Where-Object { Test-LsqTrue $_.IsPrimaryContact })

    if ($primaries.Count -gt 1) {
        Add-Violation "V3" "HIGH" $cid "Account has $($primaries.Count) primary contacts - deals will fragment. Leads: $(($primaries.ProspectID) -join ', ')"
    }
    if ($stage -in @("Opportunity", "Customer") -and $primaries.Count -eq 0) {
        Add-Violation "V2" "MEDIUM" $cid "Company at '$stage' but no contact is flagged primary"
    }
    if ($primaries.Count -eq 1) {
        $expected = Get-CompanyStageFromContactStage -ContactStage $primaries[0].ProspectStage
        if ($null -ne $expected -and $null -ne $stage -and $expected -ne $stage) {
            Add-Violation "V5" "MEDIUM" $cid "Company '$stage' but primary contact is '$($primaries[0].ProspectStage)' (expected company '$expected')"
        }
    }
    $live = @($g.Group | Where-Object { $_.ProspectStage -in @("Engaged","Prospect","Customer") })
    if ($stage -eq "Fresh" -and $live.Count -gt 0) {
        Add-Violation "V7" "LOW" $cid "Company still Fresh but has $($live.Count) contact(s) at a live stage"
    }
}

# --- V6: disqualified without a reason -------------------------------------------------
foreach ($l in ($leads | Where-Object { $_.ProspectStage -eq "Disqualified" })) {
    if ([string]::IsNullOrWhiteSpace($l.mx_Disqualification_Reason) -or
        [string]::IsNullOrWhiteSpace($l.mx_Disqualification_Category)) {
        Add-Violation "V6" "LOW" $l.ProspectID "Disqualified with no reason/category"
    }
}

# --- V1 / V4: per-lead opportunity checks (one API call each, so scoped to deal stages) --
$dealContacts = @($leads | Where-Object { $_.ProspectStage -in @("Prospect", "Customer") })
Write-LsqLog "Checking opportunities for $($dealContacts.Count) deal-stage contacts..." $logPath
foreach ($l in $dealContacts) {
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$($l.ProspectID)&opportunityType=12000"
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
        if ($r.RecordCount -eq 0) {
            Add-Violation "V1" "HIGH" $l.ProspectID "Contact at '$($l.ProspectStage)' has NO Opportunity"
        } else {
            $f = @{}
            foreach ($fld in $r.List[0].Fields) { $f[$fld.SchemaName] = $fld.Value }
            $expected = Get-ContactStageFromOpportunity -OppStatus $f["Status"] -OppStage $f["mx_Custom_2"]
            if ($null -ne $expected -and $expected -ne $l.ProspectStage) {
                Add-Violation "V4" "MEDIUM" $l.ProspectID "Contact '$($l.ProspectStage)' but opportunity is $($f['Status'])/$($f['mx_Custom_2']) (expected contact '$expected')"
            }
            if ($r.RecordCount -gt 1) {
                Add-Violation "V3" "HIGH" $l.ProspectID "Lead has $($r.RecordCount) opportunities - should be 1"
            }
        }
    } catch {
        Write-LsqLog "  opportunity check failed for $($l.ProspectID) -> $($_.Exception.Message)" $logPath
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

# --- Report ----------------------------------------------------------------------------
$reportPath = Join-Path $dataDir "consistency_report_$stamp.json"
$violations | ConvertTo-Json -Depth 4 | Set-Content -Path $reportPath

Write-LsqLog "" $logPath
Write-LsqLog "--- Violations by type ---" $logPath
foreach ($g in ($violations | Group-Object Code | Sort-Object Name)) {
    $sev = ($g.Group | Select-Object -First 1).Severity
    Write-LsqLog ("  {0} [{1,-6}] {2,6}" -f $g.Name, $sev, $g.Count) $logPath
}
Write-LsqLog "" $logPath
Write-LsqLog "TOTAL VIOLATIONS: $($violations.Count)" $logPath
Write-LsqLog "Report: $reportPath" $logPath
if ($violations.Count -eq 0) { Write-LsqLog "=== CLEAN - all funnel rules hold. ===" $logPath }
else { Write-LsqLog "=== Review the report. HIGH severity items break deal reporting. ===" $logPath }
