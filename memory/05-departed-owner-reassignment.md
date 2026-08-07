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
5. Script: `scripts/archive/reassign-departed-owners.ps1`. Run started 2026-07-27,
   logs to `data/reassignment_log.txt` (gitignored).

## Status

Check `data/reassignment_log.txt` for the run outcome (success/fail counts per batch,
final totals). If this file says the run is incomplete or shows failures, re-run the
script — it's idempotent (setting OwnerId to Admin again on an already-reassigned record
is harmless).

As of 2026-07-27 15:42: Leads fully succeeded (20,837/20,837). Companies still in
progress — see the incident below for why the log initially looked like 100% Company
failure, and why that was a false signal.

## Incident: two concurrent script instances, one running permanently-stale code (2026-07-27)

The first run (started 14:46, hit the em-dash parse bug from `CLAUDE.md`) was killed and
`common.ps1` was fixed, then a second run was started (15:18) — **without confirming the
first process had actually exited**. It hadn't: the first `powershell.exe` process (PID
19236) was still alive, still looping through `Reassign-Companies`, using the *original
broken* `common.ps1` it had dot-sourced into memory at 14:46 — a running process does not
pick up edits to a dot-sourced file, so it kept producing the malformed-URL client-side
exception (blank `$_.ErrorDetails.Message`) forever, on every single record, with no
network round-trip (which is why it looked like it was processing hundreds of records in
minutes despite the 400ms pacing — the calls were failing before they ever left the
machine).

This produced a **false 100% Company-failure signal** in the shared log: the log looked
like the fixed code still didn't work, when the entries were actually all coming from a
zombie process nobody had confirmed was dead. The second (correct) process's Lead phase
was running concurrently and succeeding the whole time — its Company-phase entries just
hadn't started appearing yet, so at a glance the log read as "Companies broken, Leads
fine," which was misleading.

Confirmed via `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"` (command
line, not just process name — several unrelated `powershell.exe` processes exist for IDE
tooling). Killed PID 19236. Left the legitimate run (PID 27048) alone. A single-record
smoke test + independent re-fetch (per the project's standard verification method)
confirmed `Company.Update` works correctly once only the correct process is running.

**Lesson for next time**: after fixing a bug in a script that's mid-run, don't just start
a new run — **confirm the old process actually exited** (`Get-CimInstance Win32_Process`
filtered by command line, not just `Get-Process` by name) before trusting any log output
from that point forward. A "100% failure" signal in a shared append-only log can mean "the
fix didn't work" or it can mean "a stale process nobody killed is still writing to this
file" — check for the latter before assuming the former.

## Incident: an active rep (Rishi Saraswat) was wrongly in the "30 departed owners" list (2026-07-27)

**Rishi Saraswat — one of the 18 active reps (`04-active-rep-roster.md`) — was mistakenly
included in the original 30-name departed-owner list** that this whole migration was built
from. That list-building step predates this session; the error was carried in, not
introduced by the reassignment script itself. Result: **2,360 of his Leads** had `OwnerId`
set to Admin during the Phase 2 Lead reassignment run. Caught because the rep reported a
live "Follow Up" contact of his had disappeared to Admin.

**Scope check performed**: cross-referenced all 30 departed-owner names against the 18
active-rep names in `04-active-rep-roster.md` — **Rishi Saraswat is the only exact-name
overlap.** Zero of his Companies were affected (0 entries under his name in
`departed_owner_companies_BACKUP.json`) — this was Leads-only.

**Fix applied and verified**: `scripts/archive/rollback-rishi-leads.ps1` restored
`OwnerId` to Rishi's real GUID (`f033a0b3-1dd5-11f1-bd10-0a70299d455d`) for all 2,360
leads, sourced directly from `OrigOwnerId`/`OrigOwnerName` already captured in the Phase 2
backup — not a guess. Result: 2,360/2,360 succeeded, 0 failures
(`data/rollback-rishi_log.txt`). Verified via a random 10-record sample re-fetch plus a
live `OwnerId`-filtered count, both confirming Rishi as current owner.

**Update — the real root cause was a GUID mislabeling, and it *did* also affect
Companies.** A first name-only cross-check said "0 Companies affected," which was wrong.
The actual bug: `data/departed_owner_ids.json` (and the Company backup built from it) has
the entry `"Piyush Das Pattnaik": "f033a0b3-1dd5-11f1-bd10-0a70299d455d"` — but that GUID
is Rishi Saraswat's real `OwnerId`. Whoever built the original departed-owner reference
data attached the wrong GUID to Piyush's name. Consequence: **1,868 Companies** (all of
"Piyush's" documented company count) actually carry Rishi's real GUID as `OrigOwnerId` in
`departed_owner_companies_BACKUP.json`, and would have been reassigned to him-losing-them
too had the Company run not been paused. Cross-checked live Admin-owned CompanyIds against
these 1,868 at the moment of discovery: **0 had been touched yet** — the paused run hadn't
reached them. Confirmed via `Get-CimInstance`/API, not assumption.

**Full verification performed** (three independent methods, all agree): (1) name-text
cross-check of all 30 departed names against the 18 active reps, (2) GUID cross-check of
`departed_owner_ids.json`'s 30 GUIDs against the 18 active reps' real GUIDs (resolved live
via lead search), (3) GUID cross-check of the *actual* `OrigOwnerId` values inside both
`departed_owner_leads_BACKUP.json` and `departed_owner_companies_BACKUP.json` against the
18 active reps. **All three agree: the Rishi/Piyush GUID mislabeling is the only overlap,
in both files. No other active rep was affected.**

**Side effect**: since "Piyush Das Pattnaik" was actually Rishi's GUID this whole time, the
real Piyush Das Pattnaik (if he's a genuine departed rep) has **zero** leads or companies
correctly captured anywhere in this migration — he's missing, not damaged. A future pass
would need his real `OwnerId` (not currently known) to complete his reassignment.

**Remediation**:
- Leads: `scripts/archive/rollback-rishi-leads.ps1` restored all 2,360 of Rishi's
  leads to his real `OwnerId`. 2,360/2,360 succeeded, verified via sample re-fetch + a
  live `OwnerId`-filtered count.
- Companies: built `data/departed_owner_companies_BACKUP_corrected.json` (the original
  10,972-row backup minus the 1,868 rows with `OrigOwnerId` == Rishi's GUID → 9,104 rows).
  `scripts/archive/resume-company-reassignment.ps1` resumes from this corrected file,
  skipping any company already confirmed Admin-owned (from the ~3,854 processed before the
  pause) — Leads are **not** re-run by this script, since the original
  `reassign-departed-owners.ps1`'s Lead path would silently undo the rollback if re-run
  from the uncorrected leads backup.

**Process lesson**: a "0 affected" conclusion from a single name-text cross-check was
wrong and nearly missed real exposure (1,868 companies). The reliable check is a direct
GUID comparison against the *actual* backup files being written from, not the
intermediate name-mapping reference file, and not names alone — GUIDs are the only
identity that's actually load-bearing for these writes.

**Process note**: the Company reassignment (Phase 2, Companies side) was paused mid-run
(at 3,800/10,972) the moment this was reported, purely as a precaution while the Rishi
scope was being investigated. In hindsight this was the right call for a different reason
than first assumed — it prevented the 1,868 mislabeled companies from being hit before the
corrected worklist could exclude them.
