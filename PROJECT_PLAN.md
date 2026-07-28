# Project Plan — TrueFan CRM Pipeline & Funnel Fix

Status as of 2026-07-27. Read `CLAUDE.md` first for orientation and the API gotchas that
apply to every phase below.

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

## Phase 5R — Stage restructure across all three objects — **designed, blocked on 3 sign-offs**

Design locked 2026-07-28 by Kaustubh. **Full plan: `docs/STAGE_RESTRUCTURE_PLAN.md`.
Rep-facing SOP: `docs/SOP_PIPELINE.md`.** Supersedes the 4-layer sketch previously in
`memory/06-stage-taxonomy-design.md`.

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

Contact Stage deliberately stays rep-writable: for ~1 month **half the team works at account
level and half continues the legacy process**, so the contact record is the only surface both
halves share. Old `ProspectStage` values stay live in the dropdown through the transition —
nothing is deleted until everyone has moved across.

**All business decisions resolved 2026-07-28** (`memory/08-open-decisions.md`).

**Scripts built and parse-verified, nothing run against production**:
`scripts/leadsquared/migration/` — `00-schema.ps1` (declarative mapping, 29 entries,
smoke-tested to cover all 28 live values with a passing negative control) through
`07-verify.ps1`, orchestrated by `run-migration.ps1`. One command, unattended, checkpointed
and idempotent. Nothing writes without `-Execute`; `-Execute` refuses to start without
`-ConfirmManualSteps` and aborts if another LSQ script is running. UI-only prerequisites are
in `scripts/leadsquared/migration/MANUAL_STEPS.md`.

**Next**: rehearsal run (dry, safe in business hours) → manual UI steps → night run.

## Phase 6 — Stage sync automation — **native LSQ automation, spec'd and ready to build**

**Decided 2026-07-28 (Kaustubh): this must be native LSQ automation, not a sync script.**
Researched and confirmed buildable. Build spec: `docs/LSQ_AUTOMATION_SPEC.md`.
Capability audit: `docs/AUTOMATION_CAPABILITIES.md`.

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

**Verification is scripted**: `scripts/leadsquared/sync/test-automations-live.ps1 -Execute`
runs the full 9-step test plan against a throwaway account and reports pass/fail per check.
It exists because automations are asynchronous — by eye, "not fired yet" looks identical to
"never will" — and because the three regression guards assert that *nothing* happened, which
is exactly what manual testing skips.

The scripts in `scripts/leadsquared/sync/` remain as the **safety net**, not the mechanism:
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
