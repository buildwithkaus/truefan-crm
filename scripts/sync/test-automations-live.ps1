<#
.SYNOPSIS
  Runs the automation test plan end to end against a real throwaway lead, and reports which
  of the three LSQ automations actually fired. Build by hand in the UI; verify with this.

.DESCRIPTION
  The automations themselves cannot be created via API (13 endpoints probed, all 404 - see
  docs/LSQ_AUTOMATION_SPEC.md), so they are a manual UI build. The VERIFICATION does not have
  to be manual, and doing it by hand is where mistakes hide: automations are asynchronous, so
  "I changed the stage and nothing happened" is indistinguishable from "it had not fired yet."
  This script polls with a timeout instead of guessing.

  It executes the 11-step plan in the spec:

    1  create a test lead + company            -> expect Contact Fresh,   Company Fresh
    2  log an activity                         -> expect Contact Engaged, Company Nurture   [AUT-1]
    3  log a second activity                   -> expect NO CHANGE                          [AUT-1 guard]
    4  set Contact = Prospect                  -> expect Opportunity created, Company Opportunity [AUT-2]
    5  log another activity                    -> expect NO CHANGE, no second deal          [AUT-1 guard]
    6  move Opportunity -> Invoice Sent        -> expect Contact Prospect, Company Opportunity [AUT-3]
    7  move Opportunity -> Payment Received    -> expect Contact Customer, Company Customer  [AUT-3]
    8  second contact at same account -> Prospect -> expect NO second Opportunity           [AUT-2 guard]
    9  move Opportunity -> Closed - Lost       -> expect Contact Disqualified, Company Future Prospect [AUT-3]

  Steps 3, 5 and 8 are the regression guards - the ones that cause real damage if wrong. They
  assert that NOTHING happened, which is exactly what a human eyeballing the UI tends to skip.

.PARAMETER Execute
  Required. This script CREATES REAL RECORDS (2 leads, 1 company, 1 opportunity) in the live
  account. They are named with a TESTAUTO- prefix and a timestamp so they are easy to find and
  delete afterwards. Without -Execute it prints the plan and exits.

.PARAMETER TimeoutSeconds
  How long to wait for each automation to fire before calling it a failure. Default 180.
  Native automations are usually seconds, but be generous - a false failure here is worse than
  a slow test.

.PARAMETER KeepRecords
  Skip the cleanup prompt and leave the test records in place for manual inspection.

.NOTES
  pwsh ./scripts/leadsquared/sync/test-automations-live.ps1            # show the plan
  pwsh ./scripts/leadsquared/sync/test-automations-live.ps1 -Execute   # run it

  Run this AFTER building the automations and AFTER the migration, never during either.
  Do not run it at the same time as any other script - the rate limit is account-wide.
#>

