# 09 — ICP assignment programme

*Written 2026-08-08. Numbers pulled live via `scripts/reports/icp-rep-compliance.ps1`; each run
writes a timestamped JSON + Markdown + CSV into `data/icp_rep_compliance_*`.*

## What it is

Kaustubh assigns target-account contacts to reps in blocks. The population is identified by a
single Lead field:

```
Source = "Kaustubh ICP"        (exact stored string, enumerated live 2026-08-04 - not guessed)
```

Contacts sit under Kaustubh Chauhan as the **holding owner** until assigned; ownership moving to
anyone else *is* the assignment. `icp-rep-compliance.ps1` derives the rep set from live ownership
rather than a hardcoded name list, so newly-added reps appear automatically.

The expectation on a rep, per assigned contact:

1. Place an outbound call.
2. For every **connected** call, record Call Disposition.
3. Move Contact Stage off Fresh once worked.
4. If disqualifying, record a Disqualification Reason.
5. Leave a note.

## Population and ownership, first four days

| Date | Source pool | Assigned | Owners |
|---|---|---|---|
| 2026-08-04 | 4,135 | 600 | 3 |
| 2026-08-05 | 4,096 | 971 | 5 |
| 2026-08-06 | 4,283 | 1,320 | 10 |
| 2026-08-07 | 4,301 | 1,714 | 10 |

Owners seen: Abhishek Tripathi, Ashutosh Ojha, Rishi Saraswat, Subham Tak, Kartikey Mishra, then
Neha Advani, Twinkle Sutrakar, Nikhil Sharma, Saurabh Sharma, Vikhyat Verma, Arjun Rathi.

**The pool and the assignment both move constantly.** Between two runs an hour apart, contacts
have changed owner, left the Source entirely, and been parked with `Admin`. Do not treat a
per-rep delta as rep behaviour without checking the assigned count first — on 2026-08-06 a
"−19 called" for Kartikey was purely 19 contacts being reassigned to Admin, not a regression.
The report prints the assigned-count delta alongside the called delta for exactly this reason.

## Trajectory (2026-08-07 18:12, latest full run)

| Rep | Assigned | Called | Coverage | Connected | Talk time | Stage-update discipline |
|---|---|---|---|---|---|---|
| Kartikey Mishra | 149 | 142 | 95.3% | 52 | 66.5 min | 96% |
| Rishi Saraswat | 199 | 182 | 91.5% | 96 | 88.8 min | 94% |
| Ashutosh Ojha | 449 | 407 | 90.6% | 212 | 227.7 min | **43%** |
| Subham Tak | 256 | 177 | 69.1% | 105 | 100.1 min | 67% |
| Twinkle Sutrakar | 104 | 59 | 56.7% | 23 | 26.8 min | **14%** |
| Abhishek Tripathi | 446 | 246 | 55.2% | 139 | 302.5 min | 94% |
| Neha Advani | 106 | 9 | 8.5% | 7 | 7.7 min | 100% |
| **Total** | **1,714** | **1,224** | **71.4%** | **635** | **822 min** | **69%** |

## Standing per-rep patterns

These held across every run 08-04 → 08-07 and are the useful signal, more than any single day:

- **Abhishek Tripathi** is the quality benchmark. Longest connects by a wide margin (~140-165s
  average vs ~55-65s for everyone else), 93-94% discipline sustained, disposition mix that looks
  like real outcomes. Lower coverage, but his records are the only ones another person could pick
  up and use.
- **Ashutosh Ojha** is the volume leader and the compliance floor, consistently. He runs the
  highest coverage and the lowest discipline (8-52% depending on the day), and his connects are
  distinctively short — roughly half peak at ≤30 seconds, every single run, at rising volume.
  That ratio is stable enough to be a dialling pattern rather than noise; worth listening to
  recordings before treating his connect rate as comparable to the others'.
- **Rishi Saraswat** has excellent stage discipline (84-94%) and ignores Disqualification Reason
  entirely (27 blank, unmoved across four consecutive runs). Also went fully idle for ~20 hours
  on 08-05/06 while otherwise performing well — worth checking availability rather than
  assuming a pace problem.
- **Kartikey Mishra** cleans up in batches. Discipline swung 19% → 74% → 56% → 93% → 96% as he
  alternated between calling and reconciling. Also had two consecutive zero-call days.
- **Subham Tak** and **Twinkle Sutrakar** are the two to coach next — Subham for sustained low
  discipline (34-67%), Twinkle because she started on 08-07 with 59 calls on day one at 14%
  discipline, and habits are cheaper to set than to correct.

## How to re-run

```powershell
pwsh ./scripts/reports/icp-rep-compliance.ps1
```

~13-15 min at 1,700 contacts (one API call per assigned contact — there is no bulk Activity
read). Run it in the background and **check the log timestamps for a gap before trusting the
output**: if the machine sleeps mid-run, the Lead fields are read at the start and the activity
trails at the end, producing a report that silently mixes two clocks. This happened twice
(2026-08-05 and 08-07); once it smeared, once the process was killed and produced nothing.

Related: `[[10-rep-activity-measurement]]` for the methodology,
`[[11-crm-hygiene-findings]]` for what the data keeps showing.
