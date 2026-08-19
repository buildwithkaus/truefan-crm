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

# Six values, not five. 'Future Prospect' was originally modelled as a Company stage only,
# and the 2026-07-31 restructure therefore treated it as a legacy CONTACT value and mapped it
# to Disqualified. That was wrong: it is a real contact stage (Kaustubh, 2026-08-12), meaning
# "right business, no need right now" - a live revisit list, not a closed account.
#
# The cost of the earlier reading: 2,729 contacts were moved to Disqualified on 2026-08-11
# and had to be rolled back the next day, after reps noticed their accounts had gone.
$Script:ContactStages = @("Fresh", "Engaged", "Prospect", "Customer", "Disqualified", "Future Prospect")

$Script:CompanyStages = @("Fresh", "Nurture", "Opportunity", "Customer", "Future Prospect")

# The six live mx_Call_Disposition options, read from the dropdown on 2026-07-31 and kept in
# step with supabase/functions/_shared/schema.ts (CALL_DISPOSITIONS) and the
# ref_canonical_value seed in supabase/migrations/001_schema.sql. Kaustubh's decision, recorded
# in memory/08: the six existing option names stay as they are.
#
# This is the SELECTABLE list, not the stored list, and the two have drifted: LeadSquared
# stores a value that is not in the dropdown instead of rejecting it, so values like
# 'Not Interested - No Reason Gauged' and 'Requirement Gathering (Warm)' (a contact STAGE
# sitting in the disposition field) read back fine over the API while no rep can filter them.
# Compare stored values against this list to find them - do not assume a stored value is valid.
$Script:CallDispositions = @(
    "RNR", "Did Not Pick", "Call me Later", "Switched Off/Not Reachable", "Wrong Number", "Follow Up"
)

# The subset meaning "nobody was reached". Useful as a contradiction test rather than a
# category: 'Did Not Pick' is demonstrably applied to calls that connected (memory/11), which
# is worse than leaving the field blank, because a blank field does not assert anything.
$Script:NoContactDispositions = @("Did Not Pick", "RNR", "Switched Off/Not Reachable")

# Opportunity Stage lives in mx_Custom_2, a dependent dropdown under the native Status
# field (Status is fixed to Open/Won/Lost and displayed to reps as "Deal Stage").
#
# 'Requirement Gathering' sits under Open deliberately. It is not in the original TARGET
# taxonomy, but it is a real, selectable, live value on this account - 91 open deals were on it
# on 2026-08-18 - and this table is used to VALIDATE writes. Leaving it out made
# New-LsqOpportunity reject a faithful restore of an existing Requirement Gathering deal with
# "not valid under Status 'Open'", which is the tool disagreeing with production, not the data
# being wrong. See gotcha 26: legacy on the Contact, current and warm on the Opportunity.
$Script:OpportunityStages = [ordered]@{
    "Open" = @("Prospect", "Requirement Gathering", "In Discussion", "Agreement Sent", "Invoice Sent")
    "Won"  = @("Payment Received", "Customer")
    "Lost" = @("Closed - Lost")
}

# Canonical forward order. Stage never moves backwards: if a rep sends the invoice before
# the agreement, the stage sits at the higher-ranked of the two and both date fields are
# stamped independently.
#
# 'Requirement Gathering' is in here deliberately (added 2026-08-14) and is NOT drift. On the
# OPPORTUNITY it is a real, current, warm stage sitting between Prospect and In Discussion -
# 90 live deals. Only on the CONTACT is it legacy and an alias of Prospect. That is gotcha 26,
# and $Script:OpportunityStageRenames below refers to the contact, not to this table.
#
# It was missing until 2026-08-14, and the omission was not inert: $rank['Requirement Gathering']
# returned $null, and PowerShell evaluates ($null -lt 1) as $true, so a warm deal LOST every
# "keep the furthest advanced" duplicate contest to a brand-new one. Any comparison against this
# table must go through Get-LsqOpportunityStageRank (scripts/lib/opportunity.ps1), which returns
# $null plus a warning for an unknown value rather than a silent 0.
#
# Mirrors opp_stage_rank() in supabase/migrations/012_deal_taxonomy_and_fields.sql exactly.
# The two must agree - change them together.
$Script:OpportunityStageRank = [ordered]@{
    "Prospect"              = 1
    "Requirement Gathering" = 2    # warm; NOT an alias of Prospect on this object
    "In Discussion"         = 3
    "Agreement Sent"        = 4
    "Invoice Sent"          = 5
    "Payment Received"      = 6
    "Customer"              = 7
    "Closed - Lost"         = 99
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

    # Disposition values below are the EXACT live mx_Call_Disposition dropdown options, read from
    # the schema on 2026-07-31, not invented names. A stored value that is not an option in its
    # own dropdown cannot be selected or filtered by reps, which defeats the field.
    #
    # The earlier plan renamed two of these to "RNR (5+ dials)" and "Follow Up (pitch delivered)".
    # Both were dropped (Kaustubh, 2026-07-31): the legacy data never recorded a dial count, and
    # "Follow Up" does not establish that a pitch was delivered. Asserting either would be
    # inventing precision the source data does not support.

    # ---- Fresh: ONLY leads nobody has dialled yet. ----
    # Changed 2026-07-31 (Kaustubh). Originally the three un-connected outcomes below mapped to
    # Fresh, on the logic that no human was ever reached. Operationally that broke the bucket
    # reps depend on: "Fresh" is where they hunt for new accounts to call, and 17,019 leads they
    # had already dialled repeatedly were sitting in it. Fresh now means "not yet dialled"; a
    # dialled-but-unconnected lead is work in progress, so it sits in Engaged with the reason it
    # did not connect recorded in Call Disposition.
    #
    # Known trade-off, accepted: Engaged no longer means "reached a human" - roughly 79% of it
    # will be dial-attempts. Use Call Disposition to tell the two apart.
    "Fresh Lead"                 = @{ Contact = "Fresh"; Company = "Fresh" }
    "Didn't Picked"              = @{ Contact = "Engaged"; Company = "Nurture"; Disposition = "Did Not Pick" }
    "RNR"                        = @{ Contact = "Engaged"; Company = "Nurture"; Disposition = "RNR" }
    "Switched Off/Not Reachable" = @{ Contact = "Engaged"; Company = "Nurture"; Disposition = "Switched Off/Not Reachable" }

    # ---- Engaged: reached a human, no requirement stated yet ----
    "Call me Later"           = @{ Contact = "Engaged"; Company = "Nurture"; Disposition = "Call me Later" }
    "Follow Up"               = @{ Contact = "Engaged"; Company = "Nurture"; Disposition = "Follow Up" }
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

    # 'Future Prospect' maps to ITSELF on the contact. It is a canonical stage, not a legacy
    # value to be translated away.
    #
    # This entry must stay in the map rather than being deleted: 12-reconcile-contacts.ps1
    # treats an unmapped stored value as 'Unmapped' and reports it as drift needing
    # attention, so removing it would trade a wrong migration for a permanent false alarm.
    # Mapping it to itself makes the reconciler a no-op for these contacts, which is exactly
    # what is wanted - it will keep filling Reason and Category, which are still correct.
    "Future Prospect" = @{ Contact = "Future Prospect"; Company = "Future Prospect"
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

$Script:MigrationDataDir = Join-Path $PSScriptRoot "..\..\data"