param(
    [switch]$Execute,
    [int]$TimeoutSeconds = 180,
    [switch]$KeepRecords
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "automation_test_log.txt"
$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tag = "TESTAUTO-$stamp"

$script:pass = 0
$script:fail = 0
$script:results = @()

function Write-Step { param($N, $Text) Write-LsqLog "" $logPath; Write-LsqLog "--- STEP $N : $Text" $logPath }

function Assert-State {
    param(
        [string]$What,
        [string]$Expected,
        [string]$Actual,
        [switch]$Guard   # a "nothing should have changed" assertion
    )
    $ok = ($Expected -eq $Actual)
    if ($ok) { $script:pass++ } else { $script:fail++ }
    $label = if ($Guard) { "GUARD" } else { "     " }
    $verdict = if ($ok) { "PASS" } else { "FAIL" }
    $line = "  [{0}] {1} {2,-42} expected=[{3}] actual=[{4}]" -f $verdict, $label, $What, $Expected, $Actual
    Write-LsqLog $line $logPath
    $script:results += [pscustomobject]@{ Check=$What; Expected=$Expected; Actual=$Actual; Pass=$ok; Guard=[bool]$Guard }
}

function Get-LeadStage {
    param([string]$LeadId)
    # ProspectID, not ProspectId. The wrong case returned zero rows with no error, so this
    # returned $null for every lead and EVERY assertion in this harness compared against null -
    # the automation test could not have detected a failure. Fixed 2026-08-14, gotcha 49.
    $r = Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$LeadId; SqlOperator="=" } `
        -ColumnsCsv "ProspectID,ProspectStage,RelatedCompanyId,IsPrimaryContact" -PageIndex 1 -PageSize 1
    if (-not $r -or @($r).Count -eq 0) { return $null }
    return $r[0]
}

function Get-CompanyStage {
    param([string]$CompanyId)
    $r = Invoke-LsqCompanySearch -FilterBy @{ LookupName="CompanyId"; LookupValue=$CompanyId; SqlOperator="=" } -PageSize 1
    if (-not $r.Companies -or @($r.Companies).Count -eq 0) { return $null }
    foreach ($p in $r.Companies[0].companyPropertyList) { if ($p.Attribute -eq "Stage") { return $p.Value } }
    return $null
}

function Get-LeadOpportunities {
    <#
      Had two bugs until 2026-08-14, both of which made this test report success wrongly:

        1. It walked $o.Fields, which GetOpportunitiesOfLead does not return (gotcha 45), so
           Status and Stage were null on every deal - and this script's assertions are about
           Status and Stage.
        2. catch { return @() } turned a transport failure into "this lead has no deals",
           which in an automation test reads as "the automation did not fire".

      Throws now. A test harness that cannot tell "no deal" from "the read failed" cannot
      test anything.
    #>
    param([string]$LeadId)
    return Get-LsqOpportunitiesOfLead -ProspectId $LeadId -Config $cfg |
        ForEach-Object { [pscustomobject]@{ Id = $_.OpportunityId; Status = $_.Status; Stage = $_.OppStage } }
}

function Wait-For {
    <#
      Poll until the scriptblock returns the expected value, or the timeout expires.
      Returns whatever the last observed value was, so the caller can assert on it either way.
      This is the whole point of the script: an automation that has not fired YET looks
      identical to one that never will.
    #>
    param(
        [scriptblock]$Probe,
        [string]$Expected,
        [int]$Timeout = $TimeoutSeconds,
        [string]$Label = "state"
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $last = & $Probe
        if ($last -eq $Expected) { return $last }
        Start-Sleep -Seconds 5
    }
    return $last
}

function Wait-Settle {
    # For guard assertions: there is no state change to wait FOR, so wait a fixed period and
    # then confirm nothing moved. Shorter than the full timeout since we expect no event.
    param([int]$Seconds = 45)
    Write-LsqLog "  (waiting ${Seconds}s to confirm nothing changes)" $logPath
    Start-Sleep -Seconds $Seconds
}

# ---------------------------------------------------------------------------------------
if (-not $Execute) {
    Write-Host "DRY RUN - nothing created. This script would:"
    Write-Host "  * create 2 test leads and 1 test company named '$tag'"
    Write-Host "  * post activities and change stages on them"
    Write-Host "  * poll after each change (up to ${TimeoutSeconds}s) to see if the automations fired"
    Write-Host "  * assert 3 regression guards (steps 3, 5, 8) where NOTHING should happen"
    Write-Host "  * offer to delete the test records at the end"
    Write-Host ""
    Write-Host "Run with -Execute once the three automations are built and published."
    return
}

Write-LsqLog "===================================================================" $logPath
Write-LsqLog "=== LIVE AUTOMATION TEST  $tag" $logPath
Write-LsqLog "===================================================================" $logPath

# --- STEP 1: create the test company + lead --------------------------------------------
Write-Step 1 "Create test company + lead"

$companyName = "$tag Test Account"
$compBody = @{
    CompanyType = @{ CompanyTypeName = "Company" }
    Company = @(
        @{ Attribute = "CompanyName"; Value = $companyName },
        @{ Attribute = "Stage";       Value = "Fresh" }
    )
} | ConvertTo-Json -Depth 6
$companyId = $null
try {
    $r = Invoke-LsqPost -Uri "$base/CompanyManagement.svc/Company.Create?accessKey=$ak&secretKey=$sk" -JsonBody $compBody
    $companyId = $r.Message.Id
    if (-not $companyId) { $companyId = $r.CompanyId }
    Write-LsqLog "  company created: $companyId ($companyName)" $logPath
} catch {
    Write-LsqLog "  FATAL: could not create test company -> $($_.Exception.Message) | $($_.ErrorDetails.Message)" $logPath
    throw "Cannot run the test without a company. Check the Company.Create payload against your schema."
}

function New-TestLead {
    param([string]$First, [string]$Last)
    $body = @(
        @{ Attribute = "FirstName";        Value = $First },
        @{ Attribute = "LastName";         Value = $Last },
        @{ Attribute = "EmailAddress";     Value = "$($First.ToLower()).$stamp@truefan-test.invalid" },
        @{ Attribute = "ProspectStage";    Value = "Fresh" },
        @{ Attribute = "Company";          Value = $companyName },
        @{ Attribute = "RelatedCompanyId"; Value = $companyId }
    ) | ConvertTo-Json -Depth 5
    $r = Invoke-LsqPost -Uri "$base/LeadManagement.svc/Lead.Create?accessKey=$ak&secretKey=$sk" -JsonBody $body
    return $r.Message.Id
}

$leadId = New-TestLead -First "AutoTestPrimary" -Last $tag
Write-LsqLog "  lead created: $leadId" $logPath
Start-Sleep -Seconds 5

$lead = Get-LeadStage -LeadId $leadId
Assert-State "step1 contact stage" "Fresh" $lead.ProspectStage
Assert-State "step1 company stage" "Fresh" (Get-CompanyStage -CompanyId $companyId)

# --- STEP 2: first activity -> Engaged / Nurture  [AUT-1] -------------------------------
Write-Step 2 "Log first activity -> expect Contact Engaged, Company Nurture  [AUT-1]"

function Add-TestActivity {
    param([string]$LeadId, [string]$Note)
    # ActivityEvent 21 = Inbound Phone Call Activity (a standard type present on this account).
    $body = @{
        RelatedProspectId = $LeadId
        ActivityEvent     = 21
        ActivityNote      = $Note
    } | ConvertTo-Json -Depth 5
    return Invoke-LsqPost -Uri "$base/ProspectActivity.svc/Create?accessKey=$ak&secretKey=$sk" -JsonBody $body
}

Add-TestActivity -LeadId $leadId -Note "$tag activity 1" | Out-Null
$got = Wait-For -Probe { (Get-LeadStage -LeadId $leadId).ProspectStage } -Expected "Engaged"
Assert-State "step2 contact stage [AUT-1]" "Engaged" $got
$got = Wait-For -Probe { Get-CompanyStage -CompanyId $companyId } -Expected "Nurture"
Assert-State "step2 company stage [AUT-1]" "Nurture" $got

# --- STEP 3: GUARD - second activity must change nothing --------------------------------
Write-Step 3 "Log second activity -> expect NO CHANGE  [AUT-1 'run only once' guard]"
Add-TestActivity -LeadId $leadId -Note "$tag activity 2" | Out-Null
Wait-Settle
Assert-State "step3 contact unchanged" "Engaged" (Get-LeadStage -LeadId $leadId).ProspectStage -Guard
Assert-State "step3 company unchanged" "Nurture" (Get-CompanyStage -CompanyId $companyId) -Guard

# --- STEP 4: promote to Prospect -> deal created  [AUT-2] -------------------------------
Write-Step 4 "Set Contact = Prospect -> expect Opportunity created, Company Opportunity  [AUT-2]"

function Set-LeadStage {
    param([string]$LeadId, [string]$Stage)
    $body = @(@{ Attribute = "ProspectStage"; Value = $Stage }) | ConvertTo-Json -Depth 4
    if ($body -notmatch '^\[') { $body = "[$body]" }   # PS 5.1 collapses single-element arrays
    Invoke-LsqPost -Uri "$base/LeadManagement.svc/Lead.Update?accessKey=$ak&secretKey=$sk&leadId=$LeadId" -JsonBody $body | Out-Null
}

Set-LeadStage -LeadId $leadId -Stage "Prospect"
$got = Wait-For -Probe { @(Get-LeadOpportunities -LeadId $leadId).Count } -Expected 1
Assert-State "step4 opportunity count [AUT-2]" "1" "$got"
$opps = Get-LeadOpportunities -LeadId $leadId
if ($opps.Count -ge 1) {
    Assert-State "step4 opportunity stage" "Prospect" $opps[0].Stage
    Assert-State "step4 opportunity status" "Open" $opps[0].Status
}
Assert-State "step4 IsPrimaryContact set" "True" "$(Test-LsqTrue (Get-LeadStage -LeadId $leadId).IsPrimaryContact)"
$got = Wait-For -Probe { Get-CompanyStage -CompanyId $companyId } -Expected "Opportunity"
Assert-State "step4 company stage [AUT-2]" "Opportunity" $got

# --- STEP 5: GUARD - activity on a live deal must not regress it ------------------------
Write-Step 5 "Log another activity -> expect NO CHANGE, no second deal  [AUT-1 guard]"
Add-TestActivity -LeadId $leadId -Note "$tag activity 3" | Out-Null
Wait-Settle
Assert-State "step5 contact not regressed" "Prospect" (Get-LeadStage -LeadId $leadId).ProspectStage -Guard
Assert-State "step5 still one opportunity" "1" "$(@(Get-LeadOpportunities -LeadId $leadId).Count)" -Guard
Assert-State "step5 company not regressed" "Opportunity" (Get-CompanyStage -CompanyId $companyId) -Guard

# --- STEP 6/7: opportunity drives contact + company  [AUT-3] ----------------------------
function Set-OpportunityStage {
    param([string]$OppId, [string]$LeadId, [string]$Stage, [string]$Status)
    # Confirmed shape via apidocs.leadsquared.com/update-an-opportunity/ (2026-07-29). The
    # previous {Opportunity:{...}, LeadDetails:[...]} shape throws ArgumentNullException on
    # every call - never caught because this script had never been run live (the automations
    # it tests did not exist yet). Also confirmed: OpportunityManagement.svc/Update has a
    # propagation delay of several seconds before an independent re-fetch reflects the
    # write - Wait-Settle's 45-60s margin already covers this, no change needed there.
    $body = @{
        ProspectOpportunityId = $OppId
        Fields = @(
            @{ SchemaName = "Status";      Value = $Status },
            @{ SchemaName = "mx_Custom_2"; Value = $Stage }
        )
    } | ConvertTo-Json -Depth 5
    Invoke-LsqPost -Uri "$base/OpportunityManagement.svc/Update?accessKey=$ak&secretKey=$sk" -JsonBody $body | Out-Null
}

$oppId = (Get-LeadOpportunities -LeadId $leadId)[0].Id

Write-Step 6 "Opportunity -> Invoice Sent -> expect Contact Prospect, Company Opportunity  [AUT-3]"
Set-OpportunityStage -OppId $oppId -LeadId $leadId -Stage "Invoice Sent" -Status "Open"
Wait-Settle -Seconds 60
Assert-State "step6 contact stays Prospect" "Prospect" (Get-LeadStage -LeadId $leadId).ProspectStage
Assert-State "step6 company stays Opportunity" "Opportunity" (Get-CompanyStage -CompanyId $companyId)

Write-Step 7 "Opportunity -> Payment Received -> expect Contact + Company = Customer  [AUT-3]"
Set-OpportunityStage -OppId $oppId -LeadId $leadId -Stage "Payment Received" -Status "Won"
$got = Wait-For -Probe { (Get-LeadStage -LeadId $leadId).ProspectStage } -Expected "Customer"
Assert-State "step7 contact stage [AUT-3]" "Customer" $got
$got = Wait-For -Probe { Get-CompanyStage -CompanyId $companyId } -Expected "Customer"
Assert-State "step7 company stage [AUT-3]" "Customer" $got

# --- STEP 8: GUARD - second contact must not open a second deal -------------------------
Write-Step 8 "Second contact at same account -> Prospect -> expect NO second Opportunity  [AUT-2 guard]"
$leadId2 = New-TestLead -First "AutoTestSecond" -Last $tag
Write-LsqLog "  second lead created: $leadId2" $logPath
Start-Sleep -Seconds 5
Set-LeadStage -LeadId $leadId2 -Stage "Prospect"
Wait-Settle -Seconds 60
Assert-State "step8 second contact has NO deal" "0" "$(@(Get-LeadOpportunities -LeadId $leadId2).Count)" -Guard
Assert-State "step8 primary still has one deal" "1" "$(@(Get-LeadOpportunities -LeadId $leadId).Count)" -Guard

# --- STEP 9: lost deal ------------------------------------------------------------------
Write-Step 9 "Opportunity -> Closed - Lost -> expect Contact Disqualified, Company Future Prospect  [AUT-3]"
Set-OpportunityStage -OppId $oppId -LeadId $leadId -Stage "Closed - Lost" -Status "Lost"
$got = Wait-For -Probe { (Get-LeadStage -LeadId $leadId).ProspectStage } -Expected "Disqualified"
Assert-State "step9 contact stage [AUT-3]" "Disqualified" $got
$got = Wait-For -Probe { Get-CompanyStage -CompanyId $companyId } -Expected "Future Prospect"
Assert-State "step9 company stage [AUT-3]" "Future Prospect" $got

# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "===================================================================" $logPath
Write-LsqLog ("=== RESULT:  PASSED {0}   FAILED {1}" -f $script:pass, $script:fail) $logPath
Write-LsqLog "===================================================================" $logPath

$guardFails = @($script:results | Where-Object { $_.Guard -and -not $_.Pass })
if ($guardFails.Count -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "*** $($guardFails.Count) REGRESSION GUARD(S) FAILED - these are the damaging ones: ***" $logPath
    foreach ($g in $guardFails) { Write-LsqLog "      $($g.Check): expected [$($g.Expected)] got [$($g.Actual)]" $logPath }
    Write-LsqLog "A failed guard means an automation is firing when it should not - check the" $logPath
    Write-LsqLog "'is Fresh' / 'If Opportunity Exists' conditions and that they use LATEST DATA." $logPath
}

$script:results | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dataDir "automation_test_results_$stamp.json")

Write-LsqLog "" $logPath
Write-LsqLog "Test records created (delete these in the UI when done):" $logPath
Write-LsqLog "  Company : $companyId  ($companyName)" $logPath
Write-LsqLog "  Lead 1  : $leadId" $logPath
Write-LsqLog "  Lead 2  : $leadId2" $logPath
Write-LsqLog "  Search the UI for '$tag' to find them all." $logPath
if (-not $KeepRecords) {
    Write-LsqLog "" $logPath
    Write-LsqLog "NOTE: opportunities cannot be deleted via API (CanDelete=false on the type)," $logPath
    Write-LsqLog "so clean these up in the UI rather than by script." $logPath
}

if ($script:fail -gt 0) { exit 1 }
