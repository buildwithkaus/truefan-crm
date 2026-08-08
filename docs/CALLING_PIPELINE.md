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

| Tab | Contents |
|---|---|
| **Dashboard** | KPI strip + the pivot: rows rep × stage-at-call, columns disposition, cells calls |
| **Rep Day** | Per rep per day, 7 days |
| **Daily Trend** | Whole-team totals by day — the month view |
| **Funnel** | Stage movement; calls measure effort, this measures progress |
| **Exceptions** | The hygiene worklist, one row per violation |
| **Prospects** | Contacts promoted to Prospect |
| **Meta** | Health. Turns red when nothing has ingested recently |
| **Pending** | Rows parked because Supabase was unreachable; retried every 5 min |
| **Unparsed** | Payload shapes the parser did not recognise |

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

### Attribution rules (non-negotiable)

- A call counts for a rep only when the dialler is the lead's **current** owner. Contacts are
  reassigned constantly; without this a rep inherits the previous owner's whole history.
- **EventCode 208 (Callkaro AI dialler) is dropped entirely.** It appeared on 40 of 971
  assigned contacts, 14 of which no rep had ever called.
- Inbound (21) counted separately from outbound reach.
- **Connected = duration > 0**, with `Status` kept as an independent cross-check.

---

## 6. Verification

```powershell
deno run --allow-read --no-check scripts/pipeline/test-calling-pipeline.ts   # 44 tests
pwsh ./scripts/pipeline/02-qc-today.ps1                                      # vs the live API
pwsh ./scripts/pipeline/verify-against-oracle.ps1 -TargetDate 2026-08-07     # rep-by-rep diff
```

`verify-against-oracle.ps1` recounts a day straight from the LSQ API — deliberately without
reusing the pipeline's normaliser — and diffs `v_rep_day` per rep. It is the check that
matters; the only shared ingredient is the raw API response.

**Known bias in `02-qc-today.ps1`:** it scopes to contacts whose *last* activity is a call, to
match what the LSQ UI filter shows. A rep calls a lead at 10:00 and Callkaro touches it at
15:00, and that lead drops out of scope — so its total is a **floor, not the truth**. It
reported 418 for a day the pipeline recorded 980+, and the pipeline was right.

Standing checks: `Meta` not red · `Pending` and `Unparsed` empty · `-Action List` shows no
webhook `DISABLED - 10 consecutive failures`.

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
