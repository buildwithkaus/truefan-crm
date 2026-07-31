# TrueFan CRM — Pipeline & Funnel Fix

## What this project is

TrueFan (truefan.ai) sells celebrity-fronted brand content (video/photo/social) to
businesses, plus an emerging "AI for Business" product line, through an outbound sales
motion run on LeadSquared CRM. This repo is the working codebase for restructuring that
CRM: activating the Company and Opportunity objects, fixing the Lead lifecycle/stage
taxonomy, and shipping an SOP + training so reps actually follow the new model.

Read `PROJECT_PLAN.md` first — it has the phased plan and status. This file is
orientation + hard-won gotchas; `memory/` has the detailed findings behind every decision.

## Business context you need before touching anything here

- Sales motion: reps are full-cycle owners of an account (hunt → close → manage) for a
  contract that runs 1 month to 1 year. Not a single-touch close.
- Two prior plans this work descends from (not in this repo, referenced for context):
  "New SMB Outreach Model" (contact-level → account-level outreach, TAL/ICP tiering) and
  "Pipeline Centralization in LSQ" (replacing rep-maintained sheets with native LSQ
  pipeline tracking). Both authored by Kaustubh Chauhan (Founder's Office), reviewed with
  Mehak Dhar.
- ICP/TAL: a GTM engineer is building the Target Account List from ICP rules already
  handed to him. Most target companies already exist in LSQ — the work here is enriching
  them, not sourcing net-new.
- **Contacts (Lead object) is a live production system reps use every day.** Any change
  there must be additive-first — do not repurpose or remove a field/picklist value reps
  currently depend on without a migration path. Company and Opportunity objects are fair
  game for redesign — Company is 5 days old (not yet load-bearing), Opportunity has zero
  Types configured (greenfield).

## Object model

```
Company (Account)  →  Lead(s)/Contact(s)  →  Opportunity  →  Activity
```

- **Opportunities attach to a Lead, not to a Company directly.** A Company only reaches
  its Opportunities transitively, through the Leads under it. Rule adopted: only the Lead
  flagged `IsPrimaryContact = true` is allowed to own an Opportunity for that Company —
  otherwise multiple contacts at one company fragment into multiple "deals."
- Company/Opportunity: full design liberty. Lead: additive changes only, see above.

See `memory/03-object-model-and-relationships.md` for the full detail and sourcing.

## Critical API gotcha — read before writing any new script

**`LeadManagement.svc/Leads.Get` silently ignores a `Query` wrapper** (`Query.FilterBy`,
`Query.DateRange`) — it returns *unfiltered* results with no error, sorted by whatever
`Sorting` you passed. This cost real time on 2026-07-27: an entire "leads active in the
last 2 months" analysis was accidentally run against the whole historical database because
the filter silently no-op'd.

The correct shape for `Leads.Get` is a **singular `Parameter` object**:
```json
{ "Parameter": { "LookupName": "...", "LookupValue": "...", "SqlOperator": "=" } }
```
`CompanyManagement.svc/Company.Get` DOES use the `Query` wrapper correctly — `Query.FilterBy`,
`Query.CompanyType`, `Query.SearchText`, `Query.DateRange` are all verified working there.
These are two different underlying APIs with different contracts — don't assume a pattern
that works on one applies to the other.

**Rule going forward: before trusting any new filter combination, run a negative-control
test** (a value that should return zero rows) and confirm it actually returns zero — not
just that the "positive" case looks plausible. Before any write/update at scale, verify on
one record with an independent re-fetch, not just a "Success" response body (see
`scripts/leadsquared/reassign-departed-owners.ps1` for the pattern).

**Corollary — enumerate values, never probe a guessed list.** A filter that returns **zero
rows is a result you must distrust as much as a suspicious non-zero one.** On 2026-07-28 the
Phase 5 backfill was found to have probed `ProspectStage = "Invalid/Junk"` and
`"Just Enquiring No Intent"`, received 0 rows for both, and logged that as fact. The real
stored strings are `Invalid/ Junk` (space after the slash) and `Just Enquiring, No Intent`
(comma) — **20,076 leads silently skipped**, ~23% of the database, discovered only because a
separate full enumeration failed to reconcile to the known total. Three further dropdown
values were not in the documented list at all. **The only trustworthy way to learn a
dropdown's contents is to paginate every record, tally the actual stored values, and confirm
the tally reconciles to the total record count.** Hand-written string literals in a migration
script are a bug waiting to happen — generate the worklist from live data instead. Full
detail: `memory/01-lead-schema-audit.md`.

**Second gotcha, discovered the expensive way on the same day**: a PowerShell 5.1 script
with an em-dash (or other non-ASCII punctuation) inside a double-quoted string literal can
throw a cascading parse error that silently breaks everything *after* it in the file,
while the script still partially executes — variables that should have come from a broken
function just end up empty/null instead of the script failing outright. This produced a
malformed URL (`accessKey=&secretKey=`, no host) which threw `System.UriFormatException`
on every call — a **client-side** exception, so `$_.ErrorDetails.Message` (which only
exists on HTTP-response exceptions) came back blank every time, making a 100%-failure run
look like an unlabeled mystery instead of an obvious bug. Cost a full end-to-end 31,809-record
run before it was caught. Lessons adopted:
- Stick to plain ASCII punctuation (`-` not `—`, `'` not `'`) in any `.ps1` file.
- **Smoke-test a wrapper script standalone** (dot-source it, call one function, print the
  result) before trusting it for a bulk/background run — verifying the underlying API call
  works interactively is not the same as verifying the script that wraps it actually parses.
- In a catch block, log `$_.Exception.Message` (always present) alongside
  `$_.ErrorDetails.Message` (only present for HTTP errors) — logging only the latter is why
  this failure mode produced blank error messages instead of a clear signal.

**Third gotcha**: if you kill/fix a mid-run script and restart it, **confirm the old
process actually exited** before trusting any subsequent log output. A dot-sourced file
(`. "$PSScriptRoot\common.ps1"`) is read once at process start — a running process does
not pick up edits to it. A stale process left alive after a "fix and restart" will keep
running on the old broken code forever, writing failures to the same shared log file
alongside the new (correct) run, making a fixed bug look unfixed. Check with
`Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Select CommandLine` (not
just `Get-Process` by name — several unrelated `powershell.exe` processes exist for IDE
tooling) and kill anything still running the old script before believing a "100% failure"
signal in the log. Full incident write-up: `memory/05-departed-owner-reassignment.md`.

**Fourth gotcha**: `Invoke-RestMethod -Body <string> -ContentType "application/json"` (no
charset) in Windows PowerShell 5.1 does not reliably send UTF-8 bytes on the wire. Any
non-ASCII character in a value you're writing (accented letters, °, ®, etc. — common in
real `CompanyName` values) gets mis-encoded into a single byte the server's UTF-8 JSON
parser can't decode, producing a genuine `400 Bad Request` (`"Unexpected character
encountered while parsing value"`) — not a transient/retryable error, every retry fails the
same way until the encoding is fixed. Hit during the Phase 3 Opportunity backfill (4 of
4,404 companies: `360°Career Institute`, `Étiicos`, `BodyCafé`, `SHAFAQUE ®`). Fix: convert
the JSON string to explicit UTF-8 bytes and set `charset=utf-8` on Content-Type before
sending:
```powershell
$bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
Invoke-RestMethod -Uri $uri -Method Post -Body $bytes -ContentType "application/json; charset=utf-8"
```
Any script that writes free-text fields sourced from real company/lead data should use this
pattern, not the plain string-body form.

