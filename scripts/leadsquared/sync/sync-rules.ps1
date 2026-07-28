<#
.SYNOPSIS
  PURE decision logic for the stage sync engine. No API calls, no side effects, no state.
  Dot-sourced by sync-engine.ps1 and exercised by test-sync-rules.ps1.

.DESCRIPTION
  Every if/else/then in the funnel lives here as a testable function. Keeping it separate
  from the API plumbing means the rules can be verified offline against a table of cases -
  which matters on a project with no test framework and a live production database.

  The rules implement docs/STAGE_RESTRUCTURE_PLAN.md section 2:

    1. First activity of any kind : Contact Fresh -> Engaged, Company Fresh -> Nurture.
       GUARDED - fires only from Fresh, so a later activity never drags a live deal back.
    2. Engaged -> Prospect        : MANUAL rep decision. Not derived from a call outcome.
       When observed, it creates the Opportunity and moves the Company.
    3. Opportunity progression    : once a deal exists it is the source of truth and drives
       both Contact and Company.
    4. Payment Received          : Contact and Company both become Customer.

  Precedence: an existing Opportunity always wins. Rules 1-2 only apply to contacts with no
  Opportunity yet.

.NOTES
  ASCII only. No non-ASCII punctuation - see CLAUDE.md.
#>

# Opportunity stages that mean the deal is live and the account is a customer.
$Script:CustomerOppStages = @("Payment Received", "Customer")
$Script:LostOppStages     = @("Closed - Lost")

# Company stage precedence, used when an account has several contacts and no primary.
# Fresh deliberately outranks Future Prospect: an account with one un-worked contact and one
# disqualified contact is still workable, not written off.
$Script:CompanyStageRank = @{
    "Customer"        = 5
    "Opportunity"     = 4
    "Nurture"         = 3
    "Fresh"           = 2
    "Future Prospect" = 1
}

function Get-ContactStageFromOpportunity {
    <#
      Rule 3/4. Given an Opportunity's status and stage, what should the CONTACT stage be?
      Returns $null if the opportunity state is unrecognised (caller should leave it alone
      rather than guess).
    #>
    param(
        [AllowNull()][string]$OppStatus,
        [AllowNull()][string]$OppStage
    )
    if ([string]::IsNullOrWhiteSpace($OppStage)) { return $null }

    if ($Script:CustomerOppStages -contains $OppStage) { return "Customer" }
    if ($Script:LostOppStages -contains $OppStage -or $OppStatus -eq "Lost") { return "Disqualified" }
    if ($OppStatus -eq "Open") { return "Prospect" }
    if ($OppStatus -eq "Won") { return "Customer" }
    return $null
}

function Get-CompanyStageFromContactStage {
    <#
      Maps a contact lifecycle stage to the company stage it implies.
      Note Disqualified -> Future Prospect: the account is parked with a reason, not deleted.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ContactStage)
    switch ($ContactStage) {
        "Fresh"        { return "Fresh" }
        "Engaged"      { return "Nurture" }
        "Prospect"     { return "Opportunity" }
        "Customer"     { return "Customer" }
        "Disqualified" { return "Future Prospect" }
        default        { return $null }
    }
}

function Get-ContactStageAfterActivity {
    <#
      Rule 1. First activity of ANY kind moves a Fresh contact to Engaged.
      GUARDED: returns the stage unchanged for anything that is not Fresh, so logging a call
      on a Prospect or Customer never regresses them. This guard is the single most important
      line in the sync engine - without it, every follow-up call on a live deal would knock
      it back down the funnel.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentStage,
        [bool]$HasActivity
    )
    if ($CurrentStage -eq "Fresh" -and $HasActivity) { return "Engaged" }
    return $CurrentStage
}

function Test-ShouldCreateOpportunity {
    <#
      Rule 2. Should this contact get an Opportunity created right now?
      True only when: the rep has moved them to a deal stage, no Opportunity exists yet, and
      no OTHER contact at the same account already owns an open deal (one account, one deal).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ContactStage,
        [bool]$HasOpportunity,
        [bool]$AccountHasOpenOpportunity
    )
    if ($HasOpportunity) { return $false }
    if ($AccountHasOpenOpportunity) { return $false }
    return ($ContactStage -eq "Prospect" -or $ContactStage -eq "Customer")
}

function Get-OpportunityStageForNewDeal {
    <#
      What stage should a newly auto-created Opportunity start at?
      Prospect for a normal Engaged -> Prospect promotion. If a rep jumps a contact straight
      to Customer, the deal is created already Won so reporting is not left with an open
      opportunity for an account that has paid.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ContactStage)
    if ($ContactStage -eq "Customer") { return @{ Stage = "Payment Received"; Status = "Won" } }
    return @{ Stage = "Prospect"; Status = "Open" }
}

