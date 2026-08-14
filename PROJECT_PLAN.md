# Project Plan — TrueFan CRM Pipeline & Funnel Fix

Status as of 2026-08-09. Read `CLAUDE.md` first for orientation and the hard rules, and
`docs/LSQ_API_GOTCHAS.md` for the API failure modes that apply to every phase below.

Latest: **Phase 12** (2026-08-13) answers "why don't leads buy" from the calls that actually
caused each disqualification — see `memory/14`. **Phase 11f** (2026-08-12) fixed the
`channel_bundle` statement timeout by deleting work no tab rendered.

**Where the project actually is:** the data-model work (Phases 1-5R) is done and reconciled.
Phase 10 — the real-time calling pipeline — is **live and reconciling exactly** against an
independent recount, and now covers the deal funnel end to end (10b, 10c). The live work is
Phase 9, running the ICP assignment programme, plus three things Phase 10 surfaced that are
business decisions rather than engineering: making the forecast fields mandatory *with
validation*, clearing the CRM hygiene backlog, and deciding what happens to the 35,811
contacts nobody owns. Phases 6 (automation) and 7 (training) remain open and are what would
make Phase 9's findings self-correcting rather than something a report has to catch.

## Phase 0 — Foundation (done before this repo existed)

- Company object activated: 71,467 records bulk-created from Lead.Company (2026-07-22).
- Opportunities module confirmed active on the account (paid add-on, enabled).
- Active rep roster confirmed (18 reps, `memory/04-active-rep-roster.md`).

## Phase 1 — Data model & schema audit — **done**

Full schema pulled and documented: Lead (142 fields), Company (~48 fields, 71K records,
~0% enriched), Activity (57 types), Opportunity (0 Types configured, platform defaults
researched). Object relationship model confirmed (Company → Lead → Opportunity →
Activity, not Company → Opportunity directly). Stage taxonomy designed (4-layer split).
Field reparenting map built (which Lead fields are really Company attributes).

See `memory/01` through `memory/03`, `memory/06`.

## Phase 2 — Departed-owner cleanup — **done**

