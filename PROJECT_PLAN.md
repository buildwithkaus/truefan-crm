# Project Plan — TrueFan CRM Pipeline & Funnel Fix

Status as of 2026-08-08. Read `CLAUDE.md` first for orientation and the hard rules, and
`docs/LSQ_API_GOTCHAS.md` for the API failure modes that apply to every phase below.

**Where the project actually is:** the data-model work (Phases 1-5R) is done and reconciled.
The live work is now Phase 9 — running the ICP assignment programme and holding reps to
recording what they do. Phases 6 (automation) and 7 (training) remain open and are what
would make Phase 9's findings self-correcting rather than something a report has to catch.

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
6-value lifecycle sketch with the locked 5-value Contact model.

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
