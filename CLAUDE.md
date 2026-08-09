# TrueFan CRM — LeadSquared working repo

## What this project is

TrueFan (truefan.ai) sells celebrity-fronted brand content (video/photo/social) to businesses,
plus an emerging "AI for Business" line, through an outbound sales motion run on LeadSquared.
This repo is the working codebase for that CRM: the completed stage/object restructure, the
recurring reporting that runs against it, and the SOP for reps.

**Read `PROJECT_PLAN.md` for current phase and status** — its phase headers are the single source
of truth for project state. `memory/` holds the findings behind every decision. This file is
orientation and hard rules.

## Repo layout

```
scripts/
  lib/         common.ps1 (auth, request helpers, all API workarounds), schema.ps1 (stage taxonomy)
  reports/     recurring READ-ONLY reporting - the day-to-day tools. Safe to re-run any time.
  migration/   the one-time 2026-07-30/31 stage restructure. Done. Kept for audit + rollback.
  sync/        stage-sync engine and its rules/tests
  archive/     completed one-off remediations (enrichment, backfills, reassignments). Reference only.
docs/          SOP, automation spec, capability probes, API gotchas
memory/        numbered findings and decisions, each self-contained with sourcing and dates
config/        .env.example - copy to .env (gitignored) and fill in credentials
data/          gitignored. Real CRM exports, backups, report output, migration logs.
```

Every script dot-sources shared helpers rather than importing a module:

```powershell
. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"   # only if it needs the stage taxonomy
```

`common.ps1` provides `Import-LsqConfig`, `Get-LsqUrl`, `Invoke-LsqLeadSearch`,
`Invoke-LsqCompanySearch`, `Invoke-LsqPost`, `Invoke-LsqWithRetry`, `Expand-LsqRows`,
`Test-LsqTrue`, `Get-LsqTimestamp`, `Write-LsqLog`. **Extend these rather than writing new inline
API calls** — each one exists because of a specific production failure.

## Setup and running

```powershell
Copy-Item config\.env.example config\.env    # then fill in LSQ_ACCESS_KEY / LSQ_SECRET_KEY
pwsh ./scripts/reports/<script>.ps1
```

No package.json, no build, no linter, no CI. Nothing to install beyond PowerShell.

**There are no automated tests and you should not add a framework.** Verification is manual
against the live API: change one record, then independently re-fetch it to confirm the change
took. A "Success" response body alone is not sufficient. The pattern is in
`scripts/archive/reassign-departed-owners.ps1`.

## Business context

- Reps are full-cycle owners of an account (hunt → close → manage) on contracts of 1 month to
  1 year. Not a single-touch close.
- **Object model:** `Company (Account) → Lead(s)/Contact(s) → Opportunity → Activity`.
  Opportunities attach to a **Lead, not a Company** — a Company reaches its Opportunities only
  transitively. Only the Lead flagged `IsPrimaryContact` may own an Opportunity for that Company,
  otherwise multiple contacts at one account fragment into multiple "deals".
  Detail: `memory/03-object-model-and-relationships.md`.
- **The Lead/Contact object is live production that reps use every day.** Changes there are
  **additive only** — never repurpose or remove a field or picklist value reps depend on without a
  migration path, and flag for human review first. Company and Opportunity are fair game.

## Hard rules

1. **Negative-control every new filter.** Run a value that must return zero rows and confirm it
   does, before trusting the filter. A zero result is as suspicious as a weird non-zero one.
2. **Never hand-write dropdown value strings.** Enumerate them from live data
   (`scripts/reports/enumerate-lead-field-values.ps1`) and generate the worklist from that.
3. **One record, then re-fetch, then scale.** No exceptions for writes.
4. **Guard against truncated scans with an absolute expected size** from an independent source —
   not against another number derived from the same read.
5. **`$ErrorActionPreference = "Stop"` at the top of every script.** The default `Continue` turns
   bugs into false "complete" reports.
6. **Plain ASCII punctuation only in `.ps1` files.** Non-ASCII breaks parsing in a way that still
   half-executes.
7. **Smoke-test a script standalone before any bulk or background run.** Parsing correctly is a
   separate question from the API call working.
8. **After writing any dropdown field, run `scripts/reports/verify-dropdown-coverage.ps1`.** LSQ
   stores values that are not in the dropdown, making records invisible to rep filters.
9. **Log to `data/*_log.txt`** for an audit trail independent of LSQ's own history. Do **not**
   `tail -f` a log while its script runs — on Windows the reader holds the file open, every
   `Add-Content` then fails, and the run continues with console output but no audit trail. Read
   the background task's own output file instead.
10. **Credentials live in `config/.env` only.** Never hardcode them in a committed script. The
    current keys were shared in chat before this repo existed and are flagged for rotation.

## API gotchas — index

Full detail with incident write-ups: **`docs/LSQ_API_GOTCHAS.md`**. Read it before writing any
new script. One line each:

1. `Leads.Get` silently ignores a `Query` wrapper — use singular `Parameter`. `Company.Get` is the
   opposite and *does* use `Query`.
