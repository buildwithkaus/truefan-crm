# Lead object — schema audit (pulled 2026-07-27 via `LeadsMetaData.Get`)

Raw dump: `data/lead_fields_schema.json` (not in git; re-pull via
`LeadManagement.svc/LeadsMetaData.Get`).

- **142 total fields**: 84 system, 58 custom (`mx_` prefix).
- Custom fields cluster into: deal specifics (`mx_Selected_Celebrity`,
  `mx_Selected_Product` — 5 fixed SKUs, `mx_Budget`), qualification
  (`mx_Qualified_Business`, `mx_Business_Model` B2B/B2C, `mx_Industry_Type`,
  `mx_Company_revenue`, `mx_Marketing_Budget_monthly`, `mx_CIN`), ops/legal
  (`mx_Contract_Task`, `mx_Payment_Task`, `mx_Follow_Up_Task` — dates, not objects),
  channel attribution (`mx_Ad_Id/Name/set`, `mx_Campaign_Id/Name`, `mx_FB_LeadGen_ID`),
  telephony (Callkaro integration fields, `mx_AI_Follow_Up_Date_and_Time`).
- `IsPrimaryContact` (system field) exists and is **currently unused** — adopted as the
  rule for which Lead under a Company is allowed to own an Opportunity (see
  `03-object-model-and-relationships.md`).
- `ProspectActivityDate_Max` = true "Last Activity Date" (not `ModifiedOn`, which changes
  on any edit including automated field updates). Use this for any "is this lead actually
  being worked" filter.

## ProspectStage — current state: 26 values, mixing 4 different concepts

Full list (verified live, not from docs): Fresh Lead, Conversation In Progress (Hot),
Requirement Gathering (Warm), ReQualified By WhatsApp, SaaS, No Requirement of Celeb in
Ads, Conflict, Retargetedlead, RetargetedleadEMAIL, Payment Received, Disqualified,
Invalid/Junk, Not Active After First Conversation, Future Prospect, Follow Up, Call me
Later, Didn't Picked, RNR, Wrong Number, Low Budget, Supply Issue, Does not want AI, Just
Enquiring No Intent, Switched Off/Not Reachable, FB Lead - Website, B2B-Disqualified.

**Proposed split** (design, not yet migrated — see `06-stage-taxonomy-design.md` for the
full mapping):
- Kept as lifecycle stage (6): Fresh Lead → Contacted → Engaged → Requirement Gathering
  (Warm) → Hot → Converted to Opportunity
- Moves to Activity Disposition: RNR, Didn't Picked, Call me Later, Switched Off/Not
  Reachable, Wrong Number
- Moves to a new Disqualification/Loss Reason field: Low Budget, Supply Issue, Conflict,
  No Requirement of Celeb in Ads, Does not want AI, Just Enquiring No Intent, Invalid/Junk
- Moves to Source/Segment attributes: SaaS, FB Lead - Website, B2B-Disqualified,
  Retargetedlead, RetargetedleadEMAIL, ReQualified By WhatsApp

## Data quality flags

- `mx_How_Did_You_Find_Us` is configured as dropdown-with-others but has 100+ raw
  free-text values leaking in as if they were options, including at least one full
  customer inquiry with a real name and company. Unbounded/dirty field.
- `Source` field has 50+ values mixing real channels (Facebook, Google Ads, LinkedIn) with
  one-off tags (`QA_AGENT`, `FB_Lead_QA_Agent_Team`, `mehak reference`, `Calendly`) — not
  cleaned, not in scope for this project yet.

## Verified finding: "recent activity" is mostly disqualification work, not live pipeline

Corrected analysis (2026-07-27, see the API gotcha in `CLAUDE.md` for why the first attempt
was wrong — it used a silently-ignored filter): of 51,008 leads with `ProspectActivityDate_Max`
≥ 2026-05-27 (last 2 months), **59.5% (30,335) are in a clearly terminal-disqualified
state**, **24.8% (12,666) are stuck in `Didn't Picked`/`RNR`** (call-outcome-as-stage
limbo — these look dead but are really just an un-retried call attempt), only **15.6%
(7,974) are in a genuinely live stage**, and a mere **33 (0.06%) converted to Payment
Received** in the whole 2-month window. This is direct evidence for the stage-taxonomy
diagnosis: because disposition and lifecycle stage share one field, un-retried call
attempts become indistinguishable from true dead leads and silently fall out of the
follow-up queue.
