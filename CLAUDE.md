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

Plus: **no bulk Opportunity read endpoint and no bulk Activity read endpoint exist** — both cost
one API call per lead, so always narrow to a candidate set first. **No Notes API exists** either.

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