20,837 Leads + 9,104 Companies (10,972 minus the 1,868 mislabeled as Rishi's, see below)
reassigned from the departed owners to Admin. Full backup taken before the write.
**Final state, verified 2026-07-27 19:00**: Leads 20,837/20,837, Companies 9,104/9,104 -
both confirmed via independent re-fetch + random sampling, not just response bodies. Hit
a false-100%-failure signal earlier caused by a zombie process left running old code
after a mid-run fix (see incident write-up in `memory/05-departed-owner-reassignment.md`).

**Second incident, more serious**: the departed-owner reference data attached the name
"Piyush Das Pattnaik" to **Rishi Saraswat's** real `OwnerId` — an active rep. Consequence:
2,360 of his Leads *and* 1,868 Companies (mislabeled as Piyush's) were in scope. Caught by
the rep reporting a missing live contact. **Leads fixed and verified** (rolled back to
Rishi, 2,360/2,360). **Companies confirmed untouched** (0 of the 1,868 had been reassigned
before the run was paused) and permanently excluded via a corrected worklist
(`data/departed_owner_companies_BACKUP_corrected.json`, 9,104 rows). Final random-sample
re-check (30 companies from the corrected list, 10 of Rishi's excluded ones): 0 gaps,
0 wrongly touched. See `memory/05-departed-owner-reassignment.md` and
`memory/04-active-rep-roster.md` for full detail.

**Also hit and resolved during the resume**: a brief rate-limit collision (account cap
`20 calls/5 sec`) when a second script (Phase 3's Opportunity backfill) was run
concurrently — caused 23 transient Company-write failures. Self-recovered once the
concurrent script was stopped; all 23 retried and confirmed (22 needed a real retry, 1 had
actually succeeded server-side despite a dropped-connection error on the client side).
**Lesson**: don't run two scripts that both hit the LSQ API at meaningful volume at the
same time, even against different endpoints - the rate limit is account-wide.

**Verification performed on the fix**: checked three independent ways (name-text
cross-check, GUID cross-check of the reference file, and GUID cross-check of the actual
`OrigOwnerId` values in both backup files) against all 18 active reps' real GUIDs
(resolved live, not assumed from display names). All three agree this is the only overlap
— no other active rep was affected, in either Leads or Companies.

**Known gap, not urgent**: "Piyush Das Pattnaik" (if a real distinct departed rep) now has
zero leads/companies correctly captured anywhere in this migration, since his name was
attached to the wrong GUID — he's missing, not damaged. Would need his real `OwnerId`
identified for a follow-up pass.

**Why this is Phase 2, not later**: the account-based rep assignment (Phase 6) and the
GTM engineer's ICP tiering both need an accurate picture of who owns what right now. Stale
ownership under departed reps would corrupt both.

## Phase 3 — Activate the Opportunity object — **backfill done, 4,404/4,404**

Opportunity Type created 2026-07-27, confirmed live via API — all proposed custom fields
present (`memory/03-object-model-and-relationships.md`). Stage dropdown mismatch (generic
as-built values vs the TrueFan-specific design) was fixed by Kaustubh directly in the UI
2026-07-27.

**Backfill complete**: every Company at `Stage = Opportunity` (4,289) or `Stage = Customer`
(142) now has a corresponding Opportunity record, using the most-recent-activity Lead as
`IsPrimaryContact` (Kaustubh's decision 2026-07-27). Final reconciliation against the
4,404-company worklist: 2,394 already existed from the original run (paused mid-way after
a design question), 1,886 created in the corrected resume, 121 created in a straggler
retry, 3 already existed by the time the retry ran (ambiguous-outcome writes that had
actually landed) — **4,404/4,404, 0 net failures**. Spot-checked via independent
`GetOpportunityDetails`/`GetOpportunitiesOfLead` re-fetch throughout, not response bodies
alone.

**Two issues hit and fixed along the way**:
1. **Non-idempotent Capture API**: `OpportunityManagement.svc/Capture` does not dedupe
   (`IsUnique: true` even on a genuine second create) — a blind re-run of the full worklist
   after a pause would have created a second Opportunity per company already done. Fixed by
   always checking `GetOpportunitiesOfLead?...&opportunityType=12000` (the `opportunityType`
   param is required, not optional as the docs imply) before writing. One duplicate slipped
   through before this was in place — "Pomees" company has two Opportunities; API delete is
   blocked (`CanDelete: false` on the Opportunity Type), flagged for manual UI cleanup.
2. **UTF-8 body-encoding bug** (new gotcha, added to `CLAUDE.md`): non-ASCII characters in
   `CompanyName` (°, É, é, ®) corrupted the JSON request body under Windows PowerShell 5.1's
   default `Invoke-RestMethod` string encoding, causing 4 genuine (non-transient) 400 errors.
   Fixed by explicitly sending UTF-8 bytes with `charset=utf-8` on the Content-Type header;
   smoke-tested and independently re-verified before retrying at scale.

**Still open, not urgent**: `IsPrimaryContact` rule enforcement going forward (only
primary-contact Leads should own an Opportunity) needs either training (Phase 7) or a
periodic validation script — no enforcement mechanism built yet, this backfill only handled
the one-time catch-up.

## Phase 4 — Company enrichment & dedup — **in progress (4 of 6 fields), 2 fields blocked**

Runs in parallel with the GTM engineer's ICP/TAL work, not instead of it — enrich the
*existing* 71,467 Company records rather than building a separate dataset. Backfill from
the Lead-side fields per the reparenting map in `memory/02-company-schema-audit.md`.

**Confirmed backfilling now** (smoke-tested 2026-07-27, format-compatible): `CIN_Company`,
`Budget_Company` (source resolved: `mx_Budget`), `Website`, `qualified_business` (very low
fill rate, ~0.4%), `mx_business_model` (only the 0.4% of leads with a clean `B2B`/`B2C`
value — the rest of that Lead field is free text, not usable).

**Blocked, need a decision** (`08-open-decisions.md`): `Industry` (Company side is a
strict dropdown, Lead-side source is free text — need the dropdown's valid option list
from the LSQ UI) and `AnnualRevenue` (Company side expects a Decimal, Lead-side source is
bucketed range text — need a bucket-to-number conversion rule). Neither blocks the other
4 fields' backfill.

Dedup pass on near-duplicate CompanyName records — sizing this precisely needs a proper fuzzy-match
pass, not yet done.

## Phase 5 — Lead lifecycle stage migration (additive, careful) — **steps 1-2 done**

Fields created and backfilled 2026-07-27: 35,496/35,496 leads updated, 0 failures
(`data/call-disposition-disqualification_log.txt`). Spot-checked via independent re-fetch.
One known small gap: leads whose `ProspectStage` changed to a mapped value *after* the
one-time worklist was built (~16:19-16:20) weren't covered — e.g. one `B2B-Disqualified`
lead found empty on spot-check. Not a write failure, just a live-system timing gap; a cheap
incremental follow-up pass (re-run the same source-stage counts, diff against what already
has a value) would catch stragglers whenever convenient, not urgent.

**Bigger gap found 2026-07-28 — 20,076 leads silently skipped.** The run probed
`Invalid/Junk` and `Just Enquiring No Intent`, got **0 rows for both**, and logged that as
fact. The real stored strings are **`Invalid/ Junk`** (space after the slash, 17,340 leads)
and **`Just Enquiring, No Intent`** (comma, 2,736 leads). Neither ever got
`mx_Disqualification_Reason` written. Three further undocumented values
(`Not Interested` 86, `Requirement Gathering` 12, `Contract Follow Up` 6) were never in the
mapping at all. This is the exact zero-result-believed-without-a-negative-control failure
`CLAUDE.md` warns about — the rule has to be applied to *zero* rows too. Corrected value list
and counts (reconciling to all 86,628 leads): `memory/01-lead-schema-audit.md`. Remediation is
folded into the Phase 5R night run, not run separately.

`Call Disposition` and `Disqualification Reason` both carry forward into Phase 5R unchanged —
they are reused by the locked design, not replaced. Step 3 of the original plan (cutting
`ProspectStage` over to a clean list) is **superseded by Phase 5R below**, which replaces the
6-value lifecycle sketch with the locked Contact model. (That model is itself now SIX values - Future Prospect was corrected from a legacy value to a real contact stage on 2026-08-12; see migration 030.)

## Phase 5R — Stage restructure across all three objects — **DATA MIGRATION DONE 2026-07-31; automations still outstanding**

Design locked 2026-07-28 by Kaustubh. **Full plan: `docs/STAGE_RESTRUCTURE_PLAN.md`.
Rep-facing SOP: `docs/SOP_PIPELINE.md`.** Supersedes the 4-layer sketch previously in
`memory/06-stage-taxonomy-design.md`.

### Migration executed 2026-07-30/31

| Step | Result |
|---|---|
| `06b` legacy Opportunity stages | 4,404 moved off `Requirement Gathering`/`Payment Recieved`; 50/50 verified |
| `03` backup (rollback set) | leads 86,968 + companies 71,878, stamp `20260730-074038` |
| `01` Lead fields | 4 created (Category, Segment, Revisit After, Needs Contact Resourcing) |
| `04` Lead stages | 61,496 written |
| `04b` residual sweep | 805 fixed |
| `04c` mapped-field gaps | 25,497 disqualification reason/category (see the bug note below) |
| `05` Company stages | all 71,483, zero failures |
| `06` Opportunities | 159 created, 794 already existed |
| `09`/`10`/`10b` Previous Contact Stage | 87,038 leads, zero gaps |
| `07` verify | all 5 contact-stage samples clean; 0 Opportunities on a non-canonical stage |

**The bug worth remembering:** `04` skipped rows where `OldStage -eq NewContactStage`. The legacy
value `Disqualified` maps to the new value `Disqualified` - the same string - so 25,520 leads were
logged as "already at target stage (skipped)" and never received their reason/category. Every
write log said success; only an independent read of live state exposed it. `04`'s filter now also
triggers on any mapped field being present.

### Post-migration reconciliation, 2026-07-31 - **data complete except one item**

Reps were told to keep marking the OLD stage values (there is still no easy call-outcome UI), so
drift regenerated daily. Reconcilers `11` through `17` were built to absorb it. Current state,
all verified by reading live data:

| Layer | State |
|---|---|
| Contact Stage | 100% canonical across 89,845 leads, zero legacy values stored |
| Call Disposition / Disq. Reason / Category / Segment | canonical, and every stored value is now a selectable dropdown option |
| Previous Contact Stage | 87,038 leads, zero gaps |
| Opportunity Stage | 0 on a legacy value; 961/961 deal-stage primaries have an Opportunity |
| **Company Stage** | **5,557 behind - run `13-reconcile-companies.ps1 -Execute`** |

**Fresh redefined (Kaustubh, 2026-07-31).** The three un-connected outcomes originally mapped to
`Fresh` on the logic that no human was reached. That broke the bucket reps hunt in - 17,019 leads
they had already dialled were sitting in it. `17-move-unconnected-to-engaged.ps1` moved **17,011
leads, 0 failures**; Fresh is now 4,521 genuinely un-dialled leads, with the non-connect reason
preserved in Call Disposition. `00-schema.ps1` updated to match. Accepted trade-off: `Engaged` no
longer means "reached a human" (~79% is dial attempts). Unsolved: reps read Fresh as "untouched
*by me*", and reshuffling means no static field answers that - needs reset-on-reassignment.

**Two dropdown-vs-stored-value mismatches, both found by Kaustubh trying to filter.** LSQ stores a
value that is not an option rather than rejecting it, so the record reads fine over the API while
being invisible to reps. Call Disposition (3 invented plan names, 7,570 leads normalised - two of
those names were also dropped as *unsupported by the data*: the legacy `RNR` never recorded a dial
count) and Disqualification Reason (9 options vs 12 stored values, **zero overlap, 61,919 leads
unfilterable**; fixed by extending the dropdown, since the old list could not express the new
values). `16-verify-dropdown-coverage.ps1` now checks all six Lead dropdowns at once - run it after
any future migration.

**Legacy stage retirement is now unblocked.** All 25 legacy `ProspectStage` options hold zero
records (full enumeration, twice). 20 are safe to retire immediately; 5 are preserved only because
integrations still write them (`Retargetedlead`, `RetargetedleadEMAIL`, `ReQualified By WhatsApp`,
`FB Lead - Website`, `SaaS`) and go once the integration owner moves them to Source/Segment. Exact
list: `docs/HANDOVER_2026-07-31.md` section 5.

**Still outstanding (not data):**
- The 3 native LSQ automations (`docs/LSQ_AUTOMATION_SPEC.md`) - not built. See the Phase 6 note
  on API-vs-UI triggering before specifying them further.
- Activity `01. Phone Call/ Follow Up` (event 203) already captures Status + Connected/Not
  Connected Outcome. The automation should derive Contact Stage and Call Disposition from it;
  that is what makes the stage field system-owned and stops drift at source.
- Contact `Engaged` -> `Prospect` should auto-create the Opportunity. Currently manual.
- 124 non-primary contacts sit at Prospect/Customer. Opportunities were **deliberately not**
  created for them - that is the account fragmentation rule 6 exists to prevent. Needs a rep
  decision per account.
- Two junk companies created by the bulk endpoint on `&` names need deleting in the UI:
  `a57c9ad0-1a27-4ede-bad7-0cc2eb63defd`, `d59558ea-85a1-40c5-8070-c15edc4a90a5`.

Three stage models, exactly one writable per rep:
- Contact: Fresh → Engaged → Prospect → Customer, + Disqualified (+ reason)
- Company: Fresh → Nurture → Opportunity → Customer, + Future Prospect (+ reason)
- Opportunity: Prospect → In Discussion → Agreement Sent → Invoice Sent → Payment Received
  → Customer, + Closed - Lost

**Contact Stage is the rep-driven control point**; Company and Opportunity derive from it.
Three triggers: first activity of any kind auto-moves Contact `Fresh`→`Engaged` and Company
`Fresh`→`Nurture` (guarded, fires only from Fresh); the rep **manually** moves
`Engaged`→`Prospect`, which auto-creates the Opportunity and moves Company→`Opportunity`;
after that the Opportunity Stage drives everything. `Payment Received` makes Contact and
Company `Customer`.

Contact Stage deliberately stays rep-writable: `Engaged`→`Prospect` is a judgement call, not
something a call outcome can trigger reliably, so a human has to make it. This restructure is
**org-wide** — every rep cuts over together on migration night, not a phased split (that split
belongs to the separate "New SMB Outreach Model" work — don't conflate the two). Old
`ProspectStage` values stay live in the dropdown only as a rollback safety margin until the
migration is verified successful, then get retired.

**All business decisions resolved 2026-07-28** (`memory/08-open-decisions.md`).

**Scripts built and parse-verified, nothing run against production**:
`scripts/migration/` — `00-schema.ps1` (declarative mapping, 29 entries,
smoke-tested to cover all 28 live values with a passing negative control) through
`07-verify.ps1`, orchestrated by `run-migration.ps1`. One command, unattended, checkpointed
and idempotent. Nothing writes without `-Execute`; `-Execute` refuses to start without
`-ConfirmManualSteps` and aborts if another LSQ script is running. UI-only prerequisites are
in `scripts/migration/MANUAL_STEPS.md`.

**Next**: rehearsal run (dry, safe in business hours) → manual UI steps → night run.

## Phase 6 — Stage sync automation — **native LSQ automation, spec'd and ready to build**

**Decided 2026-07-28 (Kaustubh): this must be native LSQ automation, not a sync script.**
Researched and confirmed buildable. Build spec: `docs/LSQ_AUTOMATION_SPEC.md`.
Capability audit: `docs/AUTOMATION_CAPABILITIES.md`.

**Constraint discovered 2026-07-31 — automations appear not to fire on API writes.** Kaustubh
built a live automation (Company `Fresh`→`Nurture` when Contact goes `Fresh`→`Engaged`). A bulk
job then moved 17,011 leads `Fresh`→`Engaged` via `Lead/Bulk/UpdateV2` and the Company backlog
moved **5,115 → 5,111 in 19 minutes** — ordinary rep clicking, not a queue draining. So the
automation almost certainly triggers on **UI edits only**. That is fine for its day job, but it
means the call-outcome and Opportunity-creation automations may equally not fire when driven by
an integration, the phone app, or a bulk job — and a non-firing automation looks identical to one
that has not fired *yet*. **Confirm with the LSQ SPOC**, and until then assume every automation
needs a reconciler alongside it (`12`/`13` in `scripts/migration/`). This does not
overturn the native-automation decision; it adds a safety net to it.

Three findings made it possible, after an earlier false negative:
- **`Add Opportunity` is a LEAD automation action** (Type/Enquiry/Owner/Status/Stage
  configurable). It is absent from the *Opportunity* actions page, which is what produced the
  earlier wrong conclusion — it acts on a lead, so it lives under Lead actions.
- **`Update Account` is a Lead automation action.** LSQ's own docs give our exact use case:
  transitioning an account's stage when the associated lead's stage changes.
- **Opportunities are activities on the lead** — verified live on this account
  (`12000 | Opportunity`, `33 | Opportunity Captured` on the lead timeline). So a *Lead*
  automation can react to opportunity changes, and it already has both write actions. The
  feared 3-hop traversal is not needed at all.

**Three automations** spec'd (AUT-1 first-activity, AUT-2 lead-stage-driven, AUT-3
opportunity-driven), with an 11-step test plan and 4 items to confirm on-screen during the
build.

**Revised 2026-07-28 against LSQ's official Automation Feature Guide.** An earlier five-
automation draft had three sharing a `Lead Update` trigger — the guide shows LSQ **refuses to
publish** that shape (*"multiple duplicate automation triggers... could cause an infinite
loop"*), so it would have failed on build day rather than in testing. Merged to three with
Multi If/Else branching. The guide also resolved two open verification items (`If Opportunity
Exists` condition exists; activity automations do trigger on opportunity activities) and
surfaced mechanisms the draft lacked: **conditions must use `Latest Data` not `Triggered
Data`** or guards read stale state and fire anyway; `Run only once per lead`; a
50-triggers-per-lead-per-day auto-terminator; the `Exit` action; and native Failure /
Termination / Usage reports.

**Resolved 2026-07-28 (Kaustubh)**: `Add Opportunity` **can** set Owner dynamically from the
contact owner, and the automation publish limit is not a constraint. Two minor items remain to
confirm on-screen, both with fallbacks.

**No automation API exists** — confirmed by probing 13 candidate endpoints live (all 404;
control call returned 200) and by apidocs having no Automation/Workflow category. The three
automations are a **UI build**, roughly an hour. Recorded in `memory/07-write-capability-matrix.md`.

**Verification is scripted**: `scripts/sync/test-automations-live.ps1 -Execute`
runs the full 9-step test plan against a throwaway account and reports pass/fail per check.
It exists because automations are asynchronous — by eye, "not fired yet" looks identical to
"never will" — and because the three regression guards assert that *nothing* happened, which
is exactly what manual testing skips.

The scripts in `scripts/sync/` remain as the **safety net**, not the mechanism:
- `validate-consistency.ps1` — nightly drift detector, 7 violation classes. **More important
  under native automation, not less** — a paused workflow or an execution cap fails silently.
- `test-sync-rules.ps1` — **46 passing offline tests**; the executable specification of
  intended behaviour that the automation build must agree with.
- `sync-engine.ps1` — not scheduled. Kept for one-off `-FullScan` backfill and as fallback if
  a build-time check fails.
- `report-reactivation.ps1` — Supply Gap / Commercial Mismatch mining.

- `sync-rules.ps1` — **pure** decision logic, every if/else/then in the funnel, no API calls.
- `test-sync-rules.ps1` — **46 offline tests, all passing.** No API needed. The only properly
  testable part of this project; run after any rule edit.
- `sync-engine.ps1` — applies the rules live. Watermark-scoped (~35 records per 15-min cycle
  at the observed change rate); `-FullScan` for nightly reconciliation.
- `validate-consistency.ps1` — nightly drift detector, 7 violation classes.
- `report-reactivation.ps1` — Supply Gap / Commercial Mismatch accounts that convert
  themselves when a celebrity signs or pricing flexes.

**Three API facts verified live 2026-07-28** while building this, all now in `CLAUDE.md`:
timestamps are **UTC** while the account is IST (a local-time watermark matches zero rows
forever — proven: 352 vs 0); `IsPrimaryContact` reads as the string `"1"`/`"0"`, filters only
on `"1"` (`"true"` → HTTP 500), and writes as `"true"`; and there is **no bulk Opportunity
read endpoint** (8 names probed), so opportunity work costs one call per lead.

The `IsPrimaryContact` quirk was a live bug in this repo's own migration code, caught before
it ran — it would have let a second Opportunity attach to a different contact at an account
that already had one.

Also in scope: making the `01. Phone Call/ Follow Up` activity fields **mandatory**
(`Status`, `Connected`/`Not Connected Outcome`, `Next Step`). They all exist today and are all
optional, which is the root cause of the original stage-field overload. UI-only, and must land
**after** the rep briefing. See `docs/STAGE_RESTRUCTURE_PLAN.md` section 8.

## Phase 7 — SOP + rep training — **SOP drafted**

`docs/SOP_PIPELINE.md` written 2026-07-28. Still to do: review it against the *shipped*
system once Phase 5R runs (it currently describes the designed system), then run the
training session for the 18 active reps. Briefing must land Monday morning after the Friday
migration, before reps start working — the migration changes what they see on screen.

## Phase 8 — Account-based rep assignment rollout

The original "New SMB Outreach Model" plan — now landing on a Company object that's
scored (Phase 4), structurally correct (Phase 3), and clean of departed-owner noise
(Phase 2). This is the actual behavior change reps experience day to day.

## Phase 9 — ICP assignment & rep accountability — **running since 2026-08-04**

Contacts carrying `Source = "Kaustubh ICP"` are assigned in blocks to reps, who are expected to
call every one, and to record disposition, stage, disqualification reason and a note for each
connect. `scripts/reports/icp-rep-compliance.ps1` measures actual outreach from the telephony
log and grades the CRM record against it.

Trajectory across the first four days (2026-08-04 → 08-07):

| | 08-04 | 08-05 | 08-06 | 08-07 |
|---|---|---|---|---|
| Assigned | 600 | 971 | 1,320 | 1,714 |
| Reps | 3 | 5 | 10 owners | 10 owners |
| Coverage (called) | 20% | 63% | 71% | 71% |
| Stage-update discipline | — | 55% | 74% | 69% |

Standing problems, all detailed in `memory/11-crm-hygiene-findings.md`:

1. **Notes are structurally impossible** — no Notes API, and the `Notes` field holds imported ICP
   business descriptions. 0 notes captured across every run. **Needs a decision on a destination
   before it can ever be non-zero.**
2. **"Did Not Pick" is used on contacts that demonstrably connected** — 230 of them at the last
   count, 183 where *every* attempt connected. It is the largest value in the funnel.
3. **Disqualification Reason is blank on ~half of all disqualified contacts.**
4. **Hygiene only improves in batch cleanups and degrades whenever real calling happens** —
   which is the argument for Phase 6/7 rather than more reporting.

Next: agree a note destination, lock the Disqualification Reason option list (new values are
appearing faster than existing ones are used correctly), and settle what "Did Not Pick" means
with all reps.

## Phase 10 — Real-time calling pipeline — **LIVE since 2026-08-08 11:51 IST**

Replaces the hand-run reports in `scripts/reports/` with a standing system.
**LSQ webhooks → Apps Script → Supabase → Sheets / Excel.**
Full runbook: **`docs/CALLING_PIPELINE.md`**. What was learned: **`memory/12`**.

First full day: **1,169 dials, 298 connects, 25.5% connect rate, 14 reps.**

```
6 LSQ webhooks  activity 22/21/203  +  field-change on disposition / stage / disq reason
      |  batched per minute, ~2 min latency
      v
Apps Script (appsscript/CallingPipeline.gs)   normalise -> upsert, always returns 200
      |  enrichLeads 10m | flushPending 5m | refreshReports 10m
      v
Supabase Postgres    fact_call / fact_stage_change / fact_field_change / dim_contact + v_*
      |
      +-> Google Sheet (always-on monitor)    +-> Excel PivotTables (docs/EXCEL_DASHBOARD.md)
```

Decisions (Kaustubh, 2026-08-08): webhook-driven; Supabase as the store; Excel as the analysis
surface with Sheets as the monitor; disposition shown as `<no history>` before the cutover
rather than approximated. **The pipeline never writes to LSQ.**

**Three findings set the architecture:**

1. **LSQ has a native Webhooks feature and this repo did not know it.** `memory/07` recorded
   the Webhooks API as "not used" and the automation spec said webhooks needed a hosted
   endpoint — both true of the *Automation* subsystem, not this one. It **fires on
   telephony-created activities**, which gotcha 11 gave good reason to doubt.
2. **The payload is complete** — id, lead, actor, timestamp, status, duration, note blob. No
   callback ⇒ no queue ⇒ no worker. Deleted ~800 lines of an earlier Supabase design.
3. **But a Sheet cannot be the store.** At 1,169 calls/day, Apps Script's read-everything
   refresh stops finishing inside the 6-minute limit at ~50–100k rows — two months. And there
   is no bulk activity read, so unrecorded history is gone for good.

**The recoverability split**, which governs how every number is read:

| Signal | Historical | Forward |
|---|---|---|
| Calls per rep per day, connected | **Exact** (trails) | Exact |
| **Stage at time of call** | **Exact** — 3002 carries Previous/Current + timestamp | Exact |
| **Disposition at time of call** | **Unrecoverable** — lead field, no history kept | **Exact**, via field-change webhooks |

**Built and verified:** 6 Supabase migrations; `CallingPipeline.gs` (ingest, enrichment,
reporting, 6 hygiene flags, pivot); 4 PowerShell tools (webhook management, QC, backfill,
oracle); **57 tests passing against real captured payloads**. `scripts/lib/activity.ps1`
consolidates the per-lead block that was copy-pasted six times, two copies missing retry.

**Gotchas 14–20 in `CLAUDE.md`** all came from this build. The expensive ones: millisecond
timestamps on `ProspectActivityDate_Max` only (a null date reads as an empty day, not an
error); a placeholder defeating its own `coalesce` fallback (980 calls onto one row);
`Webhook.svc` needing `ActivityEvent` at the top level and `Delete` as a **GET**; and
PostgREST demanding identical key sets across a bulk insert.

**Backfill:** 15,972 contacts touched since 1 Aug, **8,297 excluded as Callkaro-only (52%)**,
7,675 to pull over two nights. Checkpointed and resumable.

### 10b — The opportunity funnel and the forecast (2026-08-09)

Extends the pipeline past `Prospect` into the deal, which is where revenue is. Migration
`010`; tabs **Rep Funnel**, **Prospects Daily**, **Deal Board**, **Forecast**, **QC**.

`Fresh → Engaged → Prospect → (opportunity) → Won | Lost`, with `Disqualified` as an exit at
any point. Prospects created is counted from **stage transitions, not current stage** — a
contact promoted Tuesday and disqualified Thursday still counts for Tuesday — and attributed
**actor-first**, so bulk and admin writes appear as their own column instead of inflating a
rep's production.

**The finding that changes the framing.** The forecast gap had been understood as reps not
filling in deal size and close date. It is not: the live Opportunity object has 66 properties
and **four** custom fields — `mx_Custom_1` (name), `mx_Custom_2` (stage), and
`mx_Custom_6`/`mx_Custom_8`, both empty and unnamed. **There is no deal-value field and no
expected-closure-date field. Absent, not blank.** Nobody can fill in a field that does not
exist, so this is an admin task, not a coaching one. The warehouse columns and every forecast
view are already written against them; creating the LSQ fields makes the tab work with no
further code change.

The Forecast tab therefore leads with **forecast coverage** rather than a forecast, and states
plainly which of the two situations it is in. `Est. value we cannot see` is labelled
everywhere as the size of the blind spot, not a prediction.

Also found: **15 of 136 opportunities still sit on the legacy deal stage `Requirement
Gathering`**, a rename the 2026-07-31 restructure specified but never applied to the dropdown
— the same failure mode as the contact-stage drift found the day before. `v_deal_stage_drift`
and QC check 10 now watch it.

**QC is now a tab.** Twelve checks inside the warehouse, each against something that does not
share its arithmetic, rendered with expected vs actual, plus a data-boundaries block stating
what each stream physically cannot know. `FAIL` means a number in the workbook is wrong.

**Ready for what is coming next week:** `fact_call` already carries nullable `disposition`,
`transcript` and `transcript_url` columns, and `v_call_disposition_at_time` already prefers a
real per-call disposition over the 12-hour inference. Adding a nullable column to an
8,000-row table is instant; retrofitting after 200,000 rows, with a re-ingest costing one API
call per lead, is not.

### 10c — Teams, the bundled read, and the deal book loaded (2026-08-09)

Migrations `013`; tabs **Teams** plus a rebuilt **Rep Funnel**. Twelve commits.

**The deal book is fully loaded.** All 1,398 opportunities read through
`GetOpportunityDetails`, 0 failures. Deduped per contact the open book is **49 hot, 91 warm,
979 new, 150 won** — 4% of open deals have progressed past a first conversation, and 888 of
the 979 were created across four days in late July by the backfill and migration rather than
by a rep. That number needed no new field and reframes the pipeline more than deal size does.

**Forecast fields exist and are unused**, correcting an earlier wrong finding of mine: across
all 1,398 deals, Expected Deal Size is filled on **2** and Expected Closure Date on **7**.
Neither survives inspection — one is a test record, the other carries a deal value of `4`.
**Do not make the field mandatory without validation**, or the column fills with 4s.

**`Requirement Gathering` is a real warm stage on the Opportunity** and legacy only on the
Contact. Same string, two objects, opposite meanings; 012 had flagged a healthy warm pipeline
as drift.

**The dashboard died for a day on an Apps Script quota**, not a bug — `enrichLeads` was
spending ~29,200 UrlFetch calls/day, 83% of the project total, and its worst branch ran when
there was nothing to do. Now metered (`ufFetch_`), bundled into one RPC, and enrichment yields
to reporting under pressure. `docs/CALLING_PIPELINE.md` §8 has the full accounting.

**`dim_rep` had been empty since migration 001** — nothing ever populated it. Now filled and
maintained by the book snapshot.

**Still open:**
- **Expected Deal Size / Expected Closure Date need to be made mandatory at In Discussion,
  with validation.** Nothing else blocks the forecast.
- **Actual Deal Size and Actual Closure Date are invisible to `GetOpportunitiesOfLead`** —
  readable only via `GetOpportunityDetails`. Adding them to the grid view did not help.
- **Disposition dropdown drift** — four non-canonical values in use across 73 calls, one of
  them a contact stage.
- **The Unassigned bucket is larger than either team** — Admin 21,341, Shriyanka Gupta 9,235.
- Hygiene backlog: 47 open deals on disqualified contacts (close as Lost, rule confirmed), 84
  Prospects with no deal, 129 duplicate pairs (being fixed by hand).
- Client list awaited, to reconcile 150 Won deals against 190 Customer-stage contacts and
  seed Actual Deal Size for closed business.
- **Notes remain uncaptured** — reports the *what*, not the *why*. EventCode 203 is no longer
  dead (last activity on 806 leads), making its fields mandatory the cheapest route.
- 281 field-change events captured before the handler existed sit unimported in `Unparsed`.
- Lead Stage Change (webhook event 5) cannot be created via API — worked around with a
  field-change webhook on `ProspectStage`.
- Apps Script cannot read request headers, so the receiver uses a query-string secret.
  Obscurity, not a credential; acceptable because the endpoint only writes rows it was handed.

## Phase 11 — All channels, ICP metrics, book saturation — **census done 2026-08-10; ingest built, not yet applied**

Phase 10 measures the phone. This phase widens it to every channel LSQ records, adds the ICP
dimension the warehouse has never had, and answers whether a rep's book is worked out before
more leads are issued. Full plan and decisions: the approved plan file; findings: `memory/13`.

**Decisions (Kaustubh, 2026-08-10):** book saturation is **advisory only** (no gate, no
write-back to LSQ) · backfill scope **held** pending the census pricing below · analysis
surfaces on the **existing Sheet + Excel** · scope is **only activity types LSQ already
records** (no new custom types; LinkedIn and email-sends stay named blind spots).

### 11a — Activity census — **done, read-only**

`scripts/pipeline/09-activity-census.ps1`. Full book (91,033 leads, reconciled 91,033/91,033,
negative control passed) plus two 300-lead trail strata that are never pooled.

- **WhatsApp is the second-largest channel and is invisible to every report.** 60% of contacts
  carry a 201, against 81% for outbound calls. 7,700 leads have it as their *last* activity.
- **It has exactly one actor** across 600 sampled leads (calling has 27), so it is a broadcast
  integration, not rep outreach, and must not be credited to reps.
- **55% of WhatsApp messages that carry a status are `FAILED`.** Nobody is watching this.
- **78.3% of contacts hold at least one non-call channel activity.**
- **No money on activities.** 204/205/206 were the last hope for recoverable deal value: 1
  activity found across 600 leads, 0 with an amount. **Funnel analysis stays count-based.**
- **`ProspectActivity.svc/ActivityTypes.Get` exists** and is where the unattributed
  `data/activity_types_schema.json` came from. 58 types live vs 57 cached.
- **EventCode 209 "Call Disposition" was created 2026-08-06 and is unused.** It carries per-call
  disposition, disqualification category/reason **and a first-class Notes field** — the two
  longest-standing gaps in this CRM. Subscribed in advance of any traffic.
- **EventCode 3001 `LeadAssigned` carries previous and new owner**, on 96% of contacts back to
  Feb 2025. Assignment history is fully recoverable; "fresh *for me*" becomes computable.

**Backfill pricing** (the decision this was run to inform): whole book 91,033 calls / 12 nights ·
workable book 26,302 / 4 · touched since 1 Aug 16,092 / 3 · non-call last activity 16,366 / 3.

### 11b — ICP field readiness — **done, read-only**

`scripts/reports/enumerate-icp-readiness.ps1` — one scan for all 17 candidate fields rather than
seventeen full scans.

- **`mx_Ads` is real**: 31,198 filled, exactly `Yes` (2,059) / `No` (29,139), 99.7% filled on the
  ICP population. **2,059 accounts confirmed running Meta ads** — enough for an ads cut with an
  n>=30 rule across a few dimensions, not many at once.
- **`mx_Category` is the industry dimension to use**: 55 clean values, **100% filled on the ICP
  population**.
- **`mx_Industry_Type` is unusable as a dropdown** — 11,515 stored values against 15 options,
  56,831 leads unfilterable. Bigger than the 61,919-lead incident. Needs a decision, blocks
  nothing.
- Dead on the ICP population: Segment, Company revenue, Selected Product, Qualified Business,
  State, Sub Sector, Marketing Budget, Country. **`mx_Categoey` (the typo field) is empty
  everywhere — safe to retire.**

### 11c — Channel ingest — **migrations applied and webhooks LIVE 2026-08-10 18:13 IST**

Migrations `014` and `015` are applied (all 8 objects verified by independent read; `ref_channel`
holds its 26 seed rows). **14 channel webhooks created, 17 activity subscriptions now live and
ENABLED, zero duplicates** — verified by reading back what LSQ actually assigned, not from the
create responses.

**3001 `LeadAssigned` refused with HTTP 500** while all 14 catalogued types created cleanly. The
3xxx system codes are in the trail but not in the ActivityTypes catalogue, and the webhook API
only accepts catalogued types. `fact_assignment` is therefore trail-derived, which is fine — the
history is already there, on 96% of contacts back to Feb 2025.

**Outstanding and now urgent:** the updated `CallingPipeline.gs` is **not yet deployed**, so the
new webhooks are firing at a receiver that still drops anything that is not 21/22/203. It returns
200, so nothing will be disabled — but every WhatsApp event arriving in the meantime is being
discarded rather than stored.

### 11c (as built) — what the files do

- `supabase/migrations/014_attempt_curve.sql` — attempt-depth hazard curve, disposition
  durability, connect-by-hour. Runs entirely off existing `fact_call`.
- `supabase/migrations/015_channels.sql` — `ref_channel` (seeded from the census, 26 rows),
  `fact_touch`, `v_touch_all`, channel views, QC. `fact_call` is untouched.
- `scripts/pipeline/01-manage-webhooks.ps1 -Action AddChannels` — idempotent; lists first,
  creates only what is missing, reads back what LSQ actually assigned.
- `appsscript/CallingPipeline.gs` — generic channel branch: anything not 21/22/203 lands in
  `fact_touch`, classified in SQL. No new UrlFetch spend.

**To apply** (there is no Supabase CLI and no DB URL here — migrations are pasted into the SQL
editor): run `014` then `015`, then `-Action AddChannels -Url <exec url> -Execute`, then paste
the updated `CallingPipeline.gs`.

### 11d — Assignment history and book saturation — **LIVE 2026-08-11, all QC passing**

Migrations `016` (assignment + saturation), `017` (channel QC fixes), `018` (recency fix) applied.
2,500 contacts' trails loaded: 16,055 touches, 5,412 assignments, 0 failures. **All 9 QC checks
PASS**, each against something that does not share its arithmetic.

**Reps use exactly one channel.** Not one rep has a single non-phone touch. WhatsApp reaches
2,691 contacts and is 100% a `System` broadcast. "Which channel converts better" cannot be asked
yet — there is only one rep channel, and that is the finding.

**Reps are not short of leads.** Of 17,811 contacts, **61 are genuinely worked out** and **1,911
are recoverable** — 1,347 never dialled, 337 dialled once and dropped, 136 stalled after a
conversation, 91 under-worked. Untouched pools concentrate in Mayank Arora (206), Rahul Madaan
(181), Admin (175), adarsh pandey (142), Prakhar Gupta (136).

**Three defects were caught by the QC rather than by anyone noticing a wrong number** — the
argument for having it. EventCode 3011 turned out to be a mirror sharing its activity Id (so the
census double-counted WhatsApp events and the upserts 500'd); opportunity webhooks arrive with no
`ActivityEventName`; and `connected_no_progress` tested stage but not recency, putting 1,888 live
conversations in a bucket labelled neglect. All three are recorded as gotchas 34–36.

**Still open:** 15,167 contacts of the enriched book remain unloaded (one API call each), so
`days_held` and `days_to_first_touch` currently describe ~16% of contacts. The buckets themselves
do not depend on assignment history and are complete.

### 11e — Still to build

`dim_contact_book` (row-level ICP dimension), the ICP funnel and scorecard views,
`fact_assignment` from 3001, and book saturation / book health.

## Phase 11f — The bundle timeout, cut rather than split (2026-08-12)

Migration `031` plus `CallingPipeline.gs` `2026-08-12.1`. The ICP and Disqualified tabs went
blank again. Neither was broken: `icp_bundle` answered in 2.0s with every key full. They were
blank because `channel_bundle` was returning **HTTP 500 statement timeout** and the Apps Script
fetched the ICP bundle from *inside* the channel bundle's try block, so one throw skipped the
other fetch entirely.

**Five of nine key sets in `channel_bundle` were rendered by nothing** — `non_owner`,
`qc_channel`, `qc_saturation`, `qc_movement`, `unmapped` — 4.85s of an 8.62s bundle against an
8s timeout. Enumerated by listing every `B.<key>` in the Apps Script, not assumed. Deleting
them took the bundle to **3.77s**, better than 2x headroom; 027 materialised the ICP base and
028 split the bundle, and both were back over the limit within a day, so a third split would
have bought the same few seconds and a third round trip. The `v_qc_*` views are untouched —
they are still queried directly by the QC logging.

Also fixed: the health check looked for `icp_funnel`/`disq_by_rep` in the channel bundle, which
they left in 028, so it reported ABSENT on every healthy run and blamed the wrong migration.

## Phase 12 — Why leads don't buy: the disqualification analysis (2026-08-13) — **done, read-only**

Full findings: **`memory/14-disqualification-analysis.md`**. Report artifact published; two
workbooks in `data/`.

Answered the standing question behind Phase 9 and 11: 67.6% of the book is Disqualified and 42%
of that says `Not Interested - No Reason Stated` — what is actually going on?

**The reason field is not diagnosis.** 96.7% of disqualifications carry a reason that is a
rename of the legacy `ProspectStage` the contact already held, proven from
`mx_Previous_Contact_Stage`. "98% have a reason" measures the migration, not the sales team.

**Reps are not the problem.** Across all 1,520 contacts a *named rep* disqualified 1–13 Aug
(bulk and admin writes excluded): **4.92 calls** on average beforehand, 92.8% connected first,
88.6% disqualified straight after a connected call and 93.8% within the hour. An earlier
"1.38 calls" figure was wrong — it counted only the warehouse window, not full history.

**200 disqualifying calls read in full** (the one-connected-call, `No Reason Stated`, transcribed
cohort): 48% genuinely produced no obtainable reason, 23.5% should never have been dialled,
11% gave a real commercial reason, and **7% were lost by our own process** — an existing customer
cold-called, a Prospect-stage partner dropped, opt-outs still being dialled, nine who asked for
material and were marked Not Interested anyway. **Price appears 3 times in 200.**

**ICP enrichment bought reachability, not demand** — no industry, city or ads signal separates
buyers anywhere in the book. **Lead quality is a channel problem**: 31% of FB Lead Ads and 48%
of `Inbound Phone call` are marked "not a business", against 0.4% on the manual ICP list.

Six gotchas came out of this and are in `CLAUDE.md` (39–44). The expensive one is **41**: the
first pass analysed 299 calls *to* disqualified contacts as if each were the disqualifying call,
which it was not, and published a conclusion that had to be withdrawn.

**Still open, all business decisions rather than engineering:** qualify the list before it
reaches a rep (biggest lever, sits outside sales); put call history, stage and opt-out status on
the dialler screen; add monthly ad spend as a qualifying field; make disposition + a one-line
note mandatory on a connected call; make Closed-Lost real. **Do not** respond to this by pushing
reps to dial more or disqualify less.

---

## Sub-agent task breakdown

Suggested split for parallelizable work once Phase 3's manual blocker is cleared:

| Agent focus | Phases | Reads first |
|---|---|---|
| Opportunity build-out | 3 | `memory/03`, `memory/07` |
| Company enrichment/dedup scripting | 4 | `memory/02`, `memory/00` (GTM/ICP context) |
| Lead stage migration scripting | 5 | `memory/01`, `memory/06`, `CLAUDE.md` (live-object caution) |
| Automation/rollup research + build | 6 | `memory/03`, `memory/08` |
| SOP + training content | 7 | `memory/06`, `PROJECT_PLAN.md` (needs 3-5 shipped first) |

Every agent: read `CLAUDE.md` in full before writing any script (the API gotchas are not
optional reading — they were each discovered the expensive way).

## Status tracking

Update this file's phase headers (`— done`, `— executing`, `— blocked on X`) as work
lands, rather than keeping status in a separate tracker. This file is the single source
of truth for "what's the state of this project."
