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

Other schema-name gotchas hit while building this:
- Company object: `Include_CSV` column list is picky — omit it and fetch full records
  (`companyPropertyList`) rather than guessing exact field names; the display-name field
  for owner is `OwnerName`, not `OwnerIdName` (that's the Lead-side field name).
- PowerShell 5.1's `ConvertTo-Json` collapses a single-element array into a bare object —
  breaks any API expecting `[{...}]`. Build single-element array bodies as literal strings,
  not via `ConvertTo-Json` on a PS array.

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
  inline API calls.
- `data/` — gitignored. Real CRM exports/backups. Never commit; contains business data.
- `docs/` — SOP and training material for reps (once built).

## Working conventions for sub-agents picking up tasks here

1. Read `PROJECT_PLAN.md` for current phase/status before starting anything.
2. Read the relevant `memory/*.md` file before re-deriving a fact via the API — most of
   the schema audit is already done and numbers are real (pulled from the live account,
   not estimated), dated in each file.
3. Any write operation against the live LeadSquared account: test on one record, verify
   independently via re-fetch, *then* scale up. No exceptions — see the API gotcha above
   for why.
4. Contacts/Lead object changes: additive only, flag for human review before anything that
   touches a field/picklist reps currently use.
5. Log migrations to `data/*_log.txt` (gitignored) so there's an audit trail independent of
   LeadSquared's own history.
