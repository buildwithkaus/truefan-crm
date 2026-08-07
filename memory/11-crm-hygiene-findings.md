# 11 — CRM hygiene findings

*Written 2026-08-08 from eleven full runs of `scripts/reports/icp-rep-compliance.ps1` between
2026-08-04 and 2026-08-07. These are the findings that repeated across every run, not one-day
observations.*

## 1. Rep notes have nowhere to go — 0 captured, ever

**This is a system gap, not a rep-discipline problem, and no amount of coaching will move it.**

Probed 2026-08-05: `LeadManagement.svc/Lead.Notes.Get`, `Leads.GetNotes`, `Note.Get`,
`ProspectNote.svc/Retrieve`, `Lead.Note.Get` — **all 404. There is no Notes API on this account.**

The three places a note could physically land:

| Location | State |
|---|---|
| Lead field `Notes` (Text) | **Occupied.** 100% populated with imported ICP business descriptions ("AR-enabled creative learning kits for children", "Furniture and Interior Design Services"). A rep writing here destroys the ICP enrichment. |
| `CallNotes` inside the call activity's `ActivityEvent_Note` blob | **The correct target.** Empty on every call examined — 0 of 455, then 0 of 1,242. |
| Activity `EventCode 203` — "01. Phone Call/ Follow Up" | Exists, has a `Status` field and custom fields. **Unused since November 2025.** |

`ActivityEvent_Note` is a `{=}` / `{next}` delimited key-value string, **not JSON**:

```
Caller{=}Abhishek Tripathi{next}UserId{=}...{next}Duration{=}501{next}Status{=}Answered{next}CallNotes{=}{next}ResourceURL{=}...
```

**Decision needed:** pick a destination (most likely making EventCode 203 the rep-facing form, per
`docs/STAGE_RESTRUCTURE_PLAN.md` section 8, which already proposes making its fields mandatory)
before this metric can ever be non-zero.

## 2. "Did Not Pick" is applied to calls that connected

The single largest data-quality problem in the funnel, and it grows linearly with volume.

| Run | `Did Not Pick` total | On contacts that connected | …where **every** attempt connected |
|---|---|---|---|
| 2026-08-05 19:17 | 321 | 85 | 74 |
| 2026-08-06 18:29 | 593 | 190 | 149 |
| 2026-08-07 18:12 | 693 | 230 | 183 |

"Every attempt connected" is the strict test: the contact has no unconnected call that could
justify the label. The telephony log flatly contradicts the field.

Two mechanisms, both observed:

- **Default-value clearing.** It is the value reps reach for to empty the field.
- **Batch cleanup.** On 2026-08-05 Ashutosh reconciled 80 records in 28 minutes; `Did Not Pick`
  jumped 321 → 449 team-wide and his own contradicting count went 12 → 47. The backlog was
  cleared by stamping the label on contacts he had demonstrably spoken to, and moving them to
  Engaged.

**This is worse than leaving the field blank.** A blank reads as "not filled in"; `Did Not Pick`
on a 90-second conversation reads as a real outcome and flows into funnel reporting as one.

**Action:** this needs a definition conversation with all reps, not a data fix. Whatever they
think it means, they agree on it and it is not "nobody answered."

## 3. Disqualification Reason is blank on roughly half of disqualifications

78 of 175 blank at the last run (45%), and it has been between 45% and 57% every single run. It
got *worse* as volume rose — new disqualifications added blanks faster than reasons.

This is the one gap that **permanently destroys information**: an uncalled contact can be called
later, but a contact disqualified for an unrecorded reason cannot have that reason re-derived.

Concentrated by rep rather than uniform — Rishi (27) and Kartikey (17) hold over half between
them, while otherwise showing 94% and 96% stage discipline. It is a specific coachable habit,
not general carelessness.

## 4. The Disqualification Reason option list is fragmenting

New values keep appearing faster than the existing ones get used correctly. Observed entering the
data during this programme alone:

- `SaaS/ Enterprise` (2026-08-06) — reads as a *segment*, not a reason. Probably the wrong list.
- `Went Dark After First Conversation` (2026-08-07)
- `Invalid / Not a Business` — the exact string flagged in gotcha 10 as **stored but not
  selectable**, so those records are invisible to a UI filter.

Call Disposition is fragmenting the same way: `Reached Voicemail`, `Requirement Gathering (Warm)`,
`RNR`, `Not Interested - No Reason Gauged` all appeared mid-programme, and
`Call me Later` / `Call Me Later` exist as **two distinct stored strings** differing only in case
— a UI filter offers one and silently hides the other.

**Action:** lock the option lists, then run `scripts/reports/verify-dropdown-coverage.ps1` after
any write. See gotcha 10 — verifying a value is *correct* is not verifying it is *selectable*.

## 5. Hygiene improves only in batch cleanups and degrades during real calling

The most important structural finding, visible only because the report ran repeatedly:

```
2026-08-05 19:17   discipline 80%   (after Ashutosh's 28-min cleanup)
2026-08-06 11:41   discipline 93%   (after Subham's cleanup - zero calls placed that hour)
2026-08-06 18:29   discipline 78%   (after a 444-contact calling day)
2026-08-07 11:38   discipline 74%
2026-08-07 18:12   discipline 69%   (after a 230-contact calling day)
```

Every large improvement came from a rep clearing a backlog in a batch, **not** from updating
records as they worked. Every decline came from actual calling. A clean-looking discipline number
therefore says "someone just did a cleanup pass", not "the team works tidily".

Two consequences:

1. **Always read the discipline number alongside the contradiction count.** During the 80% → 93%
   improvement, `Did Not Pick`-despite-connecting barely moved — the cleanup was re-staging, not
   dispositioning.
2. **This is the argument for Phase 6/7** (native automation + mandatory activity fields) over
   more reporting. Reporting catches the gap after the fact; making the fields mandatory at the
   point of logging a call prevents it.

Related: `[[09-icp-assignment-programme]]`, `[[10-rep-activity-measurement]]`,
`[[lsq-stores-values-not-in-the-dropdown]]`.
