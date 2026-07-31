# Open decisions — need a human call, not resolvable from data alone

## Resolved by Kaustubh, 2026-07-31 — post-migration

1. **`Fresh` means "nobody has dialled this yet".** The three un-connected outcomes
   (`Didn't Picked`, `RNR`, `Switched Off/Not Reachable`) originally mapped to `Fresh` because no
   human was ever reached. Operationally that buried the bucket reps hunt in under 17,019 leads
   they had already chased. **Decision: move them to `Engaged`**, reason preserved in Call
   Disposition. Executed — 17,011 leads, 0 failures. Accepted trade-off, stated explicitly:
   `Engaged` no longer means "reached a human" (~79% of it is dial attempts).
2. **Call Disposition keeps its six existing option names; the data is matched to them.** The plan
   had renamed two — rejected by Kaustubh, and he was right: the legacy `RNR` value never recorded
   a dial count, and `Follow Up` does not establish a pitch was delivered. Asserting either invents
   precision the source data does not support. `00-schema.ps1` updated so no future run
   reintroduces the qualifiers.
3. **Disqualification Reason: extend the dropdown, do not revert the data.** The 9 legacy options
   cannot express `Not Interested - No Reason Stated` (25,527) or `Invalid Contact Data` (4,797) at
   all, so matching the data to the old list would have destroyed real distinctions. 11 canonical
   L2 values added to the field instead.
4. **Retire the legacy `ProspectStage` values now, brief reps after.** All 25 hold zero records;
   20 retire immediately, 5 wait on the integration owner moving them to Source/Segment. Reps then
   record outcomes in Call Disposition / Disqualification Reason instead of overloading stage.

**Still open from this round:** reps read `Fresh` as *"assigned to me and I haven't called it
yet"*. Reshuffling via bulk reassign means no static stage or field answers that, and there is no
owner-assignment-date field on the Lead. Needs a **reset on reassignment** (clear disposition when
Owner changes) or an owner-stamped field — not a new stage value. Not yet designed.

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
   This supersedes the earlier read-only-rollup design. This restructure is **org-wide**: every
   rep cuts over together on migration night. (The half-account-level/half-contact-level split
   is a separate, earlier initiative — "New SMB Outreach Model" — not this one; don't conflate
   the two.)
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
8. ~~**Does renaming a dropdown value carry existing records' stored values?**~~ **ANSWERED
   2026-07-30 — no, for Company.** LSQ's own rename dialog warns *"Stages of the existing
   Companies will not be updated."* Kaustubh surfaced this before proceeding; the rename was
   **not** used. This invalidated the ~7-hour saving the plan had been built around, so all
   71,483 companies were written individually instead (which ran clean). Worth remembering that
   the earlier evidence for carry-over — the Opportunity Won stage showing
   `"Value":"Payment Recieved","OldValue":"Closed - Won"` — was **misleading**: rename support
   differs per object, and the Opportunity case does not generalise to Company.
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
