# Stage taxonomy — locked design (2026-07-28)

**The full design, migration plan and sync matrix now live in
`docs/STAGE_RESTRUCTURE_PLAN.md`.** This file keeps the summary and the history of how the
design got here.

## What changed on 2026-07-28

Kaustubh locked the three stage models explicitly. They replace the 4-layer sketch this file
previously held (that sketch had a 6-value Lead lifecycle: Fresh Lead / Contacted / Engaged /
Requirement Gathering (Warm) / Hot / Converted to Opportunity — **superseded**, do not use).

- **Contact (Lead)**: Fresh -> Engaged -> Prospect -> Customer, plus Disqualified (+ reason)
- **Company**: Fresh -> Nurture -> Opportunity -> Customer, plus Future Prospect (+ reason)
- **Opportunity**: Prospect -> In Discussion -> Agreement Sent -> Invoice Sent -> Payment
  Received -> Customer, plus Closed - Lost (+ Loss Reason)

Mapped to LSQ's fixed Opportunity Status: Open = {Prospect, In Discussion, Agreement Sent,
Invoice Sent}, Won = {Payment Received, Customer}, Lost = {Closed - Lost}.

## The core architectural rule (revised 2026-07-28 — supersedes the read-only rollup idea)

**The Contact Stage is the object reps drive. Company and Opportunity derive from it.**
Contact Stage stays **rep-writable** — an earlier draft of this design made it read-only and
that was wrong for the transition: for ~1 month **half the reps work at account level and half
continue the legacy contact-by-contact process**, so the contact record is the only surface
both halves share. It has to be the control point.

Three triggers:

1. **First activity of any kind** (automatic, guarded to fire only from `Fresh`):
   Contact `Fresh` -> `Engaged`, Company `Fresh` -> `Nurture`. The guard matters — a later
   activity must never drag a `Prospect` back to `Engaged`.
2. **`Engaged` -> `Prospect`: a MANUAL rep decision.** Deliberately not tied to a call
   outcome — no single outcome value reliably means "real deal now", so forcing one would
   either miss deals or manufacture them. That manual move then auto-fires: flag
   `IsPrimaryContact`, create the Opportunity at stage `Prospect`, move Company `Nurture` ->
   `Opportunity`.
3. **Opportunity progression** (rep-driven): Contact and Company follow the Opportunity Stage.

**`Payment Received` makes Contact and Company `Customer`** (Kaustubh, 2026-07-28). Tranched
PIs are knowingly out of scope for now; the post-sales half of the opportunity lifecycle gets
a separate pass. `Payment Received` and `Customer` are both Won and both drive Contact/Company
to `Customer`.

Old `ProspectStage` values stay live in the dropdown alongside the 5 new ones for the whole
transition month. Nothing is deleted until everyone has moved across.

Why the root cause is still fixed even with the field writable: `ProspectStage` degenerated
into 28 mixed-concept values because it was the only place to record *anything*. Call outcome
and disqualification reason now have their own fields, so the stage field has one job left.

## Migration mapping headline

Full 26-value table in `docs/STAGE_RESTRUCTURE_PLAN.md` section 4. Key logic:

- Un-connected call outcomes (RNR, Didn't Picked, Switched Off) -> Contact stays **Fresh**,
  reason moves to `mx_Call_Disposition`. **17,019 leads (19.6% of the database)** were sitting
  in what looked like a terminal state but was really an un-retried dial.
- Reached-a-human outcomes (Call me Later, Follow Up) -> **Engaged** / Company **Nurture**.
- Requirement Gathering (Warm) and Conversation In Progress (Hot) -> **Prospect** + an
  Opportunity gets created (Hot starts at `In Discussion`, Warm at `Prospect`).
- Every negative value -> single **Disqualified** state, old value preserved as the reason.
- Channel/segment tags (SaaS, FB Lead - Website, Retargeted*, ReQualified By WhatsApp) were
  never stages -> move to Source/Segment attributes, lifecycle stage inferred from whether
  the lead has a Connected phone-call activity.

## Disqualification reason — two levels

L1 category drives behaviour (does the account come back?), L2 preserves existing detail.
Categories: Not ICP Fit (never revisit, suppressed from TAL), No Requirement, Commercial
Mismatch, Supply Gap, Unreachable / Bad Data, Not Interested.

`Supply Gap` + `Commercial Mismatch` are the standing re-activation report — those accounts
convert themselves when a celebrity signs or pricing flexes, with zero new prospecting.

## Two deliberate deviations from the literal instruction — awaiting sign-off

1. **`Wrong Number` -> Company `Nurture`, not `Future Prospect`.** Its own definition says
   "qualified business but contact number is not correct" — the account is fine, only the
   phone number is wrong. Sending 4,760 qualified accounts to Future Prospect buries them.
2. **`Not ICP Fit` suppressed from working views.** The instruction was that all disqualified
   contacts send their company to Future Prospect. Implemented as asked, but the L1 category
   gates visibility so the bucket does not become a junk drawer reps learn to ignore.

## Live distribution under the new model (2026-07-28, all 86,628 leads)

| New Contact Stage | Leads | % |
|---|---|---|
| Fresh | 18,844 | 21.8% |
| Engaged | 4,093 | 4.7% |
| **Prospect** | **832** | **1.0%** |
| **Customer** | **193** | **0.2%** |
| Disqualified | 62,089 | 71.7% |
| to infer (SaaS / FB Lead) | 577 | 0.7% |

**71.7% of the database is disqualified**, and `Invalid/ Junk` ("No business") is the
second-largest bucket in the entire CRM at 17,340 leads (20%) — a lead-sourcing quality
problem no stage restructure can fix. Live pipeline is 832 Prospects and 193 Customers.

Pipeline is also heavily concentrated: 6 of 18 reps hold 81% of all Prospects. Admin holds
14,538 parked leads including **67 Customers with no active owner**. Per-rep breakdown in
`docs/STAGE_RESTRUCTURE_PLAN.md` section 4.

## Prior state (kept for history)

Phase 5 steps 1-2 executed 2026-07-27: `mx_Call_Disposition` and `mx_Disqualification_Reason`
created and backfilled for 35,496 leads. Those fields are reused by this design, not replaced.

**Known gap in that run**: it probed `Invalid/Junk` and `Just Enquiring No Intent`, got 0 rows
for both, and believed it. The real strings are `Invalid/ Junk` (space) and
`Just Enquiring, No Intent` (comma) — **20,076 leads were silently skipped**, plus 104 on
three undocumented values. Folded into the 5R night run as step 10. Full detail:
`memory/01-lead-schema-audit.md`.

`Follow Up` was resolved as a call disposition (not a lifecycle stage). `Payment Received`
and `Future Prospect` were resolved as lifecycle stages rather than "Converted to
Opportunity" — under the new model `Payment Received` -> Contact **Customer**, and
`Future Prospect` -> Contact **Disqualified** (reason: No Current Requirement / Timing) with
Company -> **Future Prospect**.