**Fifth gotcha — timestamps are UTC, this account is IST.** `ModifiedOn`, `CreatedOn` and
`ProspectActivityDate_Max` are all stored and returned in **UTC**, while the account operates
in IST (UTC+5:30). A filter timestamp built from local `Get-Date` is therefore 5.5 hours in
the *future* and matches **zero rows, forever** — a polling/watermark job built on it looks
healthy and does nothing at all. Proven live 2026-07-28:
```
UTC-correct    ModifiedOn > 2026-07-28 08:08:44  ->  352 rows
local (wrong)  ModifiedOn > 2026-07-28 13:38:44  ->    0 rows
```
Use `Get-LsqTimestamp` in `common.ps1` for every timestamp sent to the API; never format one
by hand. Same silent-zero failure family as the `Invalid/ Junk` bug above.

**Sixth gotcha — boolean-ish fields use three different conventions.** For `IsPrimaryContact`
(and probably other bit fields): **reading** returns the *string* `"1"`/`"0"` (not a boolean,
not `"true"`), **filtering** requires `LookupValue="1"` — passing `"true"` returns **HTTP
500** — and **writing** accepts `"true"`. Comparing a read value against `$true` or `"true"`
is False for every record, which silently makes every primary contact look non-primary. This
was a real bug in this repo's own migration code, caught on 2026-07-28 before it ran: it would
have let a second Opportunity attach to a different contact at an account that already had
one. Use `Test-LsqTrue` in `common.ps1` for reads.

