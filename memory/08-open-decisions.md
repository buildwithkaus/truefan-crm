# Open decisions — need a human call, not resolvable from data alone

## Phase 5R stage restructure — resolved by Kaustubh, 2026-07-28

Full context: `docs/STAGE_RESTRUCTURE_PLAN.md` section 9.

1. **`Payment Received` makes an account a Customer.** Contact and Company both flip at
   `Payment Received`, not at the later `Customer` opportunity stage. Tranched PIs are
   knowingly deferred — the post-sales half of the lifecycle gets its own pass later.
2. **`Wrong Number` -> Company `Nurture`.** APPROVED. 4,753 qualified accounts stay workable
   with a `Needs Contact Resourcing` flag rather than being buried in Future Prospect.
3. **`Not ICP Fit` suppressed from working views and the TAL.** APPROVED.
4. **Contact Stage stays REP-WRITABLE**, and `Engaged` -> `Prospect` is a **manual rep
   decision**, not a call-outcome trigger — no single outcome reliably means "real deal now".
   This supersedes the earlier read-only-rollup design. Driven by the transition reality:
   for ~1 month half the team works account-level and half continues the legacy process, so
   the contact record is the only control point both halves share.
5. **Nothing is to be changed in production ahead of the migration.** Schemas and scripts are
   prepared, parse-verified and rehearsable; the whole thing runs as one unattended command
   on the night. Built: `scripts/leadsquared/migration/` + `MANUAL_STEPS.md`.

## OPEN — not blocking the migration

6. **What structure holds the payment schedule?** A contract split into tranches has no object
   representing it — today it is reconstructed from `04. Sales Activity` entries (Amount
   Received / Total Amount / Pending Amount) logged by hand per tranche. Needs either a child
   object on Opportunity or a strict logging convention. **Almost certainly where the
   operational sheets live.** Deferred with decision 1, but it is the next thing to design.
7. **`Meeting` activity type has zero custom fields** — no virtual/physical flag, no outcome.
   Client-requested pre-contract meetings are real but structurally unrecorded.
8. **Does renaming a dropdown value carry existing records' stored values?** Not a business
   call — needs a test on a throwaway custom field. Sizes the Company step only (~1.5 hr with
   renames, ~6 hr without); the script writes whatever the rename did not, so it blocks
   nothing. Evidence it is at least *supported*: the live Opportunity Won stage carries
   `"Value":"Payment Recieved","OldValue":"Closed - Won"`.
## Resolved 2026-07-28 — native automation

**Kaustubh: the sync must be native LSQ automation, not a script.** Researched and confirmed
buildable; spec in `docs/LSQ_AUTOMATION_SPEC.md`.

- **`Add Opportunity` is a LEAD automation action**, not an Opportunity one — configurable
  Type/Enquiry/Owner/Status/Stage. Its absence from the *Opportunity* actions page caused an
  earlier false negative in this repo's own analysis.
- **`Update Account` is a Lead automation action**; LSQ's docs give our exact use case.
- **The 3-hop traversal question is moot**: Opportunities are activities on the lead
  (verified live - `12000 | Opportunity`, `33 | Opportunity Captured`), so a Lead automation
  can react to opportunity changes and already has both write actions.

**Spec revised 2026-07-28 against LSQ's official Automation Feature Guide**, which corrected a
build-blocking mistake: an earlier draft had three automations sharing a `Lead Update` trigger,
and LSQ **refuses to publish** that shape (*"multiple duplicate automation triggers... could
cause an infinite loop"*). Merged from five automations to three. The guide also confirmed the
`If Opportunity Exists` condition exists (removing a fallback), and surfaced `Latest Data` vs
`Triggered Data` - guards set to `Triggered Data` read stale state and fire anyway, which is
the easiest correctness bug to introduce here.

**Resolved (Kaustubh, 2026-07-28)**: `Add Opportunity` **can** set Owner dynamically from the
contact owner - auto-created deals land on the right rep, no reassignment needed. And the
automation publish limit is **not a constraint** on our plan.

Two minor items left to confirm on-screen during the build, both with working fallbacks
(`LSQ_AUTOMATION_SPEC.md`): whether `Update Account` is offered on a New-Activity trigger, and
whether it can mail-merge the disqualification reason from the lead.

**There is no automation API** (confirmed 2026-07-28: 13 endpoints probed, all 404, control
call 200). The three automations are a UI build, like the Opportunity Type was. Verification is
scripted though - `scripts/leadsquared/sync/test-automations-live.ps1 -Execute` runs the whole
test plan against a throwaway account. See `07-write-capability-matrix.md`.

## Resolved earlier

All five below were resolved by Kaustubh, 2026-07-27:

- **`mx_Budget` vs `mx_Marketing_Budget_monthly`** both feed the proposed
  `Budget_Company` field. **Resolved: use `mx_Budget`** as the backfill source; ignore
  `mx_Marketing_Budget_monthly` for this purpose. See `02-company-schema-audit.md`.
- **Havishma Haranath vs Havishma H** — two different LSQ OwnerId GUIDs. **Resolved: same
  person, two accounts** (data hygiene duplicate, not two people). See
  `04-active-rep-roster.md` — flagged for a future account-merge pass, not urgent.
- **`Follow Up` stage value** was used ambiguously (sometimes lifecycle stage, sometimes
  call disposition). **Resolved: it's a call disposition** — moves to the new `Call
  Disposition` field in the Phase 5 migration, not the lifecycle-stage list. See
  `06-stage-taxonomy-design.md`.
- **`Future Prospect` and `Payment Received`** in the old `ProspectStage` list. **Resolved:
  both map to a lifecycle stage, not to "Converted to Opportunity."** Which of the 6
  target lifecycle-stage values each one lands on specifically is still an open
  micro-decision for whoever writes the Phase 5 migration-mapping script — flag for a
  quick follow-up confirmation before that script runs, but this no longer blocks Phase 5
  steps 1-2 (adding the new fields, backfilling `Call Disposition` /
  `Disqualification Reason`).
- **897 live-stage leads reassigned to Admin** (`05-departed-owner-reassignment.md`).
  **Resolved: leave them parked under Admin** — standing decision confirmed, no change
  needed ahead of the account-based rollout (Phase 8).
- **Company.Stage as automated rollup** — can LeadSquared's native automation traverse
  Opportunity → Lead → Company to update a Company field, or does this need a scheduled
  API job instead? **Still open** — not a business judgment call, needs validation with
  LeadSquared support or a sandbox test. See `08` reference in `PROJECT_PLAN.md` Phase 6.
- **Company `Industry` backfill (Phase 4)** — Company's `Industry` field is a strict
  dropdown; the Lead-side source (`mx_Industry_Type`) is free text and gets rejected
  outright. Need someone with LSQ UI access to pull the dropdown's valid option list
  (My Account > Settings > Customization > Company > Industry) so a mapping/normalization
  pass can be designed — not resolvable via API alone (no Company field-metadata endpoint
  exists). Discovered 2026-07-27, see `02-company-schema-audit.md`.
- **Company `AnnualRevenue` backfill (Phase 4)** — Company's `AnnualRevenue` expects a
  numeric `Decimal`; the Lead-side source (`mx_Company_revenue`) is bucketed range text
  ("0 to 10 cr", etc.) that the API rejects. Needs a business call on the conversion rule
  (e.g. bucket midpoint, lower bound, upper bound) before this can backfill — not something
  to silently invent. Discovered 2026-07-27, see `02-company-schema-audit.md`.
