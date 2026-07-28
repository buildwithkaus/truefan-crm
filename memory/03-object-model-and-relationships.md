# Object model and relationships (researched 2026-07-27, help.leadsquared.com + apidocs.leadsquared.com)

## Structure: Company → Lead → Opportunity → Activity

**Opportunities attach to a Lead, not directly to a Company.** A Company reaches its
Opportunities only transitively, through the Leads under it. A Lead can carry more than
one Opportunity. Source: help.leadsquared.com/leads-opportunities-and-accounts,
help.leadsquared.com/opportunity-management-feature-guide.

**Adopted rule**: only the Lead flagged `IsPrimaryContact = true` may own an Opportunity
for its Company. Every other contact at that company is a stakeholder (buying-committee
member), not a separate deal. `IsPrimaryContact` exists on Lead today and is unused —
this is a zero-cost adoption, not a new field. This is also where the "buying-committee
mapping" step from the Outreach Model email plugs into the data model.

## Opportunity — confirmed active (paid module), zero Opportunity Types configured

- Status is **fixed and non-editable**: Open / Won / Lost. Cannot add more statuses.
- Stage is a **dependent dropdown under Status** — admins define stage names per status.
- Default/standard fields on a new Opportunity Type: Status, Owner, Stage (mandatory) +
  Notes, Description, Source, Campaign, Expected/Actual Deal Size, Expected/Actual
  Closure Date, Product.
- No default Opportunity Type ships out of the box — must be created from scratch.
- **Creating an Opportunity Type is UI-only** (My Profile > Settings > Opportunities >
  Opportunity Types > Create). No API found. `GetOpportunityTypeMetadata` only reads an
  existing type by its `code` — can't be used to discover types that don't exist yet.

## Opportunity Type — built 2026-07-27, Stage dropdown corrected in UI (re-verified live 2026-07-28)

`GetOpportunityTypes` / `GetOpportunityTypeMetadata?code=12000` confirms a Type exists
(`EventCode 12000`, `DisplayName "Opportunity"`, modified by Kaustubh Chauhan).

**Critical structural finding (2026-07-28): "Stage" is NOT the native LSQ stage construct —
it is a custom field, `mx_Custom_2`, a SearchableDropdown with `ParentField = "Status"`.**
The native `Status` field is displayed to reps as **"Deal Stage"** and holds the fixed
Open/Won/Lost values. Anything reading or writing opportunity stage must target
`mx_Custom_2`, not `Status`. `scripts/leadsquared/resume-opportunity-backfill.ps1` already
does this correctly.

**The Phase 3 blocker recorded in `PROJECT_PLAN.md` was already resolved** — the UI edit was
done and the generic template values (Prospecting/Qualification/Need Analysis/...) are gone.
As-built and verified live 2026-07-28:

| Status | `mx_Custom_2` Stage values |
|---|---|
| Open | Requirement Gathering, Celebrity/Product Proposed, Contract Sent, Payment Pending |
| Won | Payment Recieved *(sic — typo in the live value)* |
| Lost | Closed - Lost |

**Renames are supported and tracked in place.** The Won option carries
`"Value":"Payment Recieved","OldValue":"Closed - Won"` — proof that a dropdown value can be
renamed rather than recreated. This is the basis of the cheap-migration path in
`docs/STAGE_RESTRUCTURE_PLAN.md` section 7.1 (rename buckets whose entire population maps to
one new value; write only the deltas). **Whether a rename carries existing records' stored
values is still unverified — test on a throwaway field before depending on it.**

Under the 2026-07-28 locked design these five values are renamed to: Prospect, In Discussion,
Agreement Sent, Invoice Sent, Payment Received (typo fixed), plus a new Won value `Customer`.

Confirmed built custom fields (schema name → display name): `mx_Custom_1` → Opportunity Name
(mandatory), `mx_Custom_2` → Stage (mandatory, dependent on Status), `mx_Custom_10` → Product,
`mx_Custom_13` → Celebrity Assigned, `mx_Custom_14`/`mx_Custom_15` → Contract Start/End
Date, `mx_Custom_4` → Loss Reason, `mx_Custom_12` → Renewed From, `mx_Custom_6`/`mx_Custom_7`
→ Expected/Actual Deal Size, `mx_Custom_8`/`mx_Custom_9` → Expected/Actual Closure Date.

## Proposed Opportunity Stage (Open) / Loss Reason (Lost) design (original proposal — see
note above on what was actually built)

- Open: Requirement Gathering → Celebrity/Product Proposed → Contract Sent → Payment
  Pending
- Won: Payment Received
- Lost: single status, reason captured in a separate `Loss Reason` field reusing the
  disqualification taxonomy from `01-lead-schema-audit.md` — don't re-encode reasons as
  stages, that's the exact mistake being fixed on the Lead side.
- Renewal: **new Opportunity linked via a `Renewed From` lookup field**, not an extension
  of the original. This was an open question in the Pipeline Centralization email;
  resolved this way so renewal rate and new-logo rate stay separately reportable.

## Proposed new Opportunity fields (beyond platform defaults) — all confirmed built

| Field | Type | Source |
|---|---|---|
| Product / Package | Dropdown | `mx_Selected_Product`'s 5 existing SKUs |
| Celebrity Assigned | Text/Lookup | `mx_Selected_Celebrity` |
| Contract Start / End Date | Date | new — needed for renewal tracking |
| Loss Reason | Dropdown | new — disqualification taxonomy |
| Renewed From | Lookup (parent Opportunity) | new |

## Open technical question — not yet validated

Can LeadSquared's native automation update a Company field off an Opportunity change
three hops away (Opportunity → Lead → Company)? This is needed to make `Company.Stage`
an automatic rollup (Prospect/Opportunity/Customer) instead of something set by hand.
Not verified either way — validate with LeadSquared support or a scheduled API job before
committing to native automation for this.
