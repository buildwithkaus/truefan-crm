# LeadSquared API gotchas

Every item here cost real time and is reproduced from a live incident. `CLAUDE.md` carries a
one-line index of these; this file is the full detail. Add to it whenever a new failure mode
is proven, with the date and what it actually cost.

The common thread: **LeadSquared fails silently far more often than it fails loudly.** Most of
these produce a plausible-looking wrong answer, not an error. Assume any surprising zero, any
suspiciously round number, and any "it worked" response is wrong until independently checked.

---

## 1. `Leads.Get` silently ignores a `Query` wrapper

`LeadManagement.svc/Leads.Get` accepts `Query.FilterBy` / `Query.DateRange` without error and
returns **unfiltered** results, sorted by whatever `Sorting` you passed.

Correct shape is a singular `Parameter` object:

```json
{ "Parameter": { "LookupName": "...", "LookupValue": "...", "SqlOperator": "=" } }
```

`CompanyManagement.svc/Company.Get` **does** use the `Query` wrapper correctly — `Query.FilterBy`,
`Query.CompanyType`, `Query.SearchText`, `Query.DateRange` all verified working there. Two
different underlying APIs with different contracts; a pattern proven on one says nothing about
the other.

*Cost (2026-07-27): an entire "leads active in the last 2 months" analysis was run against the
whole historical database because the filter no-op'd.*

**Rule:** before trusting any new filter combination, run a **negative control** — a value that
must return zero rows — and confirm it actually returns zero. Every report script in
`scripts/reports/` does this at the top; copy that pattern.

---

## 2. Enumerate dropdown values, never probe a guessed list

A filter returning **zero rows is a result to distrust as much as a suspicious non-zero one.**

The Phase 5 backfill probed `ProspectStage = "Invalid/Junk"` and `"Just Enquiring No Intent"`,
got 0 rows for both, and logged that as fact. The real stored strings were `Invalid/ Junk`
(space after the slash) and `Just Enquiring, No Intent` (comma). **20,076 leads silently
skipped — ~23% of the database** — found only because a separate full enumeration failed to
reconcile to the known total. Three further values were not in the documented list at all.

The only trustworthy way to learn a dropdown's contents is to paginate every record, tally the
actual stored values, and confirm the tally reconciles to the total record count. Hand-written
string literals in a migration script are a bug waiting to happen — generate the worklist from
live data.

Use `scripts/reports/enumerate-lead-field-values.ps1`. Detail: `memory/01-lead-schema-audit.md`.

---

## 3. Non-ASCII punctuation in a `.ps1` breaks the file after it

A PowerShell 5.1 script with an em-dash (or other non-ASCII punctuation) inside a double-quoted
string can throw a cascading parse error that silently breaks everything *after* it in the file,
**while the script still partially executes** — variables that should have come from a broken
function end up empty instead of the script failing outright.

This produced a malformed URL (`accessKey=&secretKey=`, no host) which threw
`System.UriFormatException` on every call. That is a **client-side** exception, so
`$_.ErrorDetails.Message` (which only exists on HTTP-response exceptions) came back blank every
time — making a 100%-failure run look like an unlabelled mystery rather than an obvious bug.

*Cost (2026-07-28): a full end-to-end 31,809-record run before it was caught.*

**Rules adopted:**
- Plain ASCII punctuation only in `.ps1` files (`-` not `—`, `'` not `'`).
- **Smoke-test a wrapper script standalone** before trusting it in a bulk run. Verifying the
  underlying API call works interactively is not the same as verifying the script that wraps it
  actually parses.
- In a catch block log `$_.Exception.Message` (always present) alongside
  `$_.ErrorDetails.Message` (HTTP errors only).

---

## 4. A killed script does not stop; confirm the process actually exited

