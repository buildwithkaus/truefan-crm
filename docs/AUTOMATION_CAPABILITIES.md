# What can actually be automated — verified, not assumed

Written 2026-07-28 in answer to a direct question: *are you 100% sure about the automated
workflows for opportunity creation and trigger-based stage changes?*

**Short answer: no — and that is exactly why the sync engine is built as a script rather than
as LeadSquared native automation.** Everything below is marked with how it was established.
"Verified" means tested against the live account today, with a negative control. "Unverified"
means nobody has tested it and it should not be relied on.

---

## 1. Native LSQ automation — RESOLVED 2026-07-28, it can do this

**This section previously said the answer was unknown. It is now answered, and the answer is
yes.** Native automation is the primary mechanism; the script is the safety net. Full build
spec: `docs/LSQ_AUTOMATION_SPEC.md`.

| Question | Status |
|---|---|
| Can automation create an Opportunity when a Lead field changes? | **YES** — `Add Opportunity` is a **Lead** automation action, with Type/Enquiry/Owner/Status/Stage configurable |
| Can automation update the related Company/Account? | **YES** — `Update Account` is a Lead automation action. LSQ's docs give our exact use case |
| Can automation traverse Opportunity -> Lead -> Company (3 hops)? | **Not needed.** Opportunities are activities on the lead (verified live: `12000 \| Opportunity`, `33 \| Opportunity Captured`), so a **Lead** automation can react to opportunity changes and it already has both write actions |
| Can dropdown options be pushed to a *system* field (`ProspectStage`) via API? | **Unverified** — docs only show `mx_` fields. UI instead |
| Does renaming a dropdown value carry existing records' stored values? | **Unverified** — renames are *tracked* (`OldValue` seen live), but whether data follows is untested |

**Why this was previously wrong:** `Add Opportunity` is absent from the *Opportunity*
automation actions page — it lives under *Lead* actions, because it acts on a lead. Reading
only the opportunity page produced a false negative. Opportunity automations genuinely cannot
update the parent lead or account, which is why every rule is built as a Lead automation.

Six items still need confirming on-screen during the build (owner assignment being the one
that actually matters) — listed in `LSQ_AUTOMATION_SPEC.md`.

---

## 2. What was verified today, against the live account

These were tested, each with a negative control, because a wrong assumption here is what
silently skipped 20,076 leads last time.

### 2.1 The watermark works — and MUST be UTC

A polling sync engine needs "records changed since X". Confirmed working on `ModifiedOn`, with
a clean monotonic curve (1000 / 1000 / 527 / 344 / 133 / 0 across the day) and a negative
control at a future date returning 0.

**But LeadSquared stores timestamps in UTC while this account operates in IST (UTC+5:30).**
Proven directly:

```
UTC-correct    ModifiedOn > 2026-07-28 08:08:44  ->  352 rows
local (wrong)  ModifiedOn > 2026-07-28 13:38:44  ->    0 rows
```

A watermark built from local `Get-Date` is 5.5 hours in the future and matches **nothing,
forever**. The sync would appear to run fine and do absolutely nothing — the same class of
silent failure as the `Invalid/ Junk` bug. Handled by `Get-LsqTimestamp` in `common.ps1`;
never format a timestamp by hand.

### 2.2 `IsPrimaryContact` has two separate quirks

- **Reading**: returns the *string* `"1"` / `"0"` — not a boolean, not `"true"`. Comparing
  against `$true` or `"true"` is False for every record.
- **Filtering**: `LookupValue="true"` returns **HTTP 500**. `LookupValue="1"` works.
- **Writing**: `"true"` is accepted.

Three different conventions on one field. This was a live bug in code already written for this
project — every one of the 4,404 real primary contacts would have read as non-primary, and the
migration could have attached a second Opportunity to a different contact at the same account.
Handled by `Test-LsqTrue` in `common.ps1`. Verified count with the correct filter: **4,404**,
exactly matching the Phase 3 backfill.

### 2.3 There is no bulk Opportunity read

Probed eight endpoint names. All 404 except per-lead access:

- `GetOpportunitiesOfLead?leadId=X&opportunityType=12000` — works (`opportunityType` is
  **required**, not optional as the docs imply)
