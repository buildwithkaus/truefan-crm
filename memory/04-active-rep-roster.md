# Active rep roster (confirmed by Kaustubh, 2026-07-27)

18 active reps. LSQ `OwnerIdName` doesn't always match the name Kaustubh used verbatim —
mapped by process of elimination against the full owner list pulled from live data:

| Given name | Matched LSQ OwnerIdName |
|---|---|
| Shriyanka Gupta | Shriyanka Gupta |
| Adarsh Pandey | adarsh pandey |
| Mayank Arora | Mayank Arora |
| Nikhil Sharma | Nikhil Sharma |
| Prakhar Gupta | Prakhar Gupta |
| Rahul Madaan | Rahul Madaan |
| Vikhyat Verma | Vikhyat Verma |
| Neha Advani | Neha Advani |
| Arjun Rathi | Arjun Rathi |
| Saurabh Sharma | Saurabh Sharma |
| Abhishek Tripathi | Abhishek Tripathi |
| Ashutosh | Ashutosh Ojha |
| Rishi | Rishi Saraswat |
| Shubham Kumar Tak | Subham Tak |
| Irfan Md | Irfan Mahmood |
| Kartikey | Kartikey Mishra |
| Anchal | Anchal Awasthi |
| Twinkle | Twinkle Sutrakar |

The fuzzy-matched rows (bottom 7) were not explicitly re-confirmed name-by-name after
mapping — if training/SOP rollout needs 100% certainty on identity, double check against
LSQ's user list before using this table for anything user-facing.

## Departed owners (reassigned to Admin, 2026-07-27 — see `05-departed-owner-reassignment.md`)

30 names, all resolved to distinct LSQ OwnerId GUIDs (confirmed genuinely different user
accounts, not display-name duplicates) — except **Havishma Haranath** and **Havishma H**,
which resolved to *different* GUIDs (`f54d7816-...` vs `a814c42c-...`). **Resolved
(Kaustubh, 2026-07-27): same person, two LSQ accounts** — a data-hygiene duplicate, not
two people. Both accounts were already in the departed-owner reassignment scope, so both
sets of Leads/Companies correctly moved to Admin; no separate fix needed for Phase 2. Flag
for a future account-merge cleanup pass (not currently scheduled in `PROJECT_PLAN.md`) so
the duplicate account doesn't confuse rep-count or activity reporting later.

Full list with lead/company counts: `data/departed_owner_ids.json` and the reassignment
log (gitignored, real data).

**Incident 2026-07-27**: the departed-owner reference data attached the name "Piyush Das
Pattnaik" to **Rishi Saraswat's** real `OwnerId` GUID (`f033a0b3-1dd5-11f1-bd10-0a70299d455d`)
— he's on the active roster above. Consequence: 2,360 of his Leads *and* 1,868 Companies
(mislabeled as Piyush's) were caught in the Phase 2 migration scope. Leads were reassigned
and have since been rolled back; the 1,868 Companies were caught before being touched (the
Company run was paused first). See `05-departed-owner-reassignment.md` for the full
incident and remediation.

**Verification performed**: this was checked three independent ways — name-text
cross-check, GUID cross-check of the reference file, and GUID cross-check of the actual
`OrigOwnerId` values in both backup files — against all 18 active reps' real GUIDs
(resolved live via lead search, not assumed from display names). All three agree: this
Rishi/Piyush mismatch is the only overlap. No other active rep was affected.
