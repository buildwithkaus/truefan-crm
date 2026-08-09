# Real-time calling activity pipeline

Built 2026-08-08. **LeadSquared webhooks → Google Apps Script → Supabase → Sheets / Excel.**

Reps are told that every call carries a logged Call Disposition, a Contact Stage change, and
(for connects) a note, plus a Disqualification Reason when disqualifying. This measures
whether that actually happens, per rep, per day, from the telephony log rather than from what
reps typed.

Live since 2026-08-08 11:51 IST. First full day: **1,169 dials, 298 connects, 14 reps.**

---

## 1. Architecture

```
  LeadSquared
      |  6 webhooks (My Account > Settings > API and Webhooks)
      |    activity  : Outbound (22) / Inbound (21) / 01. Phone Call-Follow Up (203)
      |    field-chg : mx_Call_Disposition / ProspectStage / mx_Disqualification_Reason
      |  batched per minute, ~2 min latency
      v
  Apps Script web app  (appsscript/CallingPipeline.gs)
      |  doPost -> normalise -> upsert to Supabase. Always returns 200.
      |  enrichLeads   10 min : fetch owner/company/stage for unknown leads
      |  flushPending   5 min : retry anything Supabase refused
      |  refreshReports 10 min: paint the Sheet tabs from SQL views
      v
  Supabase Postgres  (supabase/migrations/)
      fact_call, fact_call_outcome, fact_stage_change, fact_field_change, dim_contact, dim_rep
      + v_* views: all report logic lives here, nothing aggregates in Apps Script
      |
      +--> Google Sheet   always-on monitor, refreshes with nothing open
      +--> Excel/OneDrive analysis surface, native PivotTables (docs/EXCEL_DASHBOARD.md)
      +--- backfill.ps1   one-off history load from activity trails
```

**Supabase is used as nothing more than "Postgres with a REST API"** — no edge functions, no
queue, no cron. The webhook payload carries the whole activity, so there is nothing to fetch
back and nothing to throttle.

---

## 2. Why this shape

Three findings, each of which killed a more complicated design:

**The webhook payload is complete.** Captured live: activity id, lead id, who dialled, when,
status, duration and the note blob. So recording a call costs zero API calls — no callback,
no queue, no worker. An earlier build had all three on the assumption the webhook carried
only an identifier.

**It fires on telephony-created activities.** This was the load-bearing unknown — gotcha 11
records that LSQ *automations* do not fire on API/bulk writes, and EventCode 22 rows are
written by the telephony integration. Native Webhooks are a different subsystem and do fire,
proven with real handset calls.

**But a Sheet cannot be the store.** Measured 418 calls in a partial day, 1,169 in a full one.
Apps Script rebuilds reports by reading every row each cycle, so a Sheet-backed store stops
finishing inside the 6-minute limit at roughly 50–100k rows — about two months. And the LSQ
API cannot re-derive history later: there is no bulk activity read, so anything not recorded
is gone.

---

## 3. What is and is not recoverable

This distinction governs how every number should be read.

| Signal | Historical (before 2026-08-08) | Going forward |
|---|---|---|
| Calls, per rep, per day | **Exact** — from activity trails | Exact |
| Connected vs not | **Exact** — duration > 0 | Exact |
| **Stage at time of call** | **Exact** — `EventCode 3002` records each transition with a timestamp; the backfill replays them | Exact, via the ProspectStage field-change webhook |
| **Call disposition at time of call** | **Unrecoverable** | **Exact**, via the field-change webhook |
| Rep notes | Never captured | Still not captured — see §7 |

`mx_Call_Disposition` is a lead field holding only its *current* value. LeadSquared keeps no
history and no activity records the change, so for any call before the field-change webhooks
went live the disposition that applied at the time is genuinely gone. The pivot shows
`<no history>` rather than substituting today's value, which would be right for a contact
called once and quietly wrong for every repeatedly-worked one.