- `ProspectActivity.svc/Retrieve?leadId=X` — works, returns all activities for one lead
- `OpportunityManagement.svc/{Opportunity.Get, Opportunities.Get, Retrieve, Search,
  GetOpportunities, Opportunity.GetByType}` — all 404
- `ProspectActivity.svc/{Advanced/Retrieve/BySearchParameter, Retrieve/BySearchParameter,
  RetrieveByActivityEvent}` — all 404

**Consequence for the design:** any opportunity-driven sync costs one API call per lead. That
rules out a full sweep every cycle and makes watermark-scoping mandatory rather than merely
nice. At the observed change rate (~133 leads/hour in business hours) a 15-minute cycle
processes ~35 records — a few seconds of work.

### 2.4 LSQ already logs stage changes

Activities of `EventCode 3002 / "StageChange"` are written automatically on every stage change.
Useful later for funnel velocity reporting (time-in-stage) without building anything.

### 2.5 Opportunity "Stage" is a custom field

`mx_Custom_2`, a dependent dropdown with `ParentField = "Status"`. The native `Status` field is
what reps see labelled **"Deal Stage"**. Writing a stage name into `Status` fails.

---

## 3. What is built and runnable now

All parse-clean, ASCII-only, and **nothing has been run against production**.

### Migration — `scripts/leadsquared/migration/`

One command, unattended, checkpointed, idempotent. See `MANUAL_STEPS.md` for prerequisites.

| Script | Purpose |
|---|---|
| `00-schema.ps1` | Declarative stage values, 29-entry mapping, field definitions |
| `01-create-fields.ps1` | Creates the 4 new Lead custom fields |
| `02-build-worklist.ps1` | Enumerates live values, **aborts on any unmapped value**, builds worklists |
| `03-backup.ps1` | Full state snapshot — the rollback |
| `04-migrate-leads.ps1` | Contact stages + reasons/categories/dispositions/segments |
| `05-migrate-companies.ps1` | Company stages + future-prospect reasons |
| `06-create-opportunities.ps1` | Deals for primary contacts, check-before-create |
| `07-verify.ps1` | Reconciliation, residue, sampling, cross-object consistency |
| `08-rollback.ps1` | Restores Lead + Company stages from a backup set |
| `run-migration.ps1` | Runs 02-07 in sequence |

### Sync engine — `scripts/leadsquared/sync/`

| Script | Purpose |
|---|---|
| `sync-rules.ps1` | **Pure** decision logic. Every if/else/then in the funnel. No API calls. |
| `test-sync-rules.ps1` | **46 offline tests, all passing.** No API needed. Run after any rule edit. |
| `sync-engine.ps1` | Applies the rules against the live API. Watermark-scoped; `-FullScan` for nightly reconciliation. |
| `validate-consistency.ps1` | Nightly drift detector — 7 violation classes |
| `report-reactivation.ps1` | Supply Gap / Commercial Mismatch accounts that convert themselves |

Splitting the rules out as pure functions is what makes the funnel logic genuinely testable on
a project with no test framework and a live production database. The 46 tests include the
regression guards that matter most:

- a follow-up call on a live deal must **not** drag it back to Engaged
- a second contact at an account must **not** open a second deal
- a disqualified primary must **not** park an account that still has live contacts

### The sync engine's decision table

| Situation | Contact | Company | Opportunity |
|---|---|---|---|
| First activity of any kind, contact was Fresh | -> Engaged | -> Nurture | — |
| Any later activity, contact past Fresh | unchanged *(guarded)* | unchanged | — |
| Rep sets contact = Prospect, account has no open deal | Prospect | -> Opportunity | **created** at Prospect |
| Rep sets contact = Prospect, account already has a deal | Prospect | unchanged | **not created** (collision, reported) |
| Opportunity at any Open stage | -> Prospect | -> Opportunity | — |
| Opportunity -> Payment Received or Customer | -> Customer | -> Customer | — |
| Opportunity -> Closed - Lost | -> Disqualified | -> Future Prospect | — |
| Rep sets contact = Disqualified | Disqualified | -> Future Prospect | — |

