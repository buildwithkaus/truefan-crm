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

## The forecast fields exist and are unused (2026-08-09)

**An earlier version of this note said the deal-value and closure-date fields did not exist on
this account. That was wrong, and the error is worth keeping.**

`GetOpportunitiesOfLead` returned `mx_Custom_6` and `mx_Custom_8` present, empty, and with **no
display name in the payload**. I read "unlabelled and empty on every record" as "placeholder
that was never configured" and concluded the fields were absent. They are in fact:

| Schema | Display name | Type |
|---|---|---|
| `mx_Custom_6` | **Expected Deal Size** | Number |
| `mx_Custom_7` | **Actual Deal Size** | Number |
| `mx_Custom_8` | **Expected Closure Date** | DateTime |
| `mx_Custom_9` | **Actual Closure Date** | DateTime |

The Opportunity object has **17 custom fields**, including Loss Reason, Product, Celebrity
Assigned, Contract Start/End and Agreement/Invoice Sent Date. The forecast was designed for and
never adopted.

**The lesson: the API returns schema names only. An unlabelled field in a payload is not a
missing field — the display names live in the form designer, which the API never exposes
(gotcha 23: no field-metadata endpoint answers).** Read the form designer before concluding a
field does not exist. This is the same family as gotcha 2 — a plausible-looking negative that
nobody verified.

### What is actually true, measured across 107 opportunities in all four deal buckets

| Field | Returned by the API | Filled |
|---|---|---|
| Expected Deal Size (`_6`) | yes, on all 107 | **0** |
| Expected Closure Date (`_8`) | yes, on all 107 | **3** (all at In Discussion) |
| Actual Deal Size (`_7`) | **never returned** | cannot be read |
| Actual Closure Date (`_9`) | **never returned** | cannot be read |

Two separate problems, and they need different fixes. The expected fields are a **process gap**
— they are readable and nobody fills them, including on the 150 deals already marked Won. The
actual fields are a **visibility gap** — even once a rep fills them, no report can read them.

Only 4 of the 17 configured fields come back (`_1`, `_2`, `_6`, `_8`, plus `Status`), and the
set is identical on every record, so it is not value-driven. Working hypothesis: the response
mirrors the opportunity grid/list-view configuration. Untested — the test is to add Actual Deal
Size to that view and re-run `07-probe-opportunity-population.ps1`.

**The activity trail is worse still**: EventCode 12000 carries only `mx_Custom_1`, `_2`,
`Status` and `Owner`. Anything forecast-related has to come from the opportunity read, which is
a second API call per lead on top of the trail.

Two smaller findings from the same probe:

- **`GetOpportunitiesOfLead` is a POST**, despite taking every parameter on the query string
  and reading nothing from the body. A GET returns 405. There is **no `/Opportunity/` path
  segment** — inserting one returns a clean 404 on every method, which reads exactly like "the
  endpoint does not exist" rather than "the URL is wrong". Same family as gotcha 2: a
  plausible-looking negative is not evidence.
- **No opportunity field-metadata endpoint exists.** Fourteen candidates probed, all 404
  except `GetOpportunityTypes`, which returns `Fields: null`. The only way to learn the
  opportunity schema is to read a real opportunity.

### Two ingestion bugs found while loading the deal book

**The date gate was above the opportunity branch.** `backfill.ps1` filtered activities to the
reporting window *before* reaching the opportunity handler, whose own comment claimed the
stream was unbounded. Phase 3 created 4,404 opportunities in July; the deal board showed
**254**. It looked plausible and was internally consistent — the worst kind of wrong. After the
fix the same 1,340-contact pass returned **2,382**.

The tell was available and unread: `v_data_boundaries` would have shown the earliest
opportunity landing exactly on the backfill start date. QC check 12 now compares the two
supposedly-unbounded streams against the earliest call and fails if either is clipped.

**EventCode 33 is a fieldless ghost.** It accompanies every 12000 on the same lead with the
*same* `CreatedOn` and **no `ActivityFields` at all** — the same trap as 3002. Storing it as an
opportunity produced a second, blank row per deal: **1,089 ghosts against 1,398 real ones**.
Every ghost sat on a contact that already had a real deal, so removing them was lossless.
Only 12000 is an opportunity.

### The deal book, corrected

**1,398 opportunities across 1,269 contacts. 1,248 Open, 150 Won.**

| Deal stage | Count | Status |
|---|---|---|
| Prospect | 1,107 | Open |
| Payment Received | 150 | Won |
| Requirement Gathering | 91 | Open — **legacy** |
| In Discussion | 50 | Open |

