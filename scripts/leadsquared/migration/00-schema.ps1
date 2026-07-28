<#
.SYNOPSIS
  Declarative schema + mapping definition for the stage restructure. Dot-sourced by every
  other migration script. Contains NO API calls and performs NO writes - it is pure config.

.DESCRIPTION
  Single source of truth for: the new stage values on all three objects, the old-to-new
  migration mapping, the disqualification taxonomy, and the new field definitions.

  IMPORTANT - on hardcoded strings. CLAUDE.md forbids hand-writing field-value strings into
  a migration script, because the Phase 5 backfill probed two guessed strings, got 0 rows
  for each, and silently skipped 20,076 leads. The rule is honoured here as follows:

    * $StageMap below is a MAPPING, never a FILTER. Nothing is selected by these strings.
    * 02-build-worklist.ps1 enumerates the values that are ACTUALLY stored in the live
      account, then looks each one up in $StageMap.
    * Any live value missing from $StageMap causes that script to ABORT with a loud error.
      An unmapped or newly-added dropdown value therefore halts the migration instead of
      being silently dropped.

  So the map must be complete, and the build step proves it against live data rather than
  trusting it. Keys below were copied from a live enumeration on 2026-07-28 - note
  "Invalid/ Junk" (space after the slash) and "Just Enquiring, No Intent" (comma).

.NOTES
  ASCII only in this file - a non-ASCII character in a double-quoted PowerShell 5.1 string
  can throw a cascading parse error that silently breaks everything after it. See CLAUDE.md.
#>

# ---------------------------------------------------------------------------------------
# Target stage values
# ---------------------------------------------------------------------------------------

$Script:ContactStages = @("Fresh", "Engaged", "Prospect", "Customer", "Disqualified")

$Script:CompanyStages = @("Fresh", "Nurture", "Opportunity", "Customer", "Future Prospect")

# Opportunity Stage lives in mx_Custom_2, a dependent dropdown under the native Status
# field (Status is fixed to Open/Won/Lost and displayed to reps as "Deal Stage").
$Script:OpportunityStages = [ordered]@{
    "Open" = @("Prospect", "In Discussion", "Agreement Sent", "Invoice Sent")
    "Won"  = @("Payment Received", "Customer")
    "Lost" = @("Closed - Lost")
}

# Canonical forward order. Stage never moves backwards: if a rep sends the invoice before
# the agreement, the stage sits at the higher-ranked of the two and both date fields are
# stamped independently.
$Script:OpportunityStageRank = [ordered]@{
    "Prospect"         = 1
    "In Discussion"    = 2
    "Agreement Sent"   = 3
    "Invoice Sent"     = 4
    "Payment Received" = 5
    "Customer"         = 6
    "Closed - Lost"    = 99
}

# Renames to apply to the EXISTING live Opportunity stage dropdown. Applying these means the
# ~4,404 existing Opportunities need zero record writes. UI step - see MANUAL_STEPS.md.
$Script:OpportunityStageRenames = [ordered]@{
    "Requirement Gathering"      = "Prospect"
    "Celebrity/Product Proposed" = "In Discussion"
    "Contract Sent"              = "Agreement Sent"
    "Payment Pending"            = "Invoice Sent"
    "Payment Recieved"           = "Payment Received"   # also fixes the live typo
}

# ---------------------------------------------------------------------------------------
# Disqualification taxonomy. Level 1 drives behaviour (does the account ever come back?),
# Level 2 preserves the detail reps already recorded.
# ---------------------------------------------------------------------------------------

$Script:DisqualificationCategories = @(
    "Not ICP Fit",            # structurally wrong, never revisit, suppressed from TAL
    "No Requirement",         # right profile, no need now
    "Commercial Mismatch",    # wants it, price does not work
    "Supply Gap",             # wants it, celebrity roster insufficient
    "Unreachable / Bad Data", # contact-level failure, account may be fine
    "Not Interested"          # heard the pitch, declined
)

