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

## Phase 2 — Departed-owner cleanup — **executing**

20,837 Leads + 10,972 Companies reassigned from 30 departed owners to Admin. Full backup
taken before the write. See `memory/05-departed-owner-reassignment.md` for scope, method,
and how to check completion status (`data/reassignment_log.txt`).

**Why this is Phase 2, not later**: the account-based rep assignment (Phase 6) and the
GTM engineer's ICP tiering both need an accurate picture of who owns what right now. Stale
ownership under departed reps would corrupt both.

## Phase 3 — Activate the Opportunity object

**Blocked on one manual step**: Opportunity Type creation cannot be done via API
(`memory/07-write-capability-matrix.md`) — someone with LSQ admin access needs to create
it via My Profile > Settings > Opportunities > Opportunity Types > Create, using the field
spec in `memory/03-object-model-and-relationships.md` (Status/Stage/Owner defaults +
Product, Celebrity Assigned, Contract Start/End Date, Loss Reason, Renewed From).

Once the Type exists, everything else is scriptable:
- Confirm the `IsPrimaryContact` rule is enforced (only primary-contact Leads get
  Opportunities) — either by process/training or by a validation script that flags
  violations.
- Backfill: for Companies already at `Stage = Opportunity` or `Stage = Customer`, create
  corresponding Opportunity records so the new object isn't starting from zero for deals
  already in motion.

## Phase 4 — Company enrichment & dedup

Runs in parallel with the GTM engineer's ICP/TAL work, not instead of it — enrich the
*existing* 71,467 Company records (Industry, AnnualRevenue, Employees, CIN, Budget) rather
than building a separate dataset. Backfill from the Lead-side fields per the reparenting
map in `memory/02-company-schema-audit.md`. Dedup pass on near-duplicate CompanyName
records — sizing this precisely needs a proper fuzzy-match pass, not yet done.

## Phase 5 — Lead lifecycle stage migration (additive, careful)

Per `memory/06-stage-taxonomy-design.md` and the "Lead object is live" rule in
`CLAUDE.md`:
1. Add `Call Disposition` and `Disqualification Reason` fields alongside the existing
   `ProspectStage` — don't touch the live field yet.
2. Backfill both from historical `ProspectStage` values via the migration mapping.
3. Only after reps are trained (Phase 7) does `ProspectStage` itself get cut over to the
   clean 6-value list.

Resolve the open ambiguities in `memory/08-open-decisions.md` (`Follow Up`,
`Future Prospect`/`Payment Received` placement) before step 3 — not blocking for steps
1-2.

## Phase 6 — Company Stage automation

Make `Stage` (Prospect/Opportunity/Customer) a rollup off the linked Opportunity's status
instead of something set by hand. First validate whether LSQ's native automation can
traverse Opportunity → Lead → Company (untested, see `memory/08-open-decisions.md`) — if
not, fall back to a scheduled script using the update mechanisms already verified in
`scripts/leadsquared/`.

## Phase 7 — SOP + rep training

Deliverable: a rep-facing SOP (not the technical docs in this repo — a "how you work a
pipeline now" doc) plus a training session/rollout for the 18 active reps. Depends on
Phases 3-5 being functionally complete, since the SOP should describe the *shipped*
system, not the design. Lives in `docs/` once written.

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