**1,066 of 1,150 Prospect-stage contacts have a deal — 93%.** Worth recording that the buggy
data said 22%, and that "78% of prospects have no opportunity" was one step from being reported
as a business finding. It was an artifact of the date gate. *Check the pipeline before
diagnosing the business.*

`Requirement Gathering` is a **legacy value** that `scripts/lib/schema.ps1`
(`OpportunityStageRenames`) specifies should have become `Prospect`. That rename is a UI edit
on the dropdown and was never applied. Same failure mode as the contact-stage drift found on
2026-08-08 — a migration recorded as complete, with live records still on the old value.
`v_deal_stage_drift` and QC check 10 now watch it.

## Two defects the oracle caught, 2026-08-09

Run against 2026-08-07: **2,249 (LSQ) vs 2,248 (pipeline)**, 13 of 15 reps exact. A 0.04% gap,
and both halves of it turned out to be real bugs rather than noise. This is the whole argument
for the oracle existing — neither would have been visible from inside the pipeline, and both
were *shrinking* over time, so checking a recent day nearly missed them.

### 1. `ProspectActivityName_Max` used as a hard exclusion (the one CLAUDE.md forbids)

`backfill.ps1` skipped every contact whose `ProspectActivityName_Max` was the Callkaro
activity — ~41% of touch volume, so a large budget saving. But that field holds **one** value,
the last activity. A contact a rep called at 10:29 and the AI dialler touched at 15:00 reads
as "AI-dialler-only" and its real calls go with it.

Caught as *Akshita Sharma: LSQ 185, pipeline 183*. Both missing calls were connects — 25s and
31s — on contacts the AI dialler happened to touch later the same day. Neither lead existed in
`dim_contact` at all; the backfill had never considered them.

Sized rather than guessed: a random 150-contact sample of the 8,297 excluded found **1.3% with
an owner-attributed rep call**, extrapolating to ~166 missing calls. Small, but silent and
unbounded — nothing in the filter caps how bad it gets on a day the dialler runs late.

The exclusion is now **off by default**, available as `-SkipAiOnly` and documented as lossy.
Cost of correctness: 8,297 extra trail pulls for the August window, one time.

### 2. The owner-attribution rule was computed and then ignored

`v_call_enriched` has always computed `is_owner_call` (dialler = current owner). **Nothing
downstream used it.** `v_contact_day` and `v_pivot_disposition` both grouped on
`coalesce(contact_owner_name, actor_name)` — bucketing a call by who *owns* the contact
regardless of who *dialled* it. So every call a previous owner made on a since-reassigned lead
was credited to whoever inherited it.

**1,266 of 12,837 outbound calls (9.9%)** were attributed to someone who did not make them,
concentrated in the reassignment window: 493 on 1 August, decaying to 1–3/day by the 7th. That
decay is why the oracle registered it as a single call on Mayank Arora. Against 1 August the
disagreement would have been 493.

Migration `011` routes all three per-rep views through one `call_rep()` function and buckets
non-owner calls as `<inherited: not the owner>` rather than dropping them — totals still
reconcile against `fact_call`, no rep is credited with work they did not do, and the volume
stays visible instead of being silently deleted.

### The cheap diff tool this produced

`scripts/pipeline/06-diff-rep-day.ps1` turns "off by 2" into two activity ids. It pages the
rep's book (a few calls), narrows in memory to leads active since the target day, and only then
spends one call per trail — 340 calls for Akshita instead of the oracle's 4,834.

Its first version scanned the owner's whole book and was killed after 1,400 calls: for a rep
holding 8,935 leads that is more expensive than the whole-team oracle it exists to be cheaper
than. Narrow before you spend.

## The deal book, fully loaded (2026-08-09)

All 1,398 opportunities read through `GetOpportunityDetails`, 0 failures. Deduped to one deal
per contact, the open book is:

| | Deals |
|---|---|
| **Hot** (In Discussion / Agreement Sent / Invoice Sent) | **49** |
| **Warm** (Requirement Gathering) | **91** |
| **New** (Prospect, never progressed) | **979** |
| Open, total | 1,119 |
| Won (Payment Received) | 150 |

**Only 4% of the open book is hot**, and 979 deals have never moved off the stage they were
created at — 888 of those created across four days in late July by the opportunity backfill and
the stage migration, not by a rep working a deal. That is a more useful number than deal size
and it needed no new field.

### Forecast field adoption, measured across all 1,398

