<#
.SYNOPSIS
  Offline test harness for sync-rules.ps1. NO API CALLS - runs anywhere, instantly, safely.

.DESCRIPTION
  The project has no test framework and verification is normally manual against the live API.
  The funnel decision logic is the one part that can be tested properly offline, so it is.
  Every if/else/then branch in the sync matrix has at least one case here, including the
  regression guards that matter most:

    * a follow-up call on a live deal must NOT drag it back to Engaged
    * a second contact at an account must NOT create a second opportunity
    * a disqualified primary must NOT park an account that still has live contacts

  Run this after ANY edit to sync-rules.ps1.

.NOTES
  pwsh ./scripts/leadsquared/sync/test-sync-rules.ps1
#>

. "$PSScriptRoot\sync-rules.ps1"

$script:pass = 0
$script:fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $e = if ($null -eq $Expected) { "<null>" } else { "$Expected" }
    $a = if ($null -eq $Actual) { "<null>" } else { "$Actual" }
    if ($e -eq $a) {
        $script:pass++
        Write-Host ("  PASS  {0}" -f $What)
    } else {
        $script:fail++
        Write-Host ("  FAIL  {0}  expected=[{1}] actual=[{2}]" -f $What, $e, $a)
    }
}

Write-Host "=== Rule 1: first activity moves Fresh -> Engaged (guarded) ==="
Assert-Equal "Engaged"  (Get-ContactStageAfterActivity -CurrentStage "Fresh" -HasActivity $true)   "Fresh + activity -> Engaged"
Assert-Equal "Fresh"    (Get-ContactStageAfterActivity -CurrentStage "Fresh" -HasActivity $false)  "Fresh + no activity -> stays Fresh"
Assert-Equal "Engaged"  (Get-ContactStageAfterActivity -CurrentStage "Engaged" -HasActivity $true) "Engaged + activity -> stays Engaged"
Assert-Equal "Prospect" (Get-ContactStageAfterActivity -CurrentStage "Prospect" -HasActivity $true) "GUARD: Prospect + activity does NOT regress"
Assert-Equal "Customer" (Get-ContactStageAfterActivity -CurrentStage "Customer" -HasActivity $true) "GUARD: Customer + activity does NOT regress"
Assert-Equal "Disqualified" (Get-ContactStageAfterActivity -CurrentStage "Disqualified" -HasActivity $true) "GUARD: Disqualified + activity does NOT regress"

Write-Host ""
Write-Host "=== Rule 3/4: opportunity stage drives contact stage ==="
Assert-Equal "Prospect"     (Get-ContactStageFromOpportunity -OppStatus "Open" -OppStage "Prospect")         "Open/Prospect -> Prospect"
Assert-Equal "Prospect"     (Get-ContactStageFromOpportunity -OppStatus "Open" -OppStage "In Discussion")    "Open/In Discussion -> Prospect"
Assert-Equal "Prospect"     (Get-ContactStageFromOpportunity -OppStatus "Open" -OppStage "Agreement Sent")   "Open/Agreement Sent -> Prospect"
Assert-Equal "Prospect"     (Get-ContactStageFromOpportunity -OppStatus "Open" -OppStage "Invoice Sent")     "Open/Invoice Sent -> Prospect"
Assert-Equal "Customer"     (Get-ContactStageFromOpportunity -OppStatus "Won"  -OppStage "Payment Received") "Won/Payment Received -> Customer"
Assert-Equal "Customer"     (Get-ContactStageFromOpportunity -OppStatus "Won"  -OppStage "Customer")         "Won/Customer -> Customer"
Assert-Equal "Disqualified" (Get-ContactStageFromOpportunity -OppStatus "Lost" -OppStage "Closed - Lost")    "Lost -> Disqualified"
Assert-Equal $null          (Get-ContactStageFromOpportunity -OppStatus "Open" -OppStage "")                 "empty stage -> null (leave alone)"

Write-Host ""
Write-Host "=== Contact stage -> company stage ==="
Assert-Equal "Fresh"           (Get-CompanyStageFromContactStage -ContactStage "Fresh")        "Fresh -> Fresh"
Assert-Equal "Nurture"         (Get-CompanyStageFromContactStage -ContactStage "Engaged")      "Engaged -> Nurture"
Assert-Equal "Opportunity"     (Get-CompanyStageFromContactStage -ContactStage "Prospect")     "Prospect -> Opportunity"
Assert-Equal "Customer"        (Get-CompanyStageFromContactStage -ContactStage "Customer")     "Customer -> Customer"
Assert-Equal "Future Prospect" (Get-CompanyStageFromContactStage -ContactStage "Disqualified") "Disqualified -> Future Prospect"

Write-Host ""
Write-Host "=== Rule 2: when to create an opportunity ==="
Assert-Equal $true  (Test-ShouldCreateOpportunity -ContactStage "Prospect" -HasOpportunity $false -AccountHasOpenOpportunity $false) "Prospect, no opp, account clear -> create"
Assert-Equal $false (Test-ShouldCreateOpportunity -ContactStage "Prospect" -HasOpportunity $true  -AccountHasOpenOpportunity $false) "already has an opp -> do not create"
Assert-Equal $false (Test-ShouldCreateOpportunity -ContactStage "Prospect" -HasOpportunity $false -AccountHasOpenOpportunity $true)  "COLLISION: account already has an open deal -> do not create"
Assert-Equal $false (Test-ShouldCreateOpportunity -ContactStage "Engaged"  -HasOpportunity $false -AccountHasOpenOpportunity $false) "Engaged -> no opp"
Assert-Equal $false (Test-ShouldCreateOpportunity -ContactStage "Fresh"    -HasOpportunity $false -AccountHasOpenOpportunity $false) "Fresh -> no opp"
Assert-Equal $false (Test-ShouldCreateOpportunity -ContactStage "Disqualified" -HasOpportunity $false -AccountHasOpenOpportunity $false) "Disqualified -> no opp"
Assert-Equal "Prospect"         (Get-OpportunityStageForNewDeal -ContactStage "Prospect").Stage  "new deal starts at Prospect"
Assert-Equal "Payment Received" (Get-OpportunityStageForNewDeal -ContactStage "Customer").Stage  "straight-to-Customer starts Won"