A dot-sourced file is read once at process start — a running process does **not** pick up edits
to `lib/common.ps1`. A stale process left alive after a "fix and restart" keeps running the old
broken code forever, writing failures into the same shared log alongside the new correct run,
making a fixed bug look unfixed.

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Select-Object CommandLine
```

Not `Get-Process` by name — several unrelated `powershell.exe` processes exist for IDE tooling.
Note this check will match its own command line; read the output, don't just count it.

Detail: `memory/05-departed-owner-reassignment.md`.

---

## 5. `Invoke-RestMethod` does not send UTF-8 reliably

`Invoke-RestMethod -Body <string> -ContentType "application/json"` (no charset) in Windows
PowerShell 5.1 mis-encodes any non-ASCII character in a value being written — accented letters,
`°`, `®`, common in real `CompanyName` values. The server's UTF-8 JSON parser then returns a
genuine `400 Bad Request` (`"Unexpected character encountered while parsing value"`). Not
transient: every retry fails identically until the encoding is fixed.

*Hit during the Phase 3 Opportunity backfill — 4 of 4,404 companies: `360°Career Institute`,
`Étiicos`, `BodyCafé`, `SHAFAQUE ®`.*

Use `Invoke-LsqPost` in `lib/common.ps1`, which converts to explicit UTF-8 bytes and sets
`charset=utf-8`. Never pass a string body directly for a write.

---

## 6. Timestamps are UTC; this account operates in IST

`ModifiedOn`, `CreatedOn` and `ProspectActivityDate_Max` are stored and returned in **UTC**,
while the account runs in IST (UTC+5:30). A filter timestamp built from local `Get-Date` is
therefore 5.5 hours in the *future* and matches **zero rows, forever** — a polling or watermark
job built on it looks healthy and does nothing at all.

Proven live 2026-07-28:

```
UTC-correct    ModifiedOn > 2026-07-28 08:08:44  ->  352 rows
local (wrong)  ModifiedOn > 2026-07-28 13:38:44  ->    0 rows
```

Use `Get-LsqTimestamp` for every timestamp sent to the API. Never format one by hand. When
computing a calendar-day window, derive it from local midnight and convert — do not string-match
a date.

---

## 7. Boolean-ish fields use three different conventions

For `IsPrimaryContact` and probably other bit fields:

| Operation | Accepts / returns |
|---|---|
| Reading | the **string** `"1"` / `"0"` — not a boolean, not `"true"` |
| Filtering | `LookupValue="1"`. Passing `"true"` returns **HTTP 500** |
| Writing | `"true"` |

Comparing a read value against `$true` or `"true"` is False for every record, silently making
every primary contact look non-primary. This was a real bug in this repo's own migration code,
caught 2026-07-28 before it ran: it would have let a second Opportunity attach to a different
contact at an account that already had one.

Use `Test-LsqTrue` for reads.

---

## 8. `Company.Update` requires a `CompanyProperties` wrapper

A bare array `[{"Attribute":"Stage","Value":"X"}]` returns
`MXInvalidDataTypeException: "You're missing Company details."` on **every** call — including
writing a company's own existing value back to itself. The error looks like a dropdown/data
problem but is a body-shape problem.

Correct: `{"CompanyProperties":[{"Attribute":"Stage","Value":"X"}]}`

Found 2026-07-29 because `05-migrate-companies.ps1`, `08-rollback.ps1` and `sync-engine.ps1` all
had it wrong and none had been run against production yet — it would have failed the entire
company-writing leg of the migration *and* the rollback safety net at the same time.

---

## 9. A paginated page can arrive nested one level deeper

`Invoke-RestMethod` intermittently returns a `Leads.Get` page as `Object[1]` wrapping the real
`Object[1000]` instead of a flat array, for byte-identical requests. Every paginating loop is
shaped `if ($resp.Count -lt 1000) { break }`, so the nested shape reads "1 record, fewer than
PageSize, stop" and the script reports **a complete scan of the whole account after one page.**

It is decided **per-process**: a process that gets the nested shape gets it on every call; a
process that gets the flat shape never sees it. That stickiness is what makes it so misleading —
isolated health-check scripts pass 40/40 while the real script fails identically every run, which
reads exactly like an intermittent API outage. It was misdiagnosed as one (a real billing-related
access restriction had occurred separately, which made the wrong explanation fit).

Diagnosed 2026-07-29 by noticing a "1-row" response held a field whose value stringified to ~1000
space-separated values — the data was always there, only the shape was wrong.

**Fix:** wrap every page fetch in `Expand-LsqRows`. Note its `return $out.ToArray()` deliberately
has **no** leading comma — `return , $arr` would suppress unrolling and make `@(Expand-LsqRows ...)`
read `1` again, reintroducing the exact bug.

**This regressed once already.** On 2026-08-14 the comma was added to make a handful of new bare
`$rows = Expand-LsqRows ...` call sites safe on single-row pages. Measured immediately afterwards,
`@(Expand-LsqRows ...)` returned `Count = 1` for a 0-row page, a 1-row page and a 3-row page alike,
with `[0]` holding the whole inner array — breaking all 78 wrapped call sites at once, including
`backfill.ps1` and `12-load-contact-book.ps1`. It surfaced as a **negative control returning 1
instead of 0**, which is the only reason it was caught rather than shipping a truncated scan.

The single-row concern is real but belongs at the call site: use `@(Expand-LsqRows ...)`, never a
bare assignment. A bare `PSCustomObject` has no `.Count` in PowerShell 5.1 — it reads as empty
string, not `1`. Do not fix that by changing the contract underneath 78 callers.

### Corollary — an internal-consistency check is not a reconciliation

`02-build-worklist.ps1` verified `$sum -eq $total` and logged "Reconciliation OK", which a
truncated scan passes trivially (`1 == 1`). A guard must compare against an **absolute expected
size from an independent source**, not against another number derived from the same bad read.

Absolute guards now live in `02-build-worklist` (worklist), `03-backup` (refuses to write a
partial backup — it is the only thing `08-rollback` can restore from), `08-rollback` (refuses to
compute a delta from a short read), and every script in `scripts/reports/`.

---

## 10. LSQ stores a dropdown value that is not in the dropdown

Writing `mx_Disqualification_Reason = "Invalid / Not a Business"` succeeds even when that string
is not one of the field's options, and reading it back returns it correctly — so every
verification this repo does would pass. But the value is **not selectable by a rep and a dropdown
filter will never offer it**, making those records invisible to the people the field exists for.
Nothing in a write log reveals it.

Hit twice on 2026-07-31 — Call Disposition (3 plan names that were never options) and
Disqualification Reason (**9 options vs 12 stored values, zero overlap, 61,919 leads
unfilterable**) — and **both were found by a human trying to filter, not by any check here.**

Verifying a value is *correct* is not verifying it is *selectable*. Run
`scripts/reports/verify-dropdown-coverage.ps1` (checks all six Lead dropdowns at once) after
anything that writes a dropdown field; checking one field by hand is how the second instance
survived the fix for the first.

The repair is not always "fix the data" — if the existing option list cannot express the new
values, extend the dropdown instead. `CreateLeadField` rejects option values containing
`(`, `)`, `/`, `-`, `'` or `,` ("Only alphanumeric characters, space, underscore is allowed"),
so punctuated options must be added in the UI.

