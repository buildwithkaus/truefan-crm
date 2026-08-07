# TrueFan CRM — LeadSquared working repo

Restructuring and running TrueFan's LeadSquared CRM: the Company/Opportunity object model, the
Lead lifecycle stage taxonomy, the recurring rep-activity and pipeline reporting, and the SOP so
reps work an account-based pipeline instead of personal spreadsheets.

**Start here:** [`CLAUDE.md`](./CLAUDE.md) for orientation, layout and hard rules ·
[`PROJECT_PLAN.md`](./PROJECT_PLAN.md) for phases and current status ·
[`docs/LSQ_API_GOTCHAS.md`](./docs/LSQ_API_GOTCHAS.md) before writing any new script.

## Setup

```powershell
Copy-Item config\.env.example config\.env
# fill in LSQ_ACCESS_KEY / LSQ_SECRET_KEY in config\.env - it's gitignored
```

Nothing else to install. PowerShell only — no package.json, no build step, no CI.

## Layout

| Path | What's in it |
|---|---|
| `scripts/lib/` | `common.ps1` (auth, request helpers, every API workaround) and `schema.ps1` (stage taxonomy). Dot-sourced by everything. |
| `scripts/reports/` | **Recurring read-only reporting.** The day-to-day tools. Safe to re-run any time. |
| `scripts/migration/` | The one-time 2026-07-30/31 stage restructure. Complete. Kept for audit trail and rollback. |
| `scripts/sync/` | Stage-sync engine, its rules, and tests. |
| `scripts/archive/` | Completed one-off remediations — enrichment, backfills, owner reassignments. Reference only; not re-run. |
| `docs/` | SOP, LSQ automation spec, capability probes, API gotchas. |
| `memory/` | Numbered findings and decisions, each self-contained with sourcing and dates. |
| `data/` | Gitignored. Real CRM exports, backups, report output, logs. |

## The reports

All read-only against the CRM. Run from the repo root.

```powershell
pwsh ./scripts/reports/<name>.ps1
```

| Script | What it answers |
|---|---|
| `icp-rep-compliance.ps1` | Per rep, for every assigned contact: was it called, did it connect, and is the record filled in (disposition, stage, disqualification reason, note). The main rep-accountability report. |
| `daily-calling-report.ps1` | Per rep for one day: dials, connects, contacts moved to Prospect, opportunities moved to In Discussion, split by cold-call vs FB Leads. |
| `smb-calling-scorecard.ps1` | Monthly calling/prospect targets, month-to-date progress, run-rate required, by team — in the layout SalesOps circulates. |
| `calls-for-day.ps1` | Native outbound call activity for one calendar day, per rep. |
| `icp-source-audit.ps1` | Owner / stage / disposition breakdown for one Source value. |
| `distribution-by-owner.ps1` | Stage, disposition, source and disqualification-reason pivots by owner. Raw, uninterpreted. |
| `export-distribution-xlsx.ps1` | The same distribution written to a fixed-path Excel workbook that overwrites each run. |
| `full-account-audit.ps1` | One-pass audit across Contact, Company and Opportunity stages plus dropdown selectability and ownership. |
| `rep-activity-audit.ps1` | Whether the activity trail actually backs up what the Call Disposition field claims. |
| `enumerate-lead-field-values.ps1` | The safe way to learn what a Lead field really contains. Paginates everything and reconciles to the total. |
| `verify-dropdown-coverage.ps1` | Checks stored values against live dropdown options for all six Lead dropdowns. **Run after anything that writes a dropdown field.** |

Reports write a timestamped JSON snapshot, a Markdown summary and (where useful) a per-contact
CSV into `data/`, plus an append-only log.

## Non-negotiables

Read the full list in [`CLAUDE.md`](./CLAUDE.md). The three that bite hardest:

- **Negative-control every new filter** — LSQ returns plausible wrong answers, not errors.
- **Never hand-write dropdown value strings** — enumerate them from live data.
- **One record, re-fetch to verify, then scale** — a "Success" response body proves nothing.