Write-Host ""
Write-Host "=== Primary-contact rule for company stage ==="
Assert-Equal "Opportunity" (Resolve-CompanyStage -Contacts @(
    @{ Stage="Prospect"; IsPrimary=$true }, @{ Stage="Engaged"; IsPrimary=$false })) "primary Prospect wins over engaged stakeholder"
Assert-Equal "Nurture" (Resolve-CompanyStage -Contacts @(
    @{ Stage="Engaged"; IsPrimary=$false }, @{ Stage="Fresh"; IsPrimary=$false })) "no primary -> furthest along (Engaged)"
Assert-Equal "Fresh" (Resolve-CompanyStage -Contacts @(
    @{ Stage="Fresh"; IsPrimary=$false }, @{ Stage="Disqualified"; IsPrimary=$false })) "Fresh outranks Future Prospect"
Assert-Equal "Future Prospect" (Resolve-CompanyStage -Contacts @(
    @{ Stage="Disqualified"; IsPrimary=$false }, @{ Stage="Disqualified"; IsPrimary=$false })) "all disqualified -> Future Prospect"
Assert-Equal "Nurture" (Resolve-CompanyStage -Contacts @(
    @{ Stage="Disqualified"; IsPrimary=$true }, @{ Stage="Engaged"; IsPrimary=$false })) "GUARD: disqualified primary does not park an account with a live contact"
Assert-Equal "Customer" (Resolve-CompanyStage -Contacts @(
    @{ Stage="Customer"; IsPrimary=$true }, @{ Stage="Disqualified"; IsPrimary=$false })) "primary Customer wins"

Write-Host ""
Write-Host "=== End-to-end decision table (Get-SyncActions) ==="

$r = Get-SyncActions -CurrentContactStage "Fresh" -CurrentCompanyStage "Fresh" -HasActivity $true `
    -HasOpportunity $false -OppStatus $null -OppStage $null -IsPrimaryContact $false -AccountHasOpenOpportunity $false
Assert-Equal "Engaged" $r.ContactStage "E2E: first activity -> contact Engaged"
Assert-Equal "Nurture" $r.CompanyStage "E2E: first activity -> company Nurture (any contact)"
Assert-Equal $false    $r.CreateOpportunity "E2E: first activity does not create a deal"

$r = Get-SyncActions -CurrentContactStage "Prospect" -CurrentCompanyStage "Nurture" -HasActivity $true `
    -HasOpportunity $false -OppStatus $null -OppStage $null -IsPrimaryContact $false -AccountHasOpenOpportunity $false
Assert-Equal $true          $r.CreateOpportunity "E2E: rep sets Prospect -> create opportunity"
Assert-Equal "Opportunity"  $r.CompanyStage      "E2E: rep sets Prospect -> company Opportunity"

$r = Get-SyncActions -CurrentContactStage "Prospect" -CurrentCompanyStage "Opportunity" -HasActivity $true `
    -HasOpportunity $false -OppStatus $null -OppStage $null -IsPrimaryContact $false -AccountHasOpenOpportunity $true
Assert-Equal $false $r.CreateOpportunity "E2E COLLISION: second contact does not open a second deal"

$r = Get-SyncActions -CurrentContactStage "Prospect" -CurrentCompanyStage "Opportunity" -HasActivity $true `
    -HasOpportunity $true -OppStatus "Won" -OppStage "Payment Received" -IsPrimaryContact $true -AccountHasOpenOpportunity $true
Assert-Equal "Customer" $r.ContactStage "E2E: Payment Received -> contact Customer"
Assert-Equal "Customer" $r.CompanyStage "E2E: Payment Received -> company Customer"

$r = Get-SyncActions -CurrentContactStage "Customer" -CurrentCompanyStage "Customer" -HasActivity $true `
    -HasOpportunity $true -OppStatus "Won" -OppStage "Payment Received" -IsPrimaryContact $true -AccountHasOpenOpportunity $true
Assert-Equal $null $r.ContactStage "E2E: already correct -> no write"
Assert-Equal $null $r.CompanyStage "E2E: already correct -> no company write"

$r = Get-SyncActions -CurrentContactStage "Prospect" -CurrentCompanyStage "Opportunity" -HasActivity $true `
    -HasOpportunity $true -OppStatus "Lost" -OppStage "Closed - Lost" -IsPrimaryContact $true -AccountHasOpenOpportunity $false
Assert-Equal "Disqualified"    $r.ContactStage "E2E: lost deal -> contact Disqualified"
Assert-Equal "Future Prospect" $r.CompanyStage "E2E: lost deal -> company Future Prospect"

$r = Get-SyncActions -CurrentContactStage "Engaged" -CurrentCompanyStage "Opportunity" -HasActivity $true `
    -HasOpportunity $false -OppStatus $null -OppStage $null -IsPrimaryContact $false -AccountHasOpenOpportunity $true
Assert-Equal $null $r.CompanyStage "E2E GUARD: engaged stakeholder does not downgrade an account with a live deal"

Write-Host ""
Write-Host "======================================================"
Write-Host ("  PASSED: {0}    FAILED: {1}" -f $script:pass, $script:fail)
Write-Host "======================================================"
if ($script:fail -gt 0) { exit 1 }