The field-change payload turned out to carry **two complete lead snapshots**:

```json
{"Before":{"ProspectID":"…","ProspectStage":"Fresh","mx_Call_Disposition":null,"ModifiedOn":"…"},
 "After": {"ProspectID":"…","ProspectStage":"Engaged", …}}
```

so `normalizeFieldChange_` diffs them and emits one row per field that actually moved.

---

## 4. Setup

### Supabase
```
supabase db push          # or paste migrations 001-006 into the SQL editor, in order
```

### Apps Script
Paste `appsscript/CallingPipeline.gs` **verbatim** — every `cfg_('NAME')` is a lookup key,
not a placeholder for a value. Script Properties:

| Property | Value |
|---|---|
| `LSQ_API_HOST` | `https://api-in21.leadsquared.com/v2` |
| `LSQ_ACCESS_KEY` / `LSQ_SECRET_KEY` | from `config/.env` |
| `SUPABASE_URL` | `https://<ref>.supabase.co` |
| `SUPABASE_SERVICE_KEY` | service role key |
| `WEBHOOK_SECRET` | optional, matched against `?secret=` |

Then `setUp()` (installs the three triggers), then **Deploy → Manage deployments → Edit →
New version**. Saving alone does not update the live URL.

Run `diagnose()` to confirm: it lists the properties that are set, masks the key so a
trailing space is visible, tests Supabase read and write and the LSQ call, and warns if the
triggers are missing.

### Webhooks
```powershell
pwsh ./scripts/pipeline/01-manage-webhooks.ps1 -Action Create -Url <exec-url> -Execute
pwsh ./scripts/pipeline/01-manage-webhooks.ps1 -Action List      # verify by re-fetch
```

### Backfill
```powershell
pwsh ./scripts/pipeline/backfill.ps1 -FromDate 2026-08-01 -WhatIf   # sizes it
pwsh ./scripts/pipeline/backfill.ps1 -FromDate 2026-08-01
```
Checkpointed and resumable; re-run until it reports `remaining: 0`. Run it outside
09:00–20:00 IST so it does not compete with live rep traffic for the account-wide rate limit.

Sizing measured 2026-08-08: 15,972 contacts touched since 1 Aug, **8,297 excluded as
Callkaro-only (52%)**, 7,675 to pull, two nights at a 4,000-call ceiling.

---

## 5. Sheet tabs

Tabs are ordered and colour-coded on every refresh by `orderTabs_()`: blue = calling
activity, green = the book and the funnel, red = things to fix, amber = QC, grey = plumbing.

| Tab | Contents |
|---|---|
| **Dashboard** | KPI strip + the pivot: rows rep × stage-at-call, columns disposition, cells calls |
| **Rep Day** | Per rep per day, 7 days |
| **Daily Trend** | Whole-team totals by day — the month view |
| **Pipeline State** | What each rep *holds*, from the daily book snapshot |
| **Rep Funnel** | Book → Engaged → Prospect → Opportunity → Won/Lost, one row per rep |
| **Prospects Daily** | Matrix: days down, reps across. The production number |
| **Stage Movement** | Every stage transition; calls measure effort, this measures progress |
| **Deal Board** | Per-rep deal book, plus open deals by stage |
| **Forecast** | Every open deal — value, close date, staleness — and how much of it is forecastable |
| **Exceptions** | The hygiene worklist, one row per violation |
| **QC** | Every check, expected vs actual, plus what the data cannot know |
| **Meta** | Health. Turns red when nothing has ingested recently |
| **Pending** | Rows parked because Supabase was unreachable; retried every 5 min |
| **Unparsed** | Payload shapes the parser did not recognise |

`refreshReports()` wraps each tab individually. One failing view — a migration not yet run, a
renamed column — cannot take the whole refresh down and silently leave every other tab stale;
the failure is listed on **Meta** under "Tabs that failed to refresh".