function Resolve-CompanyStage {
    <#
      Which stage should a company sit at, given all of its contacts?

      Primary-contact rule: if a primary contact exists, the company follows THAT contact.
      Otherwise it follows the furthest-along contact.

      One exception, per the locked design: "once the first activity is recorded on a company
      which was in Fresh, it should move to Nurture" - ANY contact's first activity does that,
      not just the primary's. So a company is never left at Fresh while one of its contacts is
      already Engaged.

      $Contacts: array of @{ Stage = "..."; IsPrimary = $true/$false }
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Contacts)

    if ($Contacts.Count -eq 0) { return $null }

    $primary = @($Contacts | Where-Object { $_.IsPrimary })
    if ($primary.Count -gt 0) {
        $stage = Get-CompanyStageFromContactStage -ContactStage $primary[0].Stage
        # Do not let a disqualified primary park an account that still has live contacts.
        if ($stage -eq "Future Prospect") {
            $live = @($Contacts | Where-Object {
                $_.Stage -eq "Engaged" -or $_.Stage -eq "Prospect" -or $_.Stage -eq "Customer"
            })
            if ($live.Count -gt 0) {
                return (Get-CompanyStageFromContactStage -ContactStage $live[0].Stage)
            }
        }
        return $stage
    }

    $best = $null; $bestRank = -1
    foreach ($c in $Contacts) {
        $s = Get-CompanyStageFromContactStage -ContactStage $c.Stage
        if ($null -eq $s) { continue }
        $rank = $Script:CompanyStageRank[$s]
        if ($rank -gt $bestRank) { $bestRank = $rank; $best = $s }
    }
    return $best
}

function Get-SyncActions {
    <#
      The whole decision table in one place. Given everything known about one contact,
      returns what should change. Pure - the caller performs the writes.

      Returns @{
        ContactStage      = <new stage or $null if unchanged>
        CompanyStage      = <new stage or $null if unchanged>
        CreateOpportunity = $true/$false
        NewOppStage       = @{Stage=..;Status=..} or $null
        Reason            = <why, for the audit log>
      }
    #>
    param(
        [AllowEmptyString()][string]$CurrentContactStage,
        [AllowEmptyString()][string]$CurrentCompanyStage,
        [bool]$HasActivity,
        [bool]$HasOpportunity,
        [AllowNull()][string]$OppStatus,
        [AllowNull()][string]$OppStage,
        [bool]$IsPrimaryContact,
        [bool]$AccountHasOpenOpportunity
    )

    $result = @{
        ContactStage = $null; CompanyStage = $null
        CreateOpportunity = $false; NewOppStage = $null; Reason = "no change"
    }

    # --- Precedence 1: an existing Opportunity is the source of truth -------------------
    if ($HasOpportunity) {
        $target = Get-ContactStageFromOpportunity -OppStatus $OppStatus -OppStage $OppStage
        if ($null -ne $target -and $target -ne $CurrentContactStage) {
            $result.ContactStage = $target
            $result.Reason = "opportunity ($OppStatus/$OppStage) drives contact -> $target"
        }
        $effective = if ($result.ContactStage) { $result.ContactStage } else { $CurrentContactStage }
        if ($IsPrimaryContact) {
            $cs = Get-CompanyStageFromContactStage -ContactStage $effective
            if ($null -ne $cs -and $cs -ne $CurrentCompanyStage) {
                $result.CompanyStage = $cs
                if ($result.Reason -eq "no change") { $result.Reason = "primary contact drives company -> $cs" }
            }
        }
        return $result
    }

    # --- Precedence 2: no Opportunity yet ----------------------------------------------
    $newStage = Get-ContactStageAfterActivity -CurrentStage $CurrentContactStage -HasActivity $HasActivity
    if ($newStage -ne $CurrentContactStage) {
        $result.ContactStage = $newStage
        $result.Reason = "first activity: Fresh -> Engaged"
    }
    $effective = if ($result.ContactStage) { $result.ContactStage } else { $CurrentContactStage }

    if (Test-ShouldCreateOpportunity -ContactStage $effective -HasOpportunity $HasOpportunity -AccountHasOpenOpportunity $AccountHasOpenOpportunity) {
        $result.CreateOpportunity = $true
        $result.NewOppStage = Get-OpportunityStageForNewDeal -ContactStage $effective
        $result.Reason = "rep moved contact to $effective -> create opportunity at $($result.NewOppStage.Stage)"
    }

    # Company follows the primary contact. The one exception is the Fresh -> Nurture bump,
    # which any contact's first activity may trigger.
    $cs = Get-CompanyStageFromContactStage -ContactStage $effective
    if ($null -ne $cs -and $cs -ne $CurrentCompanyStage) {
        if ($IsPrimaryContact -or $result.CreateOpportunity) {
            $result.CompanyStage = $cs
        } elseif ($CurrentCompanyStage -eq "Fresh" -and $cs -eq "Nurture") {
            $result.CompanyStage = "Nurture"
            if ($result.Reason -eq "no change") { $result.Reason = "first activity at account: company Fresh -> Nurture" }
        }
    }

    return $result
}
