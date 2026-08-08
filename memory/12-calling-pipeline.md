# 12 — Calling pipeline: what was learned building it

*Written 2026-08-08, the day it was built and went live. Everything here was established
against the live account, not inferred. Architecture and runbook:
`docs/CALLING_PIPELINE.md`.*

## The finding that set the architecture

**LeadSquared has a native Webhooks feature, and this repo did not know it existed.**
`memory/07` recorded the Webhooks API as "not used in this project" and
`LSQ_AUTOMATION_SPEC.md` said webhooks needed "a hosted endpoint which this project does not
have". Both were written about the *Automation* subsystem. Native Webhooks
(My Account > Settings > API and Webhooks) are separate — and critically, **they fire on
telephony-created activities**, which gotcha 11 gave good reason to doubt.

The payload carries the **entire** activity — id, lead, actor, timestamp, status, duration,
note blob. That single fact removed a queue, a worker, four edge functions and ~800 lines: if
nothing has to be fetched back, nothing has to be throttled.

**Generalisable lesson:** an earlier conclusion recorded in `memory/` can be true about the
thing that was tested and wrong about the thing you now need. Re-probe before building around
a documented "no".

## Why a database, when a Sheet was already working

Sheets was the first design and it shipped. It broke on volume, predictably:

- Measured **1,169 dials / 298 connects / 14 reps** on the first full day.
- Apps Script rebuilds reports by reading *every* row each cycle, so a Sheet-backed store
  stops finishing inside the 6-minute execution limit at roughly 50–100k rows — about two
  months at this rate.
- History cannot be re-derived: there is no bulk activity read on this account, so anything
  not recorded when it happened is permanently gone.

Supabase is used as **nothing more than Postgres with a REST API**. No edge functions, no
queue, no cron. Apps Script posts to PostgREST directly.

## What is and is not historically recoverable

The single most important thing to understand before quoting any number:

| Signal | Backfillable? |
|---|---|
| Calls per rep per day, connected vs not | **Exact** — from activity trails |
| **Stage at time of call** | **Exact** — `EventCode 3002` carries PreviousStage/CurrentStage + timestamp, so the timeline replays |
| **Call disposition at time of call** | **Unrecoverable before 2026-08-08** |

`mx_Call_Disposition` is a Lead field holding only its *current* value. LSQ keeps no history
and no activity records the change. Decision (Kaustubh): show `<no history>` rather than
substituting today's value — right for a contact called once, quietly wrong for every
repeatedly-worked one, and a number nobody can tell is approximate gets quoted as fact.

Fixed forward by three **Lead Field Value Change** webhooks (`mx_Call_Disposition`,
`ProspectStage`, `mx_Disqualification_Reason`). Their payload carries **two complete lead
snapshots** — `Before` and `After` — so the normaliser diffs them and emits one row per field
that actually moved.

## Cost model

One API call per contact touched; there is still no bulk activity read.

- 15,972 contacts touched since 1 Aug
- **8,297 excluded as Callkaro-only — 52% of all lead-touch volume**
- 7,675 to pull, two nights at a 4,000-call ceiling against the 10,000/day cap

Excluding EventCode 208 is the single largest saving available on the API budget, and it
costs nothing: it is a background dialler, not a person.

## Bugs worth remembering

Every one of these was silent — none produced an error at the point of failure.

1. **Millisecond timestamps.** `ProspectActivityDate_Max` is `2026-08-08 07:38:00.000`. A
   parser without a `.fff` format returns null, callers skip every row, and the output looks
   like *an empty day rather than a fault*. It made a QC script report "0 calls today"
   against an account doing 418. Note `CreatedOn` on an activity has **no** milliseconds —
   the format varies by field, so parse defensively.
2. **A placeholder defeating its own fallback.** `coalesce(owner_name, '<unenriched>')`
   followed downstream by `coalesce(contact_owner_name, actor_name)` — coalesce stops at the
   first non-null, and the placeholder is not null, so `actor_name` was never reached. All
   980 calls collapsed onto one row. **A substituted placeholder is only safe in the LAST
   position of a coalesce chain.**
3. **`$pid` is a read-only PowerShell automatic variable** (the process id). Assigning it
   throws `SessionStateUnauthorizedAccessException` mid-run. Same family: `$host`, `$error`,
   `$input`, `$args`, `$matches`.
4. **PostgREST `PGRST102: All object keys must match`.** A bulk insert requires every object
   in the array to carry an identical key set, and PowerShell's `ConvertTo-Json` emits
   whatever each hashtable happens to hold. Fixed structurally: rows are projected through a
   fixed per-table schema before serialising, rather than trusting each construction site.
5. **`@()` on a PostgREST/`Invoke-RestMethod` result.** `@($null)` counts as 1, and a nested
   array counts as 1. Both made an empty or full result read as "one row" — this produced a
   false "endpoint returns zero rows" verdict about `Leads.GetById`, which works perfectly.
   Use `Invoke-WebRequest | ConvertFrom-Json` and count defensively.

## Measurement bias to be aware of

`scripts/pipeline/02-qc-today.ps1` scopes to contacts whose **last** activity is a call, so it
matches what the LSQ UI filter shows. That makes it comparable to what a human sees on screen,
but it is a **floor, not the truth**: a rep calls a lead at 10:00, Callkaro touches it at
15:00, and the lead leaves scope. It reported 418 for a day the pipeline recorded 980+, and
**the pipeline was right**.

When a QC number disagrees with the pipeline, check the QC scope before assuming the pipeline
is wrong.

## Still open

- **Notes remain uncaptured** — `CallNotes` empty on every payload, confirming
  `[[11-crm-hygiene-findings]]`. The pipeline reports the *what*, not the *why*, until a
  destination is chosen. EventCode 203 is no longer dead (last activity on 806 leads), which
  makes making its fields mandatory the cheapest route.
- 281 field-change events captured before the handler existed sit unimported in the Unparsed
  tab.
- Lead Stage Change (webhook event 5) cannot be created via the API — eleven body shapes
  rejected, including a literal `{}`. Worked around with a field-change webhook.

Related: `[[10-rep-activity-measurement]]`, `[[11-crm-hygiene-findings]]`,
`[[09-icp-assignment-programme]]`.