# Categories whose accounts are hidden from rep working views and the TAL.
$Script:SuppressedCategories = @("Not ICP Fit")

# ---------------------------------------------------------------------------------------
# THE MAPPING. Keys are exact live ProspectStage strings (enumerated 2026-07-28).
#   Contact  - target contact lifecycle stage
#   Company  - target company stage
#   Reason   - mx_Disqualification_Reason (L2), only for Disqualified
#   Category - mx_Disqualification_Category (L1), only for Disqualified
#   Disposition - mx_Call_Disposition, where the old value described a call outcome
#   Segment  - mx_Segment, where the old value described a channel or segment
#   OppStage - opportunity stage to create at, only for Contact=Prospect/Customer
#   Infer    - $true means the stage cannot be derived from the old value alone; the
#              worklist builder decides from activity history instead
# ---------------------------------------------------------------------------------------

$Script:StageMap = @{

    # ---- Fresh: never reached a human. A retryable call outcome is NOT a dead lead. ----
    "Fresh Lead"                 = @{ Contact = "Fresh"; Company = "Fresh" }
    "Didn't Picked"              = @{ Contact = "Fresh"; Company = "Fresh"; Disposition = "Did Not Pick" }
    "RNR"                        = @{ Contact = "Fresh"; Company = "Fresh"; Disposition = "RNR (5+ dials)" }
    "Switched Off/Not Reachable" = @{ Contact = "Fresh"; Company = "Fresh"; Disposition = "Switched Off / Not Reachable" }

    # ---- Engaged: reached a human, no requirement stated yet ----
    "Call me Later"           = @{ Contact = "Engaged"; Company = "Nurture"; Disposition = "Call Me Later" }
    "Follow Up"               = @{ Contact = "Engaged"; Company = "Nurture"; Disposition = "Follow Up (pitch delivered)" }
    "ReQualified By WhatsApp" = @{ Contact = "Engaged"; Company = "Nurture"; Segment = "WhatsApp Requalified" }
    "Retargetedlead"          = @{ Contact = "Engaged"; Company = "Nurture"; Segment = "Retargeted (WhatsApp)" }
    "RetargetedleadEMAIL"     = @{ Contact = "Engaged"; Company = "Nurture"; Segment = "Retargeted (Email)" }

    # ---- Prospect: requirement stated, a deal exists ----
    "Requirement Gathering (Warm)"   = @{ Contact = "Prospect"; Company = "Opportunity"; OppStage = "Prospect" }
    "Requirement Gathering"          = @{ Contact = "Prospect"; Company = "Opportunity"; OppStage = "Prospect" }
    "Conversation In Progress (Hot)" = @{ Contact = "Prospect"; Company = "Opportunity"; OppStage = "In Discussion" }
    "Contract Follow Up"             = @{ Contact = "Prospect"; Company = "Opportunity"; OppStage = "Agreement Sent" }

    # ---- Customer ----
    "Payment Received" = @{ Contact = "Customer"; Company = "Customer"; OppStage = "Payment Received" }

    # ---- Disqualified: one terminal state, reason preserved ----
    "Disqualified" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Not Interested - No Reason Stated"; Category = "Not Interested" }
    "Not Interested" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Not Interested - No Reason Stated"; Category = "Not Interested" }
    "Not Active After First Conversation" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Went Dark After First Conversation"; Category = "Not Interested" }
    "Conflict" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Legacy - Unclassified"; Category = "Not Interested" }

    "Invalid/ Junk" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Invalid / Not a Business"; Category = "Not ICP Fit" }
    "B2B-Disqualified" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Out of ICP - B2B Not Relevant"; Category = "Not ICP Fit"; Segment = "B2B" }
    "No Requirement of Celeb in Ads" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "No Celebrity Requirement"; Category = "Not ICP Fit" }

    "Future Prospect" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "No Current Requirement (Timing)"; Category = "No Requirement" }
    "Just Enquiring, No Intent" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Just Enquiring - No Intent"; Category = "No Requirement" }
    "Does not want AI" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Does Not Want AI"; Category = "No Requirement" }

    "Low Budget" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Low Budget / Pricing Mismatch"; Category = "Commercial Mismatch" }
    "Supply Issue" = @{ Contact = "Disqualified"; Company = "Future Prospect"
        Reason = "Celebrity Supply Gap"; Category = "Supply Gap" }

    # Approved deviation (Kaustubh, 2026-07-28): the account is qualified, only the phone
    # number is wrong, so the COMPANY stays workable at Nurture rather than being buried in
    # Future Prospect. 4,753 accounts affected.
    "Wrong Number" = @{ Contact = "Disqualified"; Company = "Nurture"
        Reason = "Invalid Contact Data"; Category = "Unreachable / Bad Data"
        Disposition = "Wrong Number"; NeedsContactResourcing = $true }

    # ---- Channel/segment tags that were never stages: infer stage from activity history ----
    "SaaS"              = @{ Infer = $true; Segment = "Enterprise / SaaS" }
    "FB Lead - Website" = @{ Infer = $true; Segment = "FB Lead / Website" }
}