---

## 11. Native LSQ automations do not fire on API/bulk writes

A live automation (Company `Fresh`→`Nurture` on Contact `Fresh`→`Engaged`) did not react to
17,011 leads moved via `Lead/Bulk/UpdateV2`: the backlog went **5,115 → 5,111 over 19 minutes**,
which is ordinary rep clicking, not an async queue draining.

Treat automations as covering **UI edits only** until the SPOC confirms otherwise. Two
consequences: pair every bulk write with a reconciler run, and never conclude an automation
worked without measuring the backlog before and after with a delayed re-check — "hasn't fired
yet" and "never will" look identical at a glance.

---

## 12. PowerShell collection and array traps

**`@()` on a `List[object]` variable throws.** On this machine,
`Missing = @($missingOpp)` inside a `[pscustomobject]@{...}` literal throws
`System.ArgumentException: "Argument types do not match"` for *every* size of list, including
empty and single-item, in a totally fresh process. With `$ErrorActionPreference` at its default
(`Continue`) this is **non-terminating** — the script prints the exception and keeps running,
eventually logging "JSON snapshot written" for a file that was never created. A false success
line is worse than a hard stop.

Use `.ToArray()` on the list instead of `@()`. Piping a list through a pipeline
(`$list | Where-Object {...}`) is unaffected — only a bare `@($list)` on a variable reference.