`Pending` and `Unparsed` must normally be empty. `Unparsed` earned its keep on day one — it
captured 281 field-change payloads whose shape was unknown, which is how §3 got built.

Pivot columns are generated **from the data**, not hardcoded: disposition values fragment on
this account faster than they get used correctly, so a fixed column list would silently drop
new ones. Non-canonical values are appended after the canonical six and marked `*` — those
are exactly the values reps cannot filter on in LSQ.

### Hygiene flags

| Flag | Sev | Rule |
|---|---|---|
| `CALLED_STILL_FRESH` | 1 | Called, still at `Fresh` |
| `DISQUALIFIED_NO_REASON` | 1 | The only gap that **permanently destroys information** |
| `DISPOSITION_CONTRADICTS_TELEPHONY` | 1 | Says nobody was reached, but every logged call connected |
| `CONNECTED_NO_DISPOSITION` | 2 | Connected, disposition blank |
| `NO_STAGE_UPDATE_AFTER_CALL` | 2 | No stage change at or after the last call |
| `NON_CANONICAL_VALUE` | 2 | Stored value is not a selectable dropdown option |

### The opportunity funnel

The contact journey is **Fresh → Engaged → Prospect → (opportunity) → Won | Lost**, with
**Disqualified** available as an exit at any point. Reaching `Prospect` is what creates an
opportunity, and an opportunity carries a status of `Open`, `Won` or `Lost` plus a finer deal
stage.

Opportunities attach to a **Lead, not a Company**, and only the contact flagged
`IsPrimaryContact` may own one. A Prospect-stage contact with no opportunity is therefore
either a genuine CRM gap or a non-primary contact at an account that already has a deal —
`Rep Funnel`'s *Prospect > Opp %* column is where that shows up.

**Prospects created is counted from stage transitions, not from current stage.** A contact
promoted on Tuesday and disqualified on Thursday still counts for Tuesday; reading current
stage instead would delete a rep's work retroactively every time a deal went bad. Re-entries
(a contact that had already been a Prospect) are counted but broken out separately — they are
recovered pipeline, not new pipeline.

**Attribution is actor-first**, unlike call attribution. A rep promotes their own contacts, so
actor and owner are normally the same person; they diverge only on admin edits, bulk
operations and integration writes, which is precisely the activity that should not land in a
rep's production count. Those appear as their own column instead.

### The forecast, and why it is empty

`Forecast` lists every open deal with its value, expected close date, days open and days since
last call. The headline of the tab is not a forecast — it is *forecast coverage*, the share of
open deals carrying both fields.

**Today that share is zero, and the fields exist.** Measured 2026-08-09 across 107 real
opportunities sampled from all four deal buckets:

| Field | Schema | Returned by the API | Filled |
|---|---|---|---|
| Expected Deal Size | `mx_Custom_6` | yes | **0 / 107** |
| Expected Closure Date | `mx_Custom_8` | yes | **3 / 107** |
| Actual Deal Size | `mx_Custom_7` | **no** | cannot be read |
| Actual Closure Date | `mx_Custom_9` | **no** | cannot be read |

Two different problems. The *expected* fields are a **process gap** — readable, and empty on
every deal including the 150 already marked Won. The *actual* fields are a **visibility gap** —
configured in the form designer but never returned by `GetOpportunitiesOfLead`, so a rep can
fill them and no report can read them.

> An earlier version of this document claimed these fields did not exist. The API returns
> schema names with no display names, and only 4 of the 17 configured custom fields come back
> at all — so "unlabelled and empty" was misread as "absent". Check the form designer before
> concluding a field is missing. See gotcha 24.

Once values do exist, `Est. value we cannot see` prices the unvalued deals at each rep's own
average deal size. It is **the size of the blind spot, not a prediction**, and is labelled that
way wherever it appears. Where a rep has no valued deals at all it stays blank rather than
showing zero — zero would read as "nothing missing".

### Deal stages