**Seventh gotcha — `CompanyManagement.svc/Company.Update` requires the property array wrapped
in a `CompanyProperties` key; a bare array is rejected.** `[{"Attribute":"Stage","Value":"X"}]`
returns `MXInvalidDataTypeException: "You're missing Company details."` on **every** call,
including writing a company's own pre-existing value back to itself — the error looks like a
dropdown/data problem but is actually a body-shape problem. The correct shape is
`{"CompanyProperties":[{"Attribute":"Stage","Value":"X"}]}`. `apply-company-enrichment.ps1`
and `reassign-departed-owners.ps1` had this right (both ran live successfully); found
2026-07-29 because `05-migrate-companies.ps1`, `08-rollback.ps1`, and `sync-engine.ps1` all had
it wrong — the bare-array form was never caught because none of those three had been run
against production yet. Would have failed the entire company-writing leg of the migration
*and* the rollback safety net at the same time. All three fixed and the fixed shape live-tested
(write + independent re-fetch) before trusting it.

**Eighth gotcha - a paginated page can arrive nested one level deeper, and `.Count` then reads
`1`.** `Invoke-RestMethod` intermittently returns a `Leads.Get` page as `Object[1]` wrapping the
real `Object[1000]` instead of a flat array, for byte-identical requests. Every paginating loop
in this repo is shaped `if ($resp.Count -lt 1000) { break }`, so the nested shape reads "1 record,
fewer than PageSize, stop" and the script reports a **complete scan of the whole account after one
page**. It is decided **per-process**: a process that gets the nested shape gets it on *every*
call, and a process that gets the flat shape never sees it. That per-process stickiness is what
makes it so misleading - isolated health-check scripts pass 40/40 while the real script fails
identically every run, which reads exactly like an intermittent account/API outage. It was
misdiagnosed as one (a real billing-related access restriction had occurred separately, which
made the wrong explanation fit). Diagnosed 2026-07-29 by noticing that a "1-row" response held a
field whose value stringified to ~1000 space-separated values - the data was always there, only
the shape was wrong. Fix: `Expand-LsqRows` in `common.ps1` normalizes both shapes; wrap every page
fetch in it. Note `return $out.ToArray()` there deliberately has **no** leading comma - `return ,
$arr` would suppress unrolling and make `@(Expand-LsqRows ...)` read `1` again, reintroducing the
exact bug. Applied to `02-build-worklist`, `03-backup`, `06b`, `07-verify`, `08-rollback`; the
`sync/` and `build-*` scripts still need it.

**Corollary - an internal-consistency check is not a reconciliation.** `02-build-worklist.ps1`
verified `$sum -eq $total` and logged "Reconciliation OK", which a truncated scan passes trivially
(`1 == 1`). A guard must compare against an **absolute expected size** from an independent source
(memory/01: 86,628 leads), not against another number derived from the same bad read. Absolute
guards are now in `02-build-worklist` (worklist), `03-backup` (refuses to write a partial backup -
it is the only thing `08-rollback` can restore from) and `08-rollback` (refuses to compute a delta
from a short read).