**Set `$ErrorActionPreference = "Stop"` at the top of every new script** so a bug like this fails
loudly instead of being swallowed into a false "complete" report.

**A function that logs and returns hands back both.** Every unredirected output statement in a
PowerShell function becomes part of its return value, so a function calling `Write-LsqLog`
internally returns the log-line strings bundled with the real value. **Any function that both
logs and returns needs to be two functions**: one pure (computes, no I/O), one void (logs, takes
the computed result as a parameter). See the `Get-Tally` / `Write-Tally` split used throughout
`scripts/reports/`.

**`ConvertTo-Json` collapses a single-element array** into a bare object, breaking any API
expecting `[{...}]`. Build single-element array bodies as literal strings.

**Excel COM / multi-dimensional arrays** (hit 2026-08-03 building `export-distribution-xlsx.ps1`):
- Indexing a true 2-D array with an arithmetic expression needs explicit parens —
  `$arr[$r + 1, $c]` throws `op_Addition`. Assign to a variable first.
- **Returning an `object[,]` through a normal `return`/pipeline silently flattens it to 1-D** —
  `.Rank` drops from 2 to 1 and `.GetLength(1)` then throws. This happens at *every* function
  boundary the array crosses. Use `Write-Output -NoEnumerate $arr` at each one.

---

## 13. GNU sed eats `\0` and `\l` (tooling, not LSQ)

Hit 2026-08-08 during the repo restructure. In a `sed` replacement, `\l` is "lowercase the next
character" and `\0` is a whole-match backreference — so rewriting Windows paths like
`$PSScriptRoot\..\lib\schema.ps1` through sed silently produced `$PSScriptRoot..ibschema.ps1`,
and a pattern containing `\00-schema` never matched at all. Worse, the verification grep used the
same broken escaping and reported success.

**For Windows path rewrites across files, use PowerShell's `String.Replace` (ordinal, literal),
not sed.** If you must verify with grep, verify with a *differently written* pattern than the one
you edited with — otherwise the same escaping bug hides the failure twice.

---

## 14. The Activity record shape (and three beliefs about it that were wrong)

Established live 2026-08-08 by fetching a real `EventCode 22` record and printing every field.
None of this was written down, because every report in `scripts/reports/` only ever *aggregated*
activities — so the record's own identity had never been needed, and several assumptions about it
turned out to be wrong. `scripts/lib/activity.ps1` and
`supabase/functions/_shared/normalize.ts` encode all of it; use those rather than re-deriving.

The captured shape:

```
Id                  GUID   <-- the primary key
EventCode           22 | 21 | 203 | 3002 | 12000 | 33 | 208
EventName           "Outbound Phone Call Activity"
CreatedOn           "2026-07-31 05:33:50"     <-- UTC, sortable format
ModifiedOn          "2026-07-31 05:35:00"
RelatedProspectId   GUID of the lead
ActivityType        3 (call) | 26 (stage change) | 2 (custom form)
Type                "Outbound" | "Inbound" | "Information"   <-- NOT reliable
Data                array of {Key,Value}   <-- on 22 AND on 3002
ActivityFields      object                 <-- ABSENT entirely on 3002
```

