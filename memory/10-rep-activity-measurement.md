# 10 — How to measure rep activity (methodology)

*Written 2026-08-08. Derived while building `scripts/reports/icp-rep-compliance.ps1`,
`daily-calling-report.ps1` and `calls-for-day.ps1`. All facts verified live.*

## The core principle

**Do not measure rep work from CRM field values.** Reps demonstrably do not reliably set Contact
Stage or Call Disposition — across four days of measurement, stage-update discipline ranged from
8% to 96% by rep. Field values therefore both *understate* work (a rep who called 197 contacts
and updated 16) and *misattribute* it (dispositions inherited from a previous owner's calls).

The source of truth for "did a rep reach out" is the **native telephony log**. The CRM fields are
then measured *against* it, and the gap between the two is the actual finding.

## Where the signals live

| Signal | Source |
|---|---|
| Outbound call placed | Activity `EventCode 22` — "Outbound Phone Call Activity", auto-created by the telephony integration whenever a call is placed through the system |
| Who placed it | `ActivityFields.CreatedBy` (a user GUID) |
| When | `CreatedOn` (**UTC** — see gotcha 6) |
| Duration | `ActivityFields.mx_Custom_3`, seconds |
| Outcome | `ActivityFields.Status` — `Answered` / `NotAnswered` |
| Stage changed | Activity `EventCode 3002` ("StageChange"), `CreatedOn` only — its ActivityFields are empty, so old→new is not available |
| Contact stage / disposition / reason | Lead fields `ProspectStage`, `mx_Call_Disposition`, `mx_Disqualification_Reason` |

`ActivityFields.mx_Custom_3` was confirmed as call duration on 2026-08-03 by cross-checking
against the duration embedded in `ActivityEvent_Note` across 116 real calls — exact match every
time.

## Attribution rules

1. **Credit a call to a rep only when `CreatedBy` == the lead's current `OwnerId`.** Contacts get
   reassigned constantly; without this, a rep inherits a previous owner's activity. Count calls by
   others separately as context.
2. **Exclude `EventCode 208` ("AI Phone Call / Follow Up") entirely.** That is the Callkaro AI
   dialler — a background system, not a person. It appeared on 40 of 971 assigned contacts, and
   14 of those had *no* rep call at all, so including it would have manufactured coverage that
   nobody worked. See `[[callkaro-is-not-rep-call-activity]]`.
3. **`EventCode 21` is inbound** — count separately; it is not outbound reach.
4. **"Connected" = duration > 0.** Cross-check `Status -eq "Answered"` as an independent signal.
   Across every run to date the two have agreed on *every single call* (e.g. 36/36, 48/48, 20/20),
   so a divergence would itself be news.

## Distinguishing real rep action from migration artifacts

`EventCode 3002` StageChange activity exists for almost every lead because the 2026-07-30/31
migration bulk-wrote `ProspectStage`. **"Has a stage change" is therefore not evidence a rep did
anything.** On 2026-08-05 this nearly produced the false finding that Kartikey was marking records
without calling them — 112 of his contacts had stage-change activity, all dated 2026-07-30, all
landing on `Fresh`.

The usable metric is **"stage changed at or after the rep's last call to that contact"**, which is
what the discipline percentage in the compliance report measures.

## Cost model

**There is no bulk Activity read endpoint and no bulk Opportunity read endpoint.**
`ProspectActivity.svc/Retrieve?leadId=X` is one API call per lead. Any activity-driven report is
therefore O(contacts) in API calls — ~13 minutes for 1,700 contacts at a 300 ms pace, and the API
starts returning 429s partway through (the `Invoke-LsqWithRetry` wrapper absorbs them).

Always narrow to a bounded candidate set *before* pulling trails. Three patterns in use:

- **By Source / owner** — `icp-rep-compliance.ps1` pulls only assigned contacts.
- **By watermark** — `calls-for-day.ps1` filters `ProspectActivityDate_Max >` the day before the
  target day, giving a bounded superset of "anyone touched on/after that day".
- **Never** sweep the whole 86K-lead account.

## Report structure conventions

Every script in `scripts/reports/` follows the same shape, and new ones should too:

1. `$ErrorActionPreference = "Stop"` at the top.
2. **Negative control** on the filter before trusting it — a value that must return zero rows.
3. Paginate the lead set through `Expand-LsqRows`, then guard the total against an **absolute
   expected size** (not an internally-derived one).
4. Pull per-contact activity, accumulating into a `List[object]`, `.ToArray()` at the end
   (never `@()` on the list — gotcha 12).
5. Pure `Get-Tally` / void `Write-Tally` split — a function must not both log and return.
6. Emit a timestamped JSON snapshot, a Markdown summary, and a per-contact CSV into `data/`,
   plus an append-only log.
7. Any partial/limited run must be flagged in the output itself (`IsPartialRun`), so a
   smoke-test can never be quoted as real coverage.

Related: `[[09-icp-assignment-programme]]`, `[[11-crm-hygiene-findings]]`.
