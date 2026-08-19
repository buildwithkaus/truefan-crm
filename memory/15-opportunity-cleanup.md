# 15 - Sorting the Opportunity tab (2026-08-14 to 08-19)

What the deal book actually was, what it is now, and the eight API facts this repo had
recorded wrongly. Companion to `PROJECT_PLAN.md` Phase 13.

## The starting state

4,673 opportunities. The warehouse could see 1,498 of them.

That gap was structural, not drift: `fact_opportunity`'s only feeder is `backfill.ps1`, whose
`-DealStagesOnly` mode scopes discovery to contacts **currently** at Prospect or Customer. Deals
on contacts that had drifted off were never ingested at all - so the exact population any
cleanup would target was invisible to every dashboard and every previous count of it.

`v_opportunity_hygiene` reported 62 open deals on disqualified contacts. The real figure, once
the whole book was scanned, was an order of magnitude larger. **Never size this work from the
warehouse.**

## The end state

| | before | after |
|---|---|---|
| Opportunities live | 4,673 | ~614 |
| Rows in `fact_opportunity` | 1,498 | 3,369 then reconciled |
| Open deals with no forecast data | ~2,900 | 0 |
| Deals ever marked Lost | 0 | 1 |

**4,088 net deletions. 105 contacts promoted Engaged -> Prospect. Zero contacts deleted.**

## What was deleted, and on what evidence

1. **Structural, 1,128.** 812 deals whose contact had never reached a deal stage, 200 on
   contacts that reached Prospect and lapsed, 116 duplicate losers.

   "Never reached a deal stage" was **derived, not assumed** - from the EventCode 3002 trail,
   testing both `CurrentStage` and `PreviousStage` against a Prospect-meaning value set built
   from `$Script:StageMap` rather than hand-written. 279 of 1,501 positives were found ONLY via
   `PreviousStage`: the contact's exit from Requirement Gathering (Warm) named the stage its
   entry never recorded. Testing `CurrentStage` alone would have wrongly classed those 279 as
   "never a prospect" and deleted real deal history.

   Zero contacts resolved to UNKNOWN, and `DEAL_EVER_PROSPECT_UNKNOWN` existed as a first-class
   class precisely so a missing log line could never be read as proof of absence.

2. **Forecast-less, 2,960.** Open deals carrying neither Expected Deal Size nor Expected Closure
   Date. Run boxed per rep first (Abhishek 57, Ashutosh 93, Rishi 4) to prove the shape before
   sweeping.

   Never touched: Won, Customer contacts, `Agreement Sent` or beyond, or anything carrying an
   actual deal size, contract date, or agreement/invoice-sent date. Applied literally the rule
   would have deleted all 158 Won deals and demoted 154 paying customers to Engaged.

**Of 732 Prospect deals lacking forecast data, 732 lacked BOTH fields and 0 had only one.** Reps
fill Expected Deal Size and Expected Closure Date together or not at all, which made the
"missing either vs missing both" question moot in practice.

## The promotion, and why deleting would have been wrong

108 deals carried a complete forecast - INR 3.85 crore - on contacts still at Engaged. A
Prospect-scoped forecast could not see any of it. **90 of the 108 belonged to Rahul Madaan**: he
fills the forecast fields properly and never moves the contact stage. That is a coaching
problem, not a data problem.

Deleting them to satisfy "the tab holds Prospect contacts only" would have destroyed the best
forecast data in the account to tidy a stage field. 106 contacts were promoted instead.

## The residue nobody can avoid

Deleting empty deals while contact writes were forbidden did not remove the emptiness - it moved
it. ~800 contacts now sit at Prospect holding nothing, asserting a deal that does not exist.
`08-demote-prospects-without-deal.ps1` moves them to Engaged, excluding Mayank Arora (194) and
adarsh pandey (93) by request.

Its dry run found that **of 900 candidates, 306 actually held a deal** - a third. The scan file
said otherwise. Any "has no deal" test must be re-checked live against BOTH the opportunity
endpoint and the activity trail before it drives a write.

## Eight documented facts that were wrong

| # | Was recorded as | Actually |
|---|---|---|
| 47 | `CanDelete: false`, deletion blocked | Deletion works. The parameter is `Id`, not `opportunityId`, and the wrong name fails silently |
| 45 | `GetOpportunitiesOfLead` returns `Fields[]` | It returns FLAT properties. Five scripts walked `$o.Fields`, so `03-backup.ps1` wrote structurally empty backups with a healthy row count |
| 49 | `LookupName` casing irrelevant | Case-sensitive; `ProspectId` returns zero rows silently. `test-automations-live.ps1` had been asserting against `$null` |
| 48 | `GetOpportunitiesOfLead` authoritative | Index-backed and lags; returns 0 for leads that have deals |
| 46 | Rank table complete | Missing `Requirement Gathering`, so `$null -lt 1` made the warm deal lose every duplicate contest |
| 52 | `sync-engine.ps1` can write a contact stage | It cannot and never could. Its bulk body 400s; the flat shape returns 200 with `SuccessCount: 0` |
| 50 | A wrapper exit code means the work ran | `powershell.exe` from Git Bash is execution-policy blocked and still exits 0 - zero of 1,127 deletes happened |
| 51 | Rate limit comfortable | 25 calls / 5 s, and backup-then-delete is two calls per record |

## Process lessons worth keeping

- **The one-record proof caught real failures three times**: a 400 on the first contact write, a
  bad request shape, and an unproven endpoint. Each aborted before a second record.
- **A gate that logs and returns is not a gate.** `Add-Recon` returned log lines bundled with its
  boolean, so the audit printed "all gates passed" while recording a failure. Gotcha 12, in a
  script written after that gotcha was read.
- **Read-back verification needs to poll.** A one-shot check reported 14 landed contact writes as
  failures, and they went unrecorded in the rollback file until recovered.
- **Check the log's own timestamps.** A scan showed a 9-hour gap where the machine slept; it
  resumed correctly, but nothing in the output announced it.
- **The account rate limit is shared.** A dry run launched alongside a scan throttled both.

## Still open

- ~800 Prospect contacts with no deal (script ready, not run; two owners excluded).
- 2 Disqualified contacts hold a fully forecasted deal - promoting resurrects a written-off
  account, so they were left alone.
- 81 Prospect contacts are not the primary contact for their account, so a deal cannot be created
  without fragmenting it; 13 more have no company name, which `mx_Custom_1` requires.
- 100 Customer contacts have no deal at all.
- **The forecast fields are still not mandatory in the UI.** Nothing stops this refilling with
  empty deals tomorrow. That is Phase 6 and Phase 7, and without them this was a one-off.