**The primary key is the top-level `Id`.** `ActivityFields.ProspectActivityAutoId` is a second,
integer identifier on the same record. Anything that *stores* activities must key on one of these
or it silently double-counts on every re-ingest — and a duplicate row inflates a call count
without ever looking like an error.

**`ActivityEvent_Note` contains DUPLICATE keys.** Verbatim from the live record:

```
Caller{=}Vikhyat Verma{next}UserId{=}{next}UserId{=}4057ed7a-21ce-11f1-bd10-0a70299d455d
{next}Duration{=}64{next}Status{=}Answered{next}CallNotes{=}{next}ResourceURL{=}
{next}StartTime{=}7/31/2026 5:33:49 AM{next}Tag{=}{next}DisplayNumber{=}{next}...
```

`UserId` appears twice and **the first one is empty**. `icp-rep-compliance.ps1`'s
`Get-CallNoteValue` matches non-greedily and returns the first hit, so it reads `""` for `UserId`
on every record while appearing to work perfectly. Scan every occurrence and take the last
non-empty one. Keys seen: `Caller`, `UserId`, `Duration`, `Status`, `CallNotes`, `ResourceURL`,
`StartTime`, `Tag`, `DisplayNumber`, `EventNote`, `SourceData`.

**EventCode 3002 has no `ActivityFields` whatsoever** — only `Data[]`, carrying `PreviousStage`,
`CurrentStage`, `CreatedBy` (a display **NAME**, not a GUID) and `Comment`. This settles a direct
contradiction in the repo: `daily-calling-report.ps1` was right, `memory/10-rep-activity-
measurement.md` ("its ActivityFields are empty, so old->new is not available") was wrong.

**EventCode 22 also carries `Data[]`** — `CallType` (e.g. `Complete`), `Caller`, `Duration`,
`ResourceUrl` — which is an independent cross-check on `mx_Custom_3` and a useful fallback when
that field is empty.

**Never branch on the `Type` field.** A Callkaro `EventCode 208` outbound AI call reports
`Type="Inbound"`. Branch on `EventCode`, always.

**EventCode 203 and EventCode 22 reuse `mx_Custom_2` and `mx_Custom_3` for completely different
things** — 203: Connected Outcome / Next Step. 22: Start Time / Call Duration. Any generic
`mx_Custom_N` flattener that does not branch on event code first will silently mix call durations
into text outcomes.

**Two timestamp formats appear on one record.** Activity-level `CreatedOn` is
`"2026-07-31 05:33:50"`; `ActivityFields.CreatedOn` is `"7/31/2026 5:33:50 AM"`. Neither carries a
zone and both are UTC. Parse with explicit formats and InvariantCulture — a bare `[datetime]` cast
is culture-dependent and transposes day and month on an en-GB machine.

### `ProspectActivityName_Max` is filterable, and is the cheapest candidate filter available

Verified 2026-08-08: negative control returned 0 rows, and the value tally reconciled exactly
(5,823 / 5,823) against the scanned total. Distribution over a two-day window:

| Value | Leads |
|---|---|
| `Outbound Phone Call Activity` | 3,032 |
| **`AI Phone Call / Follow Up`** | **2,405** |
| `Dynamic Form Submission` | 122 |
| `Opportunity` | 107 |
| `Inbound Phone Call Activity` | 99 |
| `Lead Capture` | 51 |
| `01. Phone Call/ Follow Up` | 7 |

Two consequences. First, **Callkaro is 41% of all lead-touch volume**, so excluding it roughly
halves the cost of any watermark-driven job. Second — and this is the trap — the field holds a
**single** value, so a rep call followed by an AI dialler touch on the same lead reads as AI.
**Never use it as a hard exclusion without a fallback pass that ignores it**, or you rebuild the
silent-skip failure this document already describes twice (gotchas 2 and 9). The pipeline handles
this by putting the exclusion in SQL where the watermark is visible (a never-before-seen lead is
always pulled) and by running an end-of-day pass with no name filter at all.