Company follows the **primary contact**. The single exception is the `Fresh -> Nurture` bump,
which any contact's first activity may trigger — so an account is never left at Fresh while one
of its contacts is already Engaged.

---

## 4. What still has to be done by hand

Genuinely not automatable. Everything else is scripted.

| Task | Why manual | When |
|---|---|---|
| Add 5 `ProspectStage` values | `ProspectStage` is a **system** field; option-push is undocumented for those | Before migration |
| Add 5 Company `Stage` values | No Company field API at all | Before migration |
| Create 3 Company fields | No Company field-creation endpoint exists | Before migration |
| Rename 5 Opportunity stages + add `Customer` | Opportunity Type editing is UI-only (confirmed) | Before migration |
| Create 2 Opportunity date fields | Same | Before migration |
| Verify rename-carry behaviour | 5-minute test on a throwaway field | Before migration |
| Make activity fields mandatory | Activity type config is UI-only | **After** rep briefing |
| Make Company Stage read-only for reps | Permissions are UI-only | After briefing |
| Schedule the sync engine | One Task Scheduler entry (command below) | After migration |
| Delete any duplicate Opportunity | `CanDelete: false` on the Opportunity Type blocks API deletion | As needed |

Roughly **45 minutes of UI work**, all of it in `MANUAL_STEPS.md` with a checklist.

### Scheduling the sync engine

```powershell
# Every 15 minutes:
schtasks /Create /TN "TrueFan CRM Stage Sync" /SC MINUTE /MO 15 ^
  /TR "powershell.exe -ExecutionPolicy Bypass -File C:\Users\kaust\truefan-crm\scripts\leadsquared\sync\sync-engine.ps1 -Execute"

# Nightly reconciliation + drift report at 02:00:
schtasks /Create /TN "TrueFan CRM Nightly Reconcile" /SC DAILY /ST 02:00 ^
  /TR "powershell.exe -ExecutionPolicy Bypass -File C:\Users\kaust\truefan-crm\scripts\leadsquared\sync\sync-engine.ps1 -Execute -FullScan"
```

**Do not schedule these until the migration has run and verified.** And never let two API
scripts run at once — the rate limit is account-wide and a concurrent run has already caused
23 silent write failures on this account.

---

## 5. Where this is still weak

Stated plainly rather than buried. This list changed substantially once native automation was
confirmed and the official Feature Guide was reviewed.

1. **Loop risk is the main hazard, and it bites at BUILD time.** LSQ **refuses to publish**
   configurations it thinks can loop — including the specific pattern of two automations
   sharing a trigger. That is why the spec has three automations, not five. At runtime, LSQ
   also auto-terminates any automation that fires 50 times for one lead in a day: it *stops*
   rather than throttles, so a loop silently ceases working for those records. See
   `LSQ_AUTOMATION_SPEC.md`.
2. **Conditions must use `Latest Data`, not `Triggered Data`.** `Triggered Data` evaluates a
   field as it was when the automation fired, so a guard reads stale state and fires anyway.
   Both look equally correct in the UI. This is the easiest correctness bug to introduce.
3. **Failures are visible, but nobody is looking.** LSQ has native Automation Failure,
   Termination, Usage and per-object reports — so this is a monitoring gap, not a blindness
   gap. `validate-consistency.ps1` remains complementary rather than redundant: the native
   reports say whether an automation *errored*, the script says whether the *data is right*
   (a contact at Prospect with no deal, an account with two primary contacts). Cross-object
   checks no single-object report can make.
4. **Automations only act on records that change after they are switched on.** Existing records
   are migrated by the one-command migration, not by automation. The two are complementary.
5. **Owner assignment on auto-created Opportunities is unconfirmed.** If `Add Opportunity`
   cannot set Owner dynamically from the lead, every auto-created deal lands on a default owner
   and needs reassignment. Verify this early — it is the one unknown with real operational cost.
6. **The automation publish limit is unknown.** LSQ caps published automations (and Forms) by
   plan tier. Three automations is modest, but confirm the headroom with the account manager
   before building.
7. **Nothing here handles the payment schedule.** Tranched PIs remain out of scope by decision,
   and that is still the biggest structural gap in the model.