2. Probing a guessed dropdown value returns 0 rows and looks like fact — 20,076 leads were once
   silently skipped this way. Enumerate instead.
3. Non-ASCII punctuation in a `.ps1` cascades a parse error that still half-executes.
4. A killed script keeps running the old dot-sourced code — confirm the process actually exited.
5. `Invoke-RestMethod` with a string body does not send UTF-8 — use `Invoke-LsqPost`.
6. All timestamps are UTC, the account is IST — use `Get-LsqTimestamp` or match zero rows forever.
7. Boolean fields read `"1"`, filter `"1"` (`"true"` → HTTP 500), write `"true"` — use `Test-LsqTrue`.
8. `Company.Update` needs a `CompanyProperties` wrapper; a bare array always fails.
9. A page can arrive nested one level deeper, making `.Count` read `1` and a scan stop after one
   page — wrap every fetch in `Expand-LsqRows`.
10. LSQ stores dropdown values that are not in the dropdown; they verify fine and are invisible to
    reps.
11. Native automations do not fire on API/bulk writes — pair bulk writes with a reconciler.
12. PowerShell traps: `@()` on a `List[object]` throws; a function that logs *and* returns hands
    back both; `ConvertTo-Json` collapses single-element arrays; `object[,]` flattens on return.
13. GNU sed eats `\0` and `\l` — use PowerShell `String.Replace` for Windows path rewrites.
14. The Activity record: PK is the top-level `Id`; `ActivityEvent_Note` has **duplicate keys**
    (take the last non-empty); 3002 has no `ActivityFields` at all; 203 and 22 reuse
    `mx_Custom_2/3` for different things; never branch on `Type`. Use `scripts/lib/activity.ps1`.
    **EventCode 33 is the same trap as 3002** — it accompanies every 12000 on the same lead
    with the *same* `CreatedOn` and no `ActivityFields`, so treating it as an opportunity
    creates a blank ghost row per deal (1,089 ghosts against 1,398 real).