Note also that `01. Phone Call/ Follow Up` (EventCode 203) is **not dead** — `memory/11` records
it as unused since November 2025, but it is the last activity on 806 leads account-wide.

## 15. `Webhook.svc` - three undocumented contract quirks

Established live 2026-08-08 by probing body shapes until one worked. **Native Webhooks are a
different subsystem from Automations**, and this repo did not know the feature existed - it
is the mechanism the calling pipeline now runs on. Working code:
`scripts/pipeline/01-manage-webhooks.ps1`.

**`ActivityEvent` must be passed at the TOP LEVEL of the create body.** The documentation
shows it only inside the `WebhookProperties` string. That form alone fails:

```
HTTP 500  MXInvalidDataTypeException: "You have not passed ActivityEvent."
```

Send both - `WebhookProperties` as documented *and* a top-level `ActivityEvent`.

**`WebhookProperties` must be a STRING of escaped JSON, not a nested object.** Passing an
object returns `400` with a JSON parse error. So the working body is:

```json
{ "WebhookEvent": "2",
  "ActivityEvent": "22",
  "WebhookProperties": "{\"ActivityEvent\":\"22\",\"ActivityData\":\"[]\",\"WebPageNames\":\"[]\"}" }
```

**`Delete` is a GET with the id in the query string.** `POST` - the pattern every other
`Webhook.svc` verb uses - returns `405 Method Not Allowed`:

```
GET /v2/Webhook.svc/Delete?accessKey=..&secretKey=..&webhookId=<id>
```

**And the failure mode that made this expensive:** LSQ returns **500** for malformed input
here, which `Invoke-LsqWithRetry` correctly classifies as transient and retries four times.
The real message only appears in `$_.ErrorDetails.Message`. Three retries of a
"server error" that was actually a body-shape bug - the same family as gotcha 3.

### The webhook contract itself

From LSQ's best-practices page, and all three are load bearing:

- **Always return HTTP 200, even on error.** Report the problem in a `StatusReason` field.
  **Ten consecutive non-200s disable the webhook** and re-enabling is manual - so returning
  `401` to a bad secret lets anyone switch off ingestion by posting garbage eleven times.
- **Verification is performed with NO payload.** A handler that requires a body never
  verifies, so the webhook never activates at all.
- **Activity webhooks are batched** - LSQ groups everything from one minute together, so the
  body is always an array. Measured latency: about 2 minutes.

Custom headers are supported (up to 10) - but **Apps Script cannot read request headers**, so
an Apps Script receiver has to fall back to a query-string secret.

## 16. The webhook payload and the activity trail use the same key for different things

Both describe an activity. They are not the same shape, and one key actively lies:

| `ProspectActivity.svc/Retrieve` | `Lead Activity Creation` webhook |
|---|---|
| `Id` | `ProspectActivityId` |
| `EventCode` | `ActivityEvent` |
| `EventName` | `ActivityEventName` |
| `ActivityFields` (object of fields) | **`Data`** (object of fields) |
| **`Data`** (ARRAY of `{Key,Value}`) | *(absent)* |
| `ActivityFields.ActivityEvent_Note` | `Data.Note` |
| `ActivityFields.CreatedBy` | top-level `CreatedBy` |

**`Data` is an array of key/value pairs on the trail and the fields object on the webhook.**
A normaliser written for one reads nothing from the other, and reads it *silently* - no
error, just empty columns. Keep the two normalisers separate and named for their source;
`appsscript/CallingPipeline.gs` has `normalizeWebhookActivity_`, and
`supabase/functions/_shared/normalize.ts` has the trail version.

The good news buried in this: **the webhook payload is complete.** Activity id, lead id,
actor, timestamp, status, duration and the note blob all arrive, so recording a call needs
zero API calls. And **it does fire on telephony-created activities** - proven with real
handset calls by two reps - which gotcha 11 gave good reason to doubt.

## `GetOpportunitiesOfLead` returns FLAT properties; only `GetOpportunityDetails` has `Fields[]`

