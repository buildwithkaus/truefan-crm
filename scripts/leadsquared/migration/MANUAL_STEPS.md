# Manual (UI-only) steps — must be done BEFORE the migration runs

These cannot be automated. There is no Company field-creation API, no Opportunity Type API,
and pushing dropdown options to a **system** Lead field (`ProspectStage`) is undocumented and
unverified. Everything else is scripted.

**Why the order matters:** writing a stage value that does not exist in the dropdown fails on
*every single record*. `run-migration.ps1 -Execute` refuses to start without
`-ConfirmManualSteps` for exactly this reason.

Budget ~45 minutes.

---

## 1. Lead — add the 5 new `ProspectStage` values

*My Account > Settings > Customization > Lead > Manage Fields > Lead Stage*

Add, **alongside the existing 28 — delete nothing yet**:

- `Fresh`
- `Engaged`
- `Prospect`
- `Customer`
- `Disqualified` — already exists, leave it

Old values stay live through the transition month, because half the team continues the
legacy process. They get hidden only after everyone has moved over.

> `Disqualified` already exists with 25,078 leads on it. Those leads keep the same stage
> string and simply gain a reason + category. No write is needed for the stage itself.

## 2. Company — add the 5 new `Stage` values

*My Account > Settings > Customization > Company > Manage Fields > Stage*

- `Fresh`
- `Nurture`
- `Opportunity` — already exists
- `Customer` — already exists
- `Future Prospect`

### 2a. The rename that saves hours

Company stage writes are the slowest part of the migration — one API call each, no safe bulk
endpoint. **Before adding the values above**, check the dry-run output of
`05-migrate-companies.ps1`: it prints which target stage the largest number of companies land
on.

**Rename the existing `Prospect` value to that stage** rather than adding it fresh. Every
company already on `Prospect` (67,036 of 71,467) then carries the new value with zero API
writes, and the migration skips them.

> **Verify the rename actually carried the data** before trusting it: rename a value on a
> throwaway field, then re-fetch a record that held the old value and confirm it reads the
> new one. Evidence renames are at least *supported*: the live Opportunity Won stage carries
> `"Value":"Payment Recieved","OldValue":"Closed - Won"`.
>
> If renames do **not** carry existing data, nothing breaks — the script just writes all
> 71,467 records and the run takes ~6 hours instead of ~1.5. Plan the window accordingly.

## 3. Company — create 3 fields

*My Account > Settings > Customization > Company > Manage Fields > New*

| Field name | Type | Options |
|---|---|---|
| `Future Prospect Reason` | Dropdown | Not ICP Fit, No Requirement, Commercial Mismatch, Supply Gap, Unreachable / Bad Data, Not Interested |
| `Revisit After` | Date | — |
| `Needs Contact Resourcing` | Dropdown | Yes, No |

Schema names must come out as `Future_Prospect_Reason` and `Needs_Contact_Resourcing` —
`05-migrate-companies.ps1` writes to those exact names. If LSQ generates something different,
update the script.

## 4. Opportunity — rename the 5 existing Stage values

*My Profile > Settings > Opportunities > Opportunity Types > Opportunity (code 12000) >
Field Configuration > Stage*

`Stage` is the custom field `mx_Custom_2`, a dependent dropdown under `Status`. **Rename, do
not recreate** — renaming carries the ~4,404 existing Opportunities across for free.

| Current value | Rename to |
|---|---|
| Requirement Gathering | `Prospect` |
| Celebrity/Product Proposed | `In Discussion` |
| Contract Sent | `Agreement Sent` |
| Payment Pending | `Invoice Sent` |
| Payment Recieved | `Payment Received` *(fixes the live typo)* |
| Closed - Lost | leave as is |

Then **add** under Status = `Won`: `Customer`.

Final state:

| Status ("Deal Stage") | Stage values |
|---|---|
| Open | Prospect, In Discussion, Agreement Sent, Invoice Sent |
| Won | Payment Received, Customer |
| Lost | Closed - Lost |

## 5. Opportunity — create 2 date fields

| Field name | Type |
|---|---|
| `Agreement Sent Date` | DateTime |
| `Invoice Sent Date` | DateTime |

These exist so agreement and invoice can be sent in **either order** without breaking funnel
reporting: stage only ever moves forward, both dates get stamped whenever each actually
happens.

## 6. Activity — make the call outcome mandatory

*My Account > Settings > Customization > Activity > `01. Phone Call/ Follow Up`*

Every field needed already exists — and **all of them are currently optional**, which is the
root cause of the whole problem. Nothing stopped a rep logging a call with everything blank
and editing the stage directly instead.

Make mandatory:
- `Status` (Connected / Not Connected)
- `Connected Outcome` / `Not Connected Outcome` (dependent on Status)
- `Next Step` (when Status = Connected)

**Do this AFTER the migration and the rep briefing**, not before — turning it on mid-week
blocks reps who have not been briefed yet.

---

## Checklist

```
[ ] 1.  Lead: 5 new ProspectStage values added (old 28 untouched)
[ ] 2.  Company: 5 new Stage values added
[ ] 2a. Rename-carry behaviour VERIFIED on a throwaway field
[ ] 2b. Company 'Prospect' renamed to the largest target bucket
[ ] 3.  Company: 3 new fields created, schema names confirmed
[ ] 4.  Opportunity: 5 stages renamed + 'Customer' added under Won
[ ] 5.  Opportunity: Agreement Sent Date + Invoice Sent Date created
[ ] --- migration runs here ---
[ ] 6.  Activity: call outcome fields made mandatory (AFTER rep briefing)
```

Once 1-5 are ticked:

```powershell
pwsh ./scripts/leadsquared/migration/run-migration.ps1 -Execute -ConfirmManualSteps
```