# ---------------------------------------------------------------------------------------
# New fields to create
# ---------------------------------------------------------------------------------------

# Lead custom fields - creatable via LeadManagement.svc/CreateLeadField (verified working).
$Script:NewLeadFields = @(
    @{ DisplayName = "Disqualification Category"; SchemaName = "mx_Disqualification_Category"
       DataType = "Select"; Options = $Script:DisqualificationCategories }
    @{ DisplayName = "Segment"; SchemaName = "mx_Segment"
       DataType = "Select"; Options = @("Enterprise / SaaS", "SMB", "B2B", "WhatsApp Requalified",
                                        "Retargeted (WhatsApp)", "Retargeted (Email)", "FB Lead / Website") }
    @{ DisplayName = "Revisit After"; SchemaName = "mx_Revisit_After"; DataType = "Date" }
    @{ DisplayName = "Needs Contact Resourcing"; SchemaName = "mx_Needs_Contact_Resourcing"
       DataType = "Select"; Options = @("Yes", "No") }
)

# UI-only. No Company field-creation API exists, and pushing dropdown options to a SYSTEM
# Lead field (ProspectStage) is undocumented/unverified. See MANUAL_STEPS.md.
$Script:ManualFieldSteps = @(
    "Lead: add the 5 new ProspectStage values (Fresh, Engaged, Prospect, Customer, Disqualified) ALONGSIDE the existing 28 - do not delete any old value yet"
    "Company: add the 5 new Stage values (Fresh, Nurture, Opportunity, Customer, Future Prospect)"
    "Company: create field 'Future Prospect Reason' (dropdown, 6 L1 categories)"
    "Company: create field 'Revisit After' (date)"
    "Company: create field 'Needs Contact Resourcing' (Yes/No)"
    "Opportunity: rename the 5 existing Stage values per OpportunityStageRenames"
    "Opportunity: add 'Customer' as a second Won stage"
    "Opportunity: create 'Agreement Sent Date' and 'Invoice Sent Date' (DateTime)"
)

# ---------------------------------------------------------------------------------------
# Helpers used by the other migration scripts
# ---------------------------------------------------------------------------------------

function Get-StageMapping {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$OldValue)
    if ($Script:StageMap.ContainsKey($OldValue)) { return $Script:StageMap[$OldValue] }
    return $null
}

function Test-StageMapCompleteness {
    <#
      Assert every value actually present in live data has a mapping. Returns the list of
      unmapped values so the caller can abort. This is the guard that makes the hardcoded
      map safe: completeness is proven against live data, never assumed.
    #>
    param([Parameter(Mandatory)][string[]]$LiveValues)
    $unmapped = @()
    foreach ($v in $LiveValues) {
        if (-not $Script:StageMap.ContainsKey($v)) { $unmapped += $v }
    }
    return $unmapped
}

$Script:MigrationDataDir = Join-Path $PSScriptRoot "..\..\..\data"