Enumerated live, never hardcoded. As at 2026-08-09 — **1,398 opportunities, 1,248 Open,
150 Won**:

| Deal stage | Count | Status |
|---|---|---|
| Prospect | 1,107 | Open |
| Payment Received | 150 | Won |
| Requirement Gathering | 91 | Open — **legacy** |
| In Discussion | 50 | Open |

`Requirement Gathering` is a **legacy value** that `scripts/lib/schema.ps1`
(`OpportunityStageRenames`) specifies should have become `Prospect`; that rename is a dropdown
edit in the UI and was never applied. Same failure mode as the contact-stage drift found the
day before — a migration recorded as complete with live records still on the old value.
`v_deal_stage_drift` and QC check 10 watch it.

**Only EventCode 12000 is an opportunity.** EventCode 33 accompanies it on the same lead with
the same `CreatedOn` and no `ActivityFields` at all — ingesting it produced 1,089 blank ghost
rows against 1,398 real ones. Same trap as 3002 (gotcha 14).

**1,066 of 1,150 Prospect-stage contacts have a deal — 93%.** Before the date-gate fix the
same query said 22%, and "78% of prospects have no opportunity" was one step from being
reported as a finding about the team. Check the pipeline before diagnosing the business.

The rest of the tab works before a single amount is entered: `overdue`, `stale` (14 days with
no call) and `days open` need no deal value, so it is a deal-hygiene worklist from day one.

### Coming: per-call disposition, recording, transcript

Three changes are in flight and all three land on `fact_call`, whose columns already exist
(`disposition`, `recording_url`, `transcript`, `transcript_url`), nullable and unused. Adding
a nullable column to an 8,000-row table is instant; retrofitting after 200,000 rows, with a
re-ingest costing one API call per lead because there is no bulk activity read, is not.

`v_call_disposition_at_time` already prefers `fact_call.disposition` and falls back to the
12-hour inference from the contact-level field. The day LSQ ships per-call dispositions this
needs a mapping line in the ingest, not a redesign, and history stays continuous.

### Attribution rules (non-negotiable)

- A call counts for a rep only when the dialler is the lead's **current** owner. Contacts are
  reassigned constantly; without this a rep inherits the previous owner's whole history.
  Calls that fail the test are **bucketed as `<inherited: not the owner>`**, not dropped — so
  team totals still reconcile against `fact_call` and the volume stays visible. This rule was
  computed but not applied until migration `011`; it had been mis-crediting 9.9% of calls.
- **Never use `ProspectActivityName_Max` as a hard exclusion.** It holds one value — the last
  activity — so filtering the AI dialler out with it silently discards real rep calls on any
  contact the dialler touched afterwards. `backfill.ps1` did this until 2026-08-09;
  `-SkipAiOnly` still offers it and is documented as lossy.
- **EventCode 208 (Callkaro AI dialler) is dropped entirely.** It appeared on 40 of 971
  assigned contacts, 14 of which no rep had ever called.
- Inbound (21) counted separately from outbound reach.
- **Connected = duration > 0**, with `Status` kept as an independent cross-check.

---

## 6. Verification

```powershell
deno run --allow-read --no-check scripts/pipeline/test-calling-pipeline.ts   # 57 tests
pwsh ./scripts/pipeline/02-qc-today.ps1                                      # vs the live API
pwsh ./scripts/pipeline/verify-against-oracle.ps1 -TargetDate 2026-08-07     # rep-by-rep diff
pwsh ./scripts/pipeline/06-diff-rep-day.ps1 -Rep "Akshita Sharma" -TargetDate 2026-08-07
```

**When the oracle reports a rep off by N, use `06-diff-rep-day.ps1`** — it lists the actual
activity ids on each side. It pages that rep's book, narrows in memory to leads active since
the target day, and only then spends one call per trail: 340 calls to explain a two-call gap,
against 4,834 to re-run the oracle. Narrow before you spend; scanning a 9,000-lead book is more
expensive than the whole-team check it is meant to be cheaper than.