`Expected Deal Size` filled on **2**. `Expected Closure Date` on **7**. `Actual Deal Size` on
**0**, including all 150 won deals.

And the two that are filled do not survive a look:

- One is the test record Kaustubh entered on 2026-08-09 (Rs 3,00,000).
- The other carries a deal value of **4**. Not 4 lakh - four. A currency field with no
  validation and no minimum.
- 5 of the 7 close dates are the same date, `2026-08-31`, which reads as a default someone
  clicked through rather than seven separate forecasts.

So the honest count of genuine forecast data in the entire deal book is **one record, entered
today, as a test**. The field-level fix (mandatory at In Discussion) has to come with
validation, or the column fills with 4s.

## The day the dashboard died: an Apps Script quota, not a bug (2026-08-09)

`refreshReports()` failed with `Service invoked too many times for one day: premium urlfetch`
and stayed broken for the rest of the day. Pipeline State, Exceptions and QC were blank; the
earlier tabs looked fine.

**The quota is per PROJECT per day, shared across every trigger, function and webhook
execution — and it fails whatever runs LAST, not whatever spent it.** So the error appears on
innocent code, in a different function from the cause, hours after the spending happened.
That is a genuinely hard signal to read, and it took a `diagnose()` that called the bundle
directly to establish that nothing was actually broken.

`enrichLeads` was 83% of the spend (~29,200/day), and its worst branch was the one that ran
when there was **nothing to do**: with the enrichment backlog clear it re-fetched 200 of
today's contacts every ten minutes, with no staleness test. An idle loop, running flat out.

Fixes, in order of how much they matter:

1. **Meter it.** Every fetch goes through `ufFetch_`; the count is flushed once per execution
   and shown on Meta and in `diagnose()`. Reasoning about the spend is what failed - the
   previous version was also "bounded by construction".
2. **Enrichment yields to reporting** above 8,000 calls/day. The job that can wait is the one
   that gets cut off; the one people are watching survives.
3. **One RPC instead of fourteen REST calls.** `report_bundle()` returns every dataset in a
   single ~230 KB, 3.6s response.
4. **Postgres does the set difference** (`v_calls_awaiting_enrichment`) rather than Apps
   Script pulling both tables in to diff them.

The quota does not refund. Once spent, nothing refreshes until midnight in the script's
timezone, and no code change helps that day.

### Two smaller things the same session turned up

**`dim_rep` had been empty since migration 001.** Nothing ever wrote to it. Most views coalesce
through `dim_contact` and looked fine, so it survived a week; it only surfaced as a raw GUID
appearing where a rep name belonged on the new Rep Funnel. Populated from `dim_contact` (22
owners) and now maintained by the book snapshot, which already sees every owner. **Anything
created empty and filled "later" needs the filling wired into a job that already runs.**

**A count formatted as a date.** `colType_` tested `indexOf('date') >= 0`, which matches
`contacts_upDATEd` - so a count of 14 rendered as 14 January 1900. Sheets was right: 14 is day
14 of the epoch. Suffix matching now, with a value-shape fallback. `'rate'` had the identical
problem. Substring matching on column names is a trap.

## Where the numbers stood at end of session (2026-08-09)

| | |
|---|---|
| Calls, 1-8 Aug | 12,907 dials, 4,500 connects (34.9%) |
| Book | 91,003 contacts; 26,375 workable |
| Deal book | 1,398 deals - 49 hot, 91 warm, 979 new, 150 won |
| Forecast fields filled | Expected Deal Size **2**, Expected Closure Date **7**, Actual **0** |
| Oracle reconciliation, 7 Aug | 2,249 vs 2,249, all 15 reps exact |
| QC | 9 PASS, 1 INFO, 3 GAP, 1 FAIL |

The single FAIL is 3,053 contacts on a non-canonical **contact** stage. The GAPs are forecast
adoption, correctly reported as business gaps rather than pipeline defects.

**Disposition dropdown drift**, found while building the trend tab - four values in use that
are not selectable options, so reps can set them but cannot filter on them:
`Not Interested - No Reason Gauged` 55 · `Requirement Gathering (Warm)` 12 ·
`Not Interested - Wrong Contact` 4 · `Reached Voicemail` 2. The second is a *contact stage*
sitting in the *disposition* field, across five reps.

**The Unassigned bucket is larger than either team**: Admin 21,341 and Shriyanka Gupta 9,235,
35,811 in total, against Team #ONE 31,828 and Team Achievers 23,364.

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