**Ninth gotcha - LSQ stores a dropdown value that is not in the dropdown instead of rejecting
it.** Writing `mx_Disqualification_Reason = "Invalid / Not a Business"` succeeds even when that
string is not one of the field's options, and reading it back returns it correctly - so every
verification this repo does would pass. But the value is not selectable by a rep and a dropdown
filter will never offer it, which makes the records **invisible to the people the field exists
for**. Nothing in a write log reveals it. Hit twice on 2026-07-31 - Call Disposition (3 plan names
that were never options) and Disqualification Reason (**9 options vs 12 stored values, zero
overlap, 61,919 leads unfilterable**) - and **both were found by Kaustubh trying to filter, not by
any check here.** Verifying a value is *correct* is not verifying it is *selectable*. Run
`16-verify-dropdown-coverage.ps1` (checks all six Lead dropdowns at once) after anything that
writes a dropdown field; checking one field by hand is how the second instance survived the fix
for the first. Note the repair is not always "fix the data" - if the existing option list cannot
express the new values, extend the dropdown instead. `CreateLeadField` rejects option values
containing `(`, `)`, `/`, `-`, `'` or `,` ("Only alphanumeric characters, space, underscore is
allowed"), so punctuated options must be added in the UI.

**Tenth gotcha - native LSQ automations do not appear to fire on API/bulk writes.** A live
automation (Company `Fresh`->`Nurture` on Contact `Fresh`->`Engaged`) did not react to 17,011
leads moved via `Lead/Bulk/UpdateV2`: the backlog went **5,115 -> 5,111 over 19 minutes**, which
is ordinary rep clicking, not an async queue draining. Treat automations as covering **UI edits
only** until the SPOC confirms otherwise. Two consequences: pair every bulk write with a
reconciler run, and never conclude an automation worked without measuring the backlog before and
after with a delayed re-check - "hasn't fired yet" and "never will" look identical at a glance.

**No bulk Opportunity read endpoint exists.** Probed eight candidate names on 2026-07-28; all
404 except per-lead access (`GetOpportunitiesOfLead?leadId=X&opportunityType=12000`, where
`opportunityType` is **required** despite the docs implying otherwise, and
`ProspectActivity.svc/Retrieve?leadId=X`). Any opportunity-driven job therefore costs one API
call per lead — scope by watermark, never sweep everything. Full list of what was probed:
`docs/AUTOMATION_CAPABILITIES.md`.

Other schema-name gotchas hit while building this:
- Company object: `Include_CSV` column list is picky — omit it and fetch full records
  (`companyPropertyList`) rather than guessing exact field names; the display-name field
  for owner is `OwnerName`, not `OwnerIdName` (that's the Lead-side field name).
- PowerShell 5.1's `ConvertTo-Json` collapses a single-element array into a bare object —
  breaks any API expecting `[{...}]`. Build single-element array bodies as literal strings,
  not via `ConvertTo-Json` on a PS array.

## Running scripts & verifying changes

This is a PowerShell + Markdown project — no package.json, no build step, no linter, no CI.
Nothing to install beyond PowerShell itself.

- **Setup**: `Copy-Item config\.env.example config\.env`, then fill in `LSQ_ACCESS_KEY` /
  `LSQ_SECRET_KEY` in `config\.env` (gitignored). `Import-LsqConfig` in `common.ps1` throws
  a clear error if this file is missing or incomplete.
- **Run a script** from the repo root: `pwsh ./scripts/leadsquared/<script>.ps1`. Scripts
  dot-source shared helpers rather than importing a module: `. "$PSScriptRoot\common.ps1"`.
- **No automated tests exist.** Verification is manual against the live API: change one
  record, then independently re-fetch it to confirm the change actually took (see the
  pattern in `scripts/leadsquared/reassign-departed-owners.ps1`) — a "Success" response body
  alone is not sufficient (see the API gotcha above for why). This is the project's actual
  test methodology; don't assume or add a test framework.
- `data/` is gitignored but not empty locally — it holds real multi-MB JSON exports/backups
  and actively-growing migration logs. Don't read these wholesale; grep/sample as needed.

## Credentials

Real LeadSquared API credentials live in `config/.env` (gitignored). `config/.env.example`
shows the shape. **Never** hardcode credentials in a script that gets committed.

These specific credentials were shared in a chat session before this repo existed — flagged
for rotation to whoever owns the LeadSquared account. Treat as sensitive regardless.

## Directory guide

- `memory/` — numbered findings/decisions, each self-contained with sourcing. This is the
  project's long-term memory — read relevant files before redoing research.
- `scripts/leadsquared/` — reusable, tested API scripts. `common.ps1` has shared
  config-loading + verified request helpers. Prefer extending these over writing new
  inline API calls. `common.ps1` provides `Import-LsqConfig`, `Get-LsqUrl`,
  `Invoke-LsqLeadSearch`, and `Invoke-LsqCompanySearch` — reuse these rather than
  re-implementing auth/request logic.
  `enumerate-lead-field-values.ps1` is the safe way to learn what values a Lead field
  actually holds (paginates everything, tallies real strings, reconciles to the total,
  brackets values so trailing spaces are visible). Use it to generate migration worklists —
  never hand-write field-value strings into a script.
- `data/` — gitignored. Real CRM exports/backups. Never commit; contains business data.
- `docs/` — SOP and training material for reps (once built).

## Working conventions for sub-agents picking up tasks here

1. Read `PROJECT_PLAN.md` for current phase/status before starting anything. Its phase
   headers (`— done`, `— executing`, `— blocked on X`) are the single source of truth for
   project state — update them as work lands.
2. Read the relevant `memory/*.md` file before re-deriving a fact via the API — most of
   the schema audit is already done and numbers are real (pulled from the live account,
   not estimated), dated in each file.
3. Any write operation against the live LeadSquared account: test on one record, verify
   independently via re-fetch, *then* scale up. No exceptions — see the API gotcha above
   for why.
4. Contacts/Lead object changes: additive only, flag for human review before anything that
   touches a field/picklist reps currently use.
5. Log migrations to `data/*_log.txt` (gitignored) so there's an audit trail independent of
   LeadSquared's own history. **Do not `tail -f` one of these logs while the script is
   running** - on Windows the reader holds the file open, every `Add-Content` in `Write-LsqLog`
   then fails with "being used by another process", and the script keeps running with console
   output intact but **no audit trail on disk**. It is a non-terminating error, so the run looks
   fine. To watch progress, read the background task's own output file instead.
