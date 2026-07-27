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

## Proposed Opportunity Stage (Open) / Loss Reason (Lost) design

- Open: Requirement Gathering → Celebrity/Product Proposed → Contract Sent → Payment
  Pending
- Won: Payment Received
- Lost: single status, reason captured in a separate `Loss Reason` field reusing the
  disqualification taxonomy from `01-lead-schema-audit.md` — don't re-encode reasons as
  stages, that's the exact mistake being fixed on the Lead side.
- Renewal: **new Opportunity linked via a `Renewed From` lookup field**, not an extension
  of the original. This was an open question in the Pipeline Centralization email;
  resolved this way so renewal rate and new-logo rate stay separately reportable.

## Proposed new Opportunity fields (beyond platform defaults)

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