Found 2026-08-14, present since the object went live.

The two opportunity reads return **different shapes**, and the repo conflated them:

```
GetOpportunitiesOfLead   ->  .List[] items are FLAT:
                             $o.mx_Custom_1, $o.mx_Custom_2, $o.Status, $o.Owner,
                             $o.OpportunityId, $o.RelatedProspectId, $o.ModifiedOn
                             There is NO $o.Fields member.

GetOpportunityDetails    ->  .Fields[] is an ARRAY of
                             { SchemaName, DisplayName, DataType, Value }
```

Five scripts read `foreach ($fld in $o.Fields)` against the **flat** endpoint. That loop simply
never executes, so the hashtable stays empty and every field reads `$null`. Nothing throws. The
record count is right, the row exists, and every value inside it is blank — which looks like an
empty-but-present opportunity, not a bug.

What it actually cost:

- **`03-backup.ps1` wrote a structurally empty opportunity backup.** Every `Status`, `Stage` and
  `Name` was null across the whole file, while the log reported a healthy row count. The Phase 5R
  rollback set for opportunities was worthless for a fortnight and nobody could have known from
  the output. `03b`, which exists to *fill the gaps* in that backup, had the same bug.
- **`validate-consistency.ps1`'s V4 check was dead.** Status and Stage were always null, so
  `Get-ContactStageFromOpportunity` always returned `$null`, so the contact-stage-vs-deal-stage
  drift check silently passed on every contact it examined.
- **`sync-engine.ps1` fed empty input to every sync-rules decision.**

Same family as gotcha 24 — an unlabelled, empty field in a payload is not a missing field — and
the same family as gotcha 2: a shape that returns nothing looks like a fact.

Read through `Get-LsqOpportunitiesOfLead` / `Get-LsqOpportunityDetails` in
`scripts/lib/opportunity.ps1` rather than hand-rolling either call. Related trap in the same
scripts: `catch { return @() }` around an opportunity read turns a transport failure into "this
lead has no deals" — and in a create path that produces a duplicate deal which **cannot be
deleted** (`CanDelete: false`). The helper throws instead.

## No bulk Opportunity read endpoint exists

Eight candidate names probed 2026-07-28; all 404 except per-lead access
(`GetOpportunitiesOfLead?leadId=X&opportunityType=12000`, where `opportunityType` is **required**
despite the docs implying otherwise, and `ProspectActivity.svc/Retrieve?leadId=X`).

Any opportunity-driven or activity-driven job therefore costs **one API call per lead** — scope by
watermark or by a bounded candidate set, never sweep everything. Full list of what was probed:
`docs/AUTOMATION_CAPABILITIES.md`.

The same is true of Activities: there is no bulk Activity read. `scripts/reports/` works around
this by narrowing to a candidate set first (by Source, by owner, or by
`ProspectActivityDate_Max` watermark) and only then pulling per-lead trails.

## No Notes API exists

Five candidate endpoints probed 2026-08-05, all 404. The lead-level `Notes` field is the only
note store on this account. See `memory/11-crm-hygiene-findings.md` — it currently holds imported
ICP business descriptions, so it is not usable for rep call notes without destroying that data.

---

## Schema-name gotchas

- **Company object:** `Include_CSV` column list is picky — omit it and fetch full records
  (`companyPropertyList`) rather than guessing exact field names. The display-name field for owner
  is `OwnerName`, **not** `OwnerIdName` (that is the Lead-side name).
- **Lead object:** `ProspectStage` has display name "Contact Stage". Disposition is
  `mx_Call_Disposition`, disqualification is `mx_Disqualification_Reason` /
  `mx_Disqualification_Category`.
- **The cached `data/lead_fields_schema.json` is from 2026-07-27 and predates the migration** — it
  does not contain `mx_Call_Disposition` or `mx_Disqualification_Reason`. Fetch
  `LeadManagement.svc/LeadsMetaData.Get` for the live list rather than trusting that file.
