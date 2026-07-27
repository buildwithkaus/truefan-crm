# Departed-owner reassignment to Admin — migration record

**Decision** (Kaustubh, 2026-07-27): everyone not on the 18-person active roster
(`04-active-rep-roster.md`) has left. All their Leads and Companies — including the ones
in genuinely live/working stages — transfer to Admin.

## Scope (all-time, not date-limited — verified via API, not estimated)

- **20,837 Leads** across all 30 departed owners
- **10,972 Companies** across 5 of the 30 (the other 25 already show zero Company
  records — likely already excluded when the Company object was built 2026-07-22):
  Vinamra Manchanda (6,787), Piyush Das Pattnaik (1,868), Chinmaya Kapoor (1,322),
  Lakshay Bhatt (939), Divij Vallecha (56).

Stage breakdown of the 20,837 leads: 95.7% (19,903) dead/terminal, **897 in genuinely
live stages** (Future Prospect 457, SaaS 304, Call me Later 64, Follow Up 41, Fresh Lead
20, + 11 others), 37 historical Payment Received. Flagged to Kaustubh before executing —
confirmed to move all of it to Admin anyway, including the 897 live ones. Admin is
therefore a temporary parking lot for live-but-orphaned deals, not a resolution — **worth
revisiting once the new account-assignment model (Outreach Model plan) is live**, so
those 897 don't just sit dead under a non-working account indefinitely.

## Method

1. Backed up original ownership for every record before any write —
   `data/departed_owner_leads_BACKUP.json` (20,837 rows: Id, OrigOwnerId, OrigOwnerName,
   Stage) and `data/departed_owner_companies_BACKUP.json` (10,972 rows) — both gitignored,
   real data, this is the rollback record if anything needs to be undone.
2. Verified both write mechanisms on a single record each, with an independent re-fetch
   confirming the change (not just trusting a "Success" response), before running at
   scale — see the API gotcha section in `CLAUDE.md` for why this discipline matters here
   specifically.
3. Leads: `LeadManagement.svc/Lead/Bulk/UpdateV2`, 25 records/call, `SearchByKey: ProspectId`.
4. Companies: `CompanyManagement.svc/Company.Update`, single record/call, by `CompanyId`.
   **Did not use** the bulk Company endpoint (`Company/Bulk/CreateOrUpdate`) — it only
   matches existing records by `CompanyName` and is create-*or*-update, so any name
   mismatch (whitespace, near-duplicate) risks silently creating a duplicate company
   instead of updating the intended one. Not worth the risk when exact `CompanyId` was
   already in hand from the backup.
5. Script: `scripts/leadsquared/reassign-departed-owners.ps1`. Run started 2026-07-27,
   logs to `data/reassignment_log.txt` (gitignored).

## Status

Check `data/reassignment_log.txt` for the run outcome (success/fail counts per batch,
final totals). If this file says the run is incomplete or shows failures, re-run the
script — it's idempotent (setting OwnerId to Admin again on an already-reassigned record
is harmless).