**The oracle earns its cost.** Its 2026-08-09 run against 7 August disagreed by one call in
2,249 — and both halves of that gap were real bugs that nothing inside the pipeline could see:
a hard exclusion on `ProspectActivityName_Max` dropping real calls, and the owner-attribution
rule being computed but never applied. Both were *shrinking* over time, so checking only a
recent day nearly missed them. See `memory/12` for the write-ups.

`verify-against-oracle.ps1` recounts a day straight from the LSQ API — deliberately without
reusing the pipeline's normaliser — and diffs `v_rep_day` per rep. It is the check that
matters; the only shared ingredient is the raw API response.

**Known bias in `02-qc-today.ps1`:** it scopes to contacts whose *last* activity is a call, to
match what the LSQ UI filter shows. A rep calls a lead at 10:00 and Callkaro touches it at
15:00, and that lead drops out of scope — so its total is a **floor, not the truth**. It
reported 418 for a day the pipeline recorded 980+, and the pipeline was right.

### The QC tab

`v_qc_pipeline` runs ten checks inside the warehouse, each against something that does not
share its arithmetic, and the **QC** tab renders them with expected vs actual.

| # | Check | Why it exists |
|---|---|---|
| 1 | No duplicate call activity ids | The PK makes it impossible; cheap proof the PK is what we think |
| 2 | Every call joins to an enriched contact | An unenriched call has no rep, company or stage, so it vanishes from every grouped view — **the most common cause of a total lower than LSQ's own filter** |
| 3 | `connected` matches `duration > 0` | Derived field must not drift from its source |
| 4 | No Callkaro AI-dialler calls stored | 208 inflates every coverage number and looks like rep activity |
| 5 | Pivot total equals raw dials today | Two different SQL paths to the same number; divergence means the pivot is dropping rows |
| 6 | Prospect-stage contacts that have an opportunity | A CRM gap, not a pipeline bug |
| 7 | Every opportunity joins to a contact | Otherwise the deal board shows `<unassigned>` for a real rep |
| 8 | Contacts on a non-canonical stage | Drifted values are invisible to a rep's own LSQ filter |
| 9 | Open opportunities that can be forecast | The business number this exists to expose |
| 10 | Book snapshot is from today | A stale snapshot looks exactly like a current one |

`FAIL` means a number in the workbook is wrong. `GAP`, `INFO` and `STALE` are business gaps or
operational reminders, not pipeline bugs.

The **"What the data can and cannot know"** block underneath (`v_data_boundaries`) states the
earliest and latest observation per stream. Read it before quoting any historical number — a
blank is not a zero, it is a period the pipeline could not observe.

Standing checks: `Meta` not red · `Pending` and `Unparsed` empty · QC shows zero `FAIL` ·
`-Action List` shows no webhook `DISABLED - 10 consecutive failures`.

---

## 7. Known gaps

1. **Notes are still not captured.** `CallNotes` was empty on every payload examined,
   confirming `memory/11`. The column exists and fills the day capture is switched on. The
   destination decision is open — most likely making EventCode 203's fields mandatory
   (`STAGE_RESTRUCTURE_PLAN.md` §8). **Until then this reports the what, not the why.**
2. **281 field-change events sit unimported** in the Unparsed tab, captured before the handler
   existed. A few hours of one day; a one-off importer would recover them.
3. **Lead Stage Change (webhook event 5) cannot be created via the API** — eleven body shapes
   rejected with "Webhook Properties is not a valid JSON", including a literal `{}`. Worked
   around with a field-change webhook on `ProspectStage`, which does the same job.
4. **Callkaro outcomes are discarded**, not merely excluded from metrics. Its note blob does
   carry outcomes; if those ever matter that is a separate table, never a merge into `fact_call`.
5. **Excel refresh needs desktop Excel.** Excel Online cannot refresh a Power Query with
   custom headers. The Google Sheet remains the always-on surface.
