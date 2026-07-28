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

## ProspectStage — current state: 28 values (CORRECTED 2026-07-28), mixing 4 different concepts

**The earlier 26-value list in this file had three wrong strings and was missing three
values.** Corrected by a full paginated enumeration of all 86,628 leads — tallying actual
stored values rather than probing a guessed list. Counts reconcile to exactly 86,628 with
**0 blank/null** stages.

| Value (exact string) | Count |
|---|---|
| Disqualified | 25,078 |
| **`Invalid/ Junk`** (space after the slash) | **17,340** |
| Didn't Picked | 12,094 |
| Low Budget | 5,891 |
| Wrong Number | 4,753 |
| Switched Off/Not Reachable | 4,649 |
| **`Just Enquiring, No Intent`** (comma) | **2,736** |
| Future Prospect | 2,686 |
| Follow Up | 2,558 |
| No Requirement of Celeb in Ads | 1,901 |
| Fresh Lead | 1,825 |
| Call me Later | 1,436 |
| Requirement Gathering (Warm) | 667 |
| Does not want AI | 612 |
| SaaS | 567 |
| B2B-Disqualified | 543 |
| Not Active After First Conversation | 356 |
| RNR | 276 |
| Payment Received | 193 |
| Conversation In Progress (Hot) | 147 |
| Supply Issue | 103 |
| Retargetedlead | 92 |
| **`Not Interested`** (undocumented) | **86** |
| **`Requirement Gathering`** (no "(Warm)", undocumented) | **12** |
| FB Lead - Website | 10 |
| ReQualified By WhatsApp | 7 |
| **`Contract Follow Up`** (undocumented) | **6** |
| Conflict | 4 |

`RetargetedleadEMAIL` exists in the dropdown but holds **0 records**.

### The string-mismatch bug this exposed — 20,076 leads silently skipped

`backfill-call-disposition-disqualification.ps1` (Phase 5, run 2026-07-27) probed
`Invalid/Junk` and `Just Enquiring No Intent`. Both returned **0 leads**, and the run logged
that as fact. The real strings are `Invalid/ Junk` and `Just Enquiring, No Intent` — so
**17,340 + 2,736 = 20,076 leads never got `mx_Disqualification_Reason` backfilled**. The
three undocumented values (104 leads) were never in the mapping at all.

This is exactly the failure mode `CLAUDE.md` warns about — a zero-row result believed
without a negative control. The rule has to be applied to *zero* results too, not just
suspicious non-zero ones. **Lesson: enumerate actual stored values; never probe a list of
guessed strings.** A paginated tally that reconciles to the known record total is the only
trustworthy way to enumerate a dropdown's real contents.

**Superseded**: the 4-way split previously sketched here is replaced by the locked design in
`docs/STAGE_RESTRUCTURE_PLAN.md` (Contact: Fresh/Engaged/Prospect/Customer/Disqualified).

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
