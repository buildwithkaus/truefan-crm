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
which resolved to *different* GUIDs (`f54d7816-...` vs `a814c42c-...`). Worth a manual
check on whether this is the same person with two LSQ accounts (data hygiene issue) or
two different people — not resolved as of this writing.

Full list with lead/company counts: `data/departed_owner_ids.json` and the reassignment
log (gitignored, real data).