15. `Webhook.svc`: `ActivityEvent` must ALSO go at the top level of the create body (docs say
    otherwise, and the doc's form 500s); `WebhookProperties` must be an escaped JSON *string*;
    `Delete` is a **GET**. A webhook endpoint must return **200 always** - ten non-200s disable
    it - and must answer a payload-less verification ping.
16. The webhook payload and the activity trail use **`Data` for different things** (fields
    object vs array of `{Key,Value}`). A normaliser for one silently reads nothing from the
    other. The webhook payload is complete, and it **does** fire on telephony-created calls.
17. Timestamp formats vary **by field**: `ProspectActivityDate_Max` carries milliseconds
    (`2026-08-08 07:38:00.000`), activity `CreatedOn` does not. A parser missing `.fff`
    returns null and the caller skips every row — which looks like an empty day, not an error.
18. A substituted placeholder is only safe in the **last** position of a `coalesce` chain.
    `coalesce(x, '<unknown>')` upstream defeats `coalesce(that, fallback)` downstream, because
    the placeholder is not null. Collapsed 980 calls onto one row.
19. PowerShell: `$pid`, `$host`, `$error`, `$input`, `$args`, `$matches` are **read-only
    automatic variables** — assigning one throws mid-run. And `@()` on an
    `Invoke-RestMethod` result counts `$null` as 1 and a nested array as 1; prefer
    `Invoke-WebRequest | ConvertFrom-Json`.
20. PostgREST bulk insert requires **every object to carry an identical key set**
    (`PGRST102`). Project rows through a fixed per-table schema before serialising rather
    than trusting each construction site to build the same hashtable.
21. **The documented opportunity `WebhookEvent` codes are wrong.** Real mapping, enumerated
    live: `29` Create, `30` Update, `31` **Delete** — the docs call 31 "Create", so following
    them puts a delete-listener on the account. `33`/`34` return 500, `35`/`36` "not found",
    so there is **no working opportunity stage-change event**. Always read back what was
    actually created. Only **one field-change webhook per field** is allowed, so renaming one
    means delete-then-create.
22. PowerShell **aliases outrank functions**. A helper named `Del` is silently shadowed by
    the built-in `del` → `Remove-Item`, so every call tries to delete a file path. Same
    family as `$pid`: use approved verbs (`Remove-LsqWebhook`), never a short alias-like name.
23. **`GetOpportunitiesOfLead` is a POST with an empty body** (a GET returns 405) and there is
    **no `/Opportunity/` path segment** — `OpportunityManagement.svc/GetOpportunitiesOfLead`,
    not `.../Opportunity/GetOpportunitiesOfLead`. The wrong path 404s on every method, which
    reads as "the endpoint does not exist" rather than "the URL is wrong". **No opportunity
    field-metadata endpoint exists** (14 candidates probed; only `GetOpportunityTypes`
    answers, and its `Fields` is null) — the only way to learn the opportunity schema is to
    read a real opportunity.
24. **The opportunity API returns SCHEMA names with no display names, and only a subset of the
    fields that exist.** The Opportunity object has **17 custom fields** in the LSQ form
    designer (`mx_Custom_6` Expected Deal Size, `_7` Actual Deal Size, `_8` Expected Closure
    Date, `_9` Actual Closure Date, `_4` Loss Reason, `_16`/`_17` Agreement/Invoice Sent Date,
    …), but `GetOpportunitiesOfLead` returns only `mx_Custom_1`, `_2`, `_6`, `_8` and `Status`.
    **An unlabelled, empty field in the payload is not a missing field** — reading it that way
    produced a confident, wrong "there is no deal-value field" on 2026-08-09. Check the form
    designer before concluding a field does not exist. `_7`/`_9` currently cannot be read at
    all; suspected to be the grid/list-view configuration, untested.
25. **Three ways to read an opportunity, each returning a different subset.** The activity
    trail (EventCode 12000) has only `mx_Custom_1`, `_2`, `Status`, `Owner`.
    `GetOpportunitiesOfLead` adds `_6`/`_8`. **`GetOpportunityDetails?opportunityId=X` (a GET)
    returns all 29 fields with `DisplayName` and `DataType`** — it is also the field-metadata
    endpoint gotcha 24 says does not exist, because it was not among the 14 names probed. The
    `opportunityId` is the same GUID as the activity `Id`, so no lookup pass is needed.
26. **`Requirement Gathering` means different things on the Contact and the Opportunity.** On
    the **Opportunity** it is a real, current stage — the *warm* pipeline. On the **Contact**
    it is legacy and maps to `Prospect`. `schema.ps1`'s `OpportunityStageRenames` refers to
    the Contact. Treating the opportunity value as drift flagged a healthy warm pipeline as a
    data-quality failure.
27. **Apps Script's UrlFetch quota is shared across EVERY trigger, function and webhook
    execution in the project**, and blowing it fails the *last* thing to run rather than the
    thing that spent it — so the symptom appears on innocent code. A job that fetched
    per-record on a 10-minute trigger spent ~29,000 calls/day on its own and silently killed
    the dashboard for a full day. Batch reads server-side (one RPC returning a JSON bundle,
    not N REST calls), bound every per-record loop, and **meter the spend** — `ufFetch_`
    counts, `ufSpentToday_` reports, and enrichment yields to reporting under pressure.
28. **`dim_rep` was created in migration 001 and never populated.** Most views coalesce
    through `dim_contact` and looked fine, so an empty join table survived a week; it only
    surfaced as a raw GUID appearing where a rep name belonged. Anything created empty and
    filled "later" needs the filling wired into a job that already runs.
29. **Apps Script concatenates every `.gs` in a project into ONE global scope; the last
    definition of a name wins**, with no module system and no warning. `WebhookCapture.gs`
    and `CallingPipeline.gs` both define `doPost`/`ok_`; the archived `SheetsSync.gs` collides
    with nine more including `TABS` and `writeTable_`. If the wrong one loads last, live
    webhooks land in a capture sheet and never reach Supabase — and LeadSquared still gets its
    200, so nothing reports an error. **See `appsscript/README.md` for which file belongs in
    which project.**

Plus: **no bulk Opportunity read endpoint and no bulk Activity read endpoint exist** — both cost
one API call per lead, so always narrow to a candidate set first. **No Notes API exists** either.
`ProspectActivityName_Max` ("last activity") *is* filterable and is the cheapest way to narrow a
candidate set — but it holds a single value, so never use it as a hard exclusion (gotcha 14).

## Reporting conventions

The reports in `scripts/reports/` measure rep activity from the **native telephony log**
(EventCode 22, Outbound Phone Call Activity), not from CRM field values, because reps do not
reliably set stage or disposition. When measuring rep outreach:

- Attribute a call to a rep only when `ActivityFields.CreatedBy` equals the lead's current
  `OwnerId`. Calls by a previous owner are inherited activity, not their work.
- **Exclude EventCode 208 (`AI Phone Call / Follow Up`)** — that is the Callkaro AI dialler, a
  background system, not a person. Counting it inflates coverage.
- EventCode 21 is inbound; count it separately from outbound reach.
- "Connected" = `ActivityFields.mx_Custom_3` (duration in seconds) > 0. Cross-check against
  `Status -eq "Answered"`; they have agreed on every call observed so far and a divergence is
  worth knowing about.

Detail and the standing findings: `memory/10-rep-activity-measurement.md`,
`memory/11-crm-hygiene-findings.md`.

## Working conventions

1. Read `PROJECT_PLAN.md` for current phase before starting; update its headers as work lands.
2. Read the relevant `memory/*.md` before re-deriving a fact via the API — most of the schema
   audit is done, the numbers are real (pulled live, not estimated) and each file is dated.
3. Lead/Contact changes: additive only, flag for human review.
4. `data/` is gitignored but not empty — multi-MB JSON exports, backups and growing logs. Don't
   read them wholesale; grep or sample.
5. Long-running report scripts (10-15 min at current volumes) should run in the background. **If
   the machine sleeps mid-run the output is either silently smeared across two clocks or lost
   entirely** — always check the run's own log timestamps for a gap before trusting a report.
