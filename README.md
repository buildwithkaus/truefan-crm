# TrueFan CRM — Pipeline & Funnel Fix

Restructuring TrueFan's LeadSquared CRM: activating Company and Opportunity objects,
fixing the Lead lifecycle/stage taxonomy, and shipping an SOP so reps can actually work
an account-based pipeline instead of maintaining personal spreadsheets.

**Start here:** [`CLAUDE.md`](./CLAUDE.md) for orientation and hard-won API gotchas,
[`PROJECT_PLAN.md`](./PROJECT_PLAN.md) for phases and current status.

## Setup

```powershell
Copy-Item config\.env.example config\.env
# fill in real LSQ_ACCESS_KEY / LSQ_SECRET_KEY in config\.env — it's gitignored
```

## Layout

- `memory/` — numbered findings and decisions from the schema audit and migrations, each
  self-contained with sourcing and dates.
- `scripts/leadsquared/` — reusable API scripts. `common.ps1` has shared config-loading
  and request helpers with the known API gotchas baked in.
- `data/` — gitignored. Real CRM exports and migration logs.
- `docs/` — SOP and training material for reps (once built, Phase 7).
