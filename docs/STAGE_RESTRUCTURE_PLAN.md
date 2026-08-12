# Stage Restructure — Design, Migration & Sync Plan

Owner: Kaustubh Chauhan (Founder's Office). Design locked 2026-07-28.
Supersedes the 4-layer sketch in `memory/06-stage-taxonomy-design.md` (kept for history).

Read `CLAUDE.md` first — every API gotcha in it applies to the scripts described here.

---

## 1. The three stage models

Reps see three objects. Each answers exactly one question. No value appears in two models.

**Contact (Lead) — "where is this *person*?"**

```
Fresh -> Engaged -> Prospect -> Customer
                 |
                 +-> Future Prospect (+ reason)   right business, wrong time - REVISIT
                 |
                 +-> Disqualified    (+ reason, mandatory)   out of play
```

Six values, not five. **`Future Prospect` and `Disqualified` are not the same exit** and the
difference is the whole point: a future prospect is an account waiting on timing and should
come back; a disqualified contact is out of play. Collapsing the two - which this document
originally did - removes 2,700-odd live accounts from the reps working them.

*(Corrected 2026-08-12. See the note above the mapping table in section 4.)*

**Company (Account) — "where is this *account*?"**

```
Fresh -> Nurture -> Opportunity -> Customer
                 \
                  -> Future Prospect (+ reason, mandatory)
```

**Opportunity — "where is this *deal*?"**

```
Prospect -> In Discussion -> Agreement Sent -> Invoice Sent -> Payment Received -> Customer
                                                            \
                                                             -> Closed - Lost (+ Loss Reason)
```

Mapped onto LeadSquared's fixed, non-editable Opportunity `Status`:

| Status (native, fixed) | Stage values (`mx_Custom_2`, dependent dropdown) |
|---|---|
| Open | Prospect, In Discussion, Agreement Sent, Invoice Sent |
| Won | Payment Received, Customer |
| Lost | Closed - Lost |

### Stage definitions (these go in the SOP verbatim)

| Object | Stage | Means |
|---|---|---|
| Contact | Fresh | Never had a live conversation. Includes every un-connected dial attempt. |
| Contact | Engaged | Reached a human, pitch delivered or in progress, no stated requirement yet. |
| Contact | Prospect | Stated a requirement. An Opportunity exists and this contact owns it. |
| Contact | Customer | Their deal reached Opportunity stage = Customer. |
| Contact | Disqualified | Out of play. Reason mandatory. |
| Company | Fresh | No contact at this account has ever connected. |
| Company | Nurture | At least one contact engaged, no requirement stated yet. |
| Company | Opportunity | An open Opportunity exists on the primary contact. |
| Company | Customer | An Opportunity reached stage = Customer. |
| Company | Future Prospect | Primary contact disqualified. Reason + revisit date mandatory. |
| Opportunity | Prospect | Requirement gathered. The deal exists but nothing has been proposed. |
| Opportunity | In Discussion | Celebrity / product / pricing actively being worked. |
| Opportunity | Agreement Sent | Contract sent to client. |
| Opportunity | Invoice Sent | Proforma invoice raised. |
| Opportunity | Payment Received | First payment tranche received against the PI. |
| Opportunity | Customer | Contract fully active, delivery underway. |

---

## 2. The single-source-of-truth rule

> **The Contact Stage is the object reps drive. Company and Opportunity follow it.**
> A rep never types a stage into more than one object.

Locked 2026-07-28. Contact Stage stays **rep-writable** — this is not a read-only rollup —
because `Engaged -> Prospect` is a judgement call: no single call outcome reliably means "this
is a real deal now" (see the manual trigger below), so a human has to make that call somewhere,
and Contact is the object closest to the rep's actual work.

This restructure is **org-wide**: every rep cuts over together on migration night, not a
phased rollout. (The half-account-level/half-contact-level split belongs to the separate *New
SMB Outreach Model* work — don't conflate the two.)

Everything else is derived from Contact Stage automatically, so a rep only ever writes to one
place. The granular detail reps used to cram into `ProspectStage` — call outcome,
disqualification reason — moves to its own dedicated fields (`Call Disposition`,
`Disqualification Reason`/`Category`, Company's `Future Prospect Reason`) instead of
overloading the stage.

### The three triggers

**1. First activity recorded — automatic**

The moment the *first* activity of any kind lands on a contact, regardless of type or
outcome:

- Contact: `Fresh` -> `Engaged`
- Company: `Fresh` -> `Nurture`

Guarded: this only fires on records currently at `Fresh`. A new activity on a contact already
at `Prospect` must never drag it back to `Engaged`.

**2. Engaged -> Prospect — manual, by the rep**

The rep moves the Contact Stage by hand. This is deliberately **not** tied to a call outcome:
there is no single outcome value that reliably means "this is a real deal now", so forcing one
would either miss deals or manufacture them. The rep's judgement is the trigger.

That one manual move then fires automatically:

1. Contact flagged `IsPrimaryContact = true` (if the account has no primary yet)
2. Opportunity **created**, Status = `Open`, Stage = `Prospect`
3. Company: `Nurture` -> `Opportunity`

**3. Opportunity progression — rep-driven, syncs back down**

Once the deal exists, the rep drives the Opportunity Stage. Contact and Company follow.

### Full sync matrix

| Trigger | Opportunity | Contact (primary) | Company |
|---|---|---|---|
| Lead created, no activity | — | Fresh | Fresh |
| **First activity of any kind** | — | **Engaged** | **Nurture** |
| Further activities while Engaged | — | Engaged *(no regression)* | Nurture |
| **Rep sets Contact = Prospect** | **created**, Open / Prospect | **Prospect** | **Opportunity** |
| Opp -> In Discussion | Open / In Discussion | Prospect | Opportunity |
| Opp -> Agreement Sent | Open / Agreement Sent | Prospect | Opportunity |
| Opp -> Invoice Sent | Open / Invoice Sent | Prospect | Opportunity |
| **Opp -> Payment Received** | Won / Payment Received | **Customer** | **Customer** |
| Opp -> Customer | Won / Customer | Customer | Customer |
| Opp -> Closed - Lost | Lost + Loss Reason | Disqualified + reason | Future Prospect + reason |
| Rep sets Contact = Disqualified | Lost, if one is open | Disqualified + reason | Future Prospect + reason |

**`Payment Received` makes the account a Customer** (approved 2026-07-28). Tranched PIs are
explicitly out of scope for now — the post-sales half of the opportunity lifecycle gets its
own pass later. Both `Payment Received` and `Customer` are Won and both drive Contact and
Company to `Customer`; the split between them exists so that later refinement has somewhere
to land.

### Old-value retention note

Old `ProspectStage` values stay live in the dropdown alongside the 5 new ones purely as a
rollback safety margin — `MANUAL_STEPS.md` step 1 is explicit that nothing is deleted before
the migration runs. Every lead moves to a new value on migration night (section 7.2); there is
no group of reps still writing the old values afterward. Old values are hidden once Phase 5R's
verification pass (steps 11-13) confirms clean, and fully retired once historical reporting
needs are confirmed covered.

---

## 3. Multiple contacts, one company — the primary contact rule

`IsPrimaryContact` exists on Lead and was unused until the Phase 3 backfill started setting
it. Rules from here:

1. **Only the primary contact may own an Opportunity.** One primary per company per open deal.
2. **Auto-promotion**: the first contact at an account to hit a `Requirement Gathering` call
   outcome becomes the primary automatically. No manual designation step, so the rule cannot
   be forgotten.
3. **Non-primary contacts move independently** through Fresh / Engaged / Disqualified. They
   can never reach Prospect or Customer — those states are derived from an Opportunity, and
   they do not own one. They are stakeholders (buying-committee members).
4. **Company Stage follows the primary contact** whenever one exists.
5. **No primary yet** -> Company Stage = the furthest-along state across all its contacts
   (any Engaged -> Nurture; all Disqualified -> Future Prospect; else Fresh).
6. **Collision** (a second contact hits Requirement Gathering at an account that already has
   an open Opportunity): do **not** create a second deal. Flag it for the rep — "add as
   stakeholder, or request primary transfer." A weekly validation report lists violations.

Rule 6 is what stops one account fragmenting into five "deals" and inflating pipeline.

---

## 4. Migration mapping — the 28 current values

> **Counts and exact strings verified 2026-07-28** by enumerating actual stored values across
> all 86,628 leads, not by probing a guessed list. They reconcile to exactly 86,628 with
> **0 blank stages**. This matters — see the string-mismatch warning below.

### Warning: the previously documented value list was wrong

Three strings were wrong and three values were missing. The Phase 5 backfill probed
`Invalid/Junk` and `Just Enquiring No Intent`, got **0 rows for both**, and logged that as
fact. The real strings carry a space and a comma: **`Invalid/ Junk`** (17,340 leads) and
**`Just Enquiring, No Intent`** (2,736 leads). **20,076 leads never got their
`mx_Disqualification_Reason` backfilled**, and three undocumented values
(`Not Interested` 86, `Requirement Gathering` 12, `Contract Follow Up` 6) were never mapped
at all.

**Every string in the table below is copied from live data. Do not retype them.** The
migration script must read them from a generated worklist, never from a hand-written literal.

> **CORRECTED 2026-08-12 — `Future Prospect` is a CONTACT stage.** This table originally
> mapped it to `Disqualified`, on the reading that it was only a Company stage. It is not: it
> is a live contact stage meaning *"right business, no need right now"* — an account waiting
> on timing, not a closed one.
>
> The original mapping was executed on 2026-08-11 and moved **2,729 contacts** into
> `Disqualified`. Reps noticed their accounts had gone, and all 2,726 still eligible were
> rolled back on 2026-08-12 (`scripts/migration/18-rollback-future-prospect.ps1`).
>
> `Future Prospect` now maps to **itself**. It stays in `$StageMap` rather than being removed,
> because `12-reconcile-contacts.ps1` reports an unmapped stored value as drift — deleting the
> entry would trade a wrong migration for a permanent false alarm. Reason and Category are
> still filled; only the stage is left alone.
>
> **The contact model is therefore SIX values, not five.** Anything in this document that says
> five is stale, including the diagram above.

| Old `ProspectStage` (exact) | Count | -> Contact Stage | Disq. Reason (L2) | Category (L1) | Call Disposition | Source / Segment | -> Company Stage |
|---|---|---|---|---|---|---|---|
| `Fresh Lead` | 1,825 | Fresh | — | — | — | — | Fresh |
| `Didn't Picked` | 12,094 | Fresh | — | — | Did Not Pick | — | Fresh |
| `RNR` | 276 | Fresh | — | — | RNR (5+ dials) | — | Fresh |
| `Switched Off/Not Reachable` | 4,649 | Fresh | — | — | Switched Off / Not Reachable | — | Fresh |
| `Call me Later` | 1,436 | Engaged | — | — | Call Me Later | — | Nurture |
| `Follow Up` | 2,558 | Engaged | — | — | Follow Up (pitch delivered) | — | Nurture |
| `ReQualified By WhatsApp` | 7 | Engaged | — | — | — | WhatsApp Requalified | Nurture |
| `Retargetedlead` | 92 | Engaged | — | — | — | Retargeted (WhatsApp) | Nurture |
| `RetargetedleadEMAIL` | 0 | Engaged | — | — | — | Retargeted (Email) | Nurture |
| **`Requirement Gathering (Warm)`** | 667 | **Prospect** | — | — | — | — | **Opportunity** |
| **`Requirement Gathering`** *(undocumented)* | 12 | **Prospect** | — | — | — | — | **Opportunity** |
| **`Conversation In Progress (Hot)`** | 147 | **Prospect** | — | — | — | — | **Opportunity** |
| **`Contract Follow Up`** *(undocumented)* | 6 | **Prospect** | — | — | — | — | **Opportunity** |
| **`Payment Received`** | 193 | **Customer** | — | — | — | — | **Customer** |
| `Disqualified` | 25,078 | Disqualified | Not Interested - No Reason Stated | Not Interested | — | — | Future Prospect |
| **`Invalid/ Junk`** *(space)* | **17,340** | Disqualified | Invalid / Not a Business | **Not ICP Fit** | — | — | Future Prospect (suppressed) |
| `Low Budget` | 5,891 | Disqualified | Low Budget / Pricing Mismatch | Commercial Mismatch | — | — | Future Prospect |
| `Wrong Number` | 4,753 | Disqualified | Invalid Contact Data | Unreachable / Bad Data | — | — | **Nurture** (see note) |
| **`Just Enquiring, No Intent`** *(comma)* | **2,736** | Disqualified | Just Enquiring - No Intent | No Requirement | — | — | Future Prospect |
| `Future Prospect` | 2,686 | **Future Prospect** *(unchanged — see the note below)* | No Current Requirement (Timing) | No Requirement | — | — | Future Prospect |
| `No Requirement of Celeb in Ads` | 1,901 | Disqualified | No Celebrity Requirement | **Not ICP Fit** | — | — | Future Prospect (suppressed) |
| `Does not want AI` | 612 | Disqualified | Does Not Want AI | No Requirement (product-specific) | — | — | Future Prospect |
| `B2B-Disqualified` | 543 | Disqualified | Out of ICP - B2B Not Relevant | **Not ICP Fit** | — | B2B | Future Prospect (suppressed) |
| `Not Active After First Conversation` | 356 | Disqualified | Went Dark After First Conversation | Not Interested | — | — | Future Prospect |
| `Supply Issue` | 103 | Disqualified | Celebrity Supply Gap | Supply Gap | — | — | Future Prospect |
| **`Not Interested`** *(undocumented)* | 86 | Disqualified | Not Interested - No Reason Stated | Not Interested | — | — | Future Prospect |
| `Conflict` | 4 | Disqualified | Legacy - Unclassified | Not Interested | — | — | Future Prospect |
| `SaaS` | 567 | *inferred* | — | — | — | Segment = Enterprise/SaaS | *inferred* |
| `FB Lead - Website` | 10 | *inferred* | — | — | — | Source = FB Lead / Website | *inferred* |

### Resulting distribution

| New Contact Stage | Leads | % of book |
|---|---|---|
| Fresh | 18,844 | 21.8% |
| Engaged | 4,093 | 4.7% |
| **Prospect** | **832** | **1.0%** |
| **Customer** | **193** | **0.2%** |
| Disqualified | 62,089 | 71.7% |
| *to infer* (SaaS / FB Lead) | 577 | 0.7% |
| **Total** | **86,628** | 100% |

Two numbers worth sitting with. **71.7% of the entire database is disqualified**, and
`Invalid/ Junk` — defined as "No business" — is the **second-largest bucket in the CRM at
17,340 leads (20%)**. That is a lead-sourcing quality problem, not a pipeline problem, and no
amount of stage restructuring fixes it. Worth a separate look at where those leads came from.

Against that, the live pipeline is **832 Prospects and 193 Customers**. That is the real
denominator this project is trying to grow.

### Each rep's book in the new model

Pulled live 2026-07-28 (`data/stage_owner_distribution.json`). This is the migration-scoping
table — and the briefing table, since every rep will want to know what happens to their list.

| Owner | Total | Fresh | Engaged | Prospect | Customer | Disqualified | To infer |
|---|---|---|---|---|---|---|---|
| Mayank Arora | 6,090 | 1,453 | 538 | **170** | 29 | 3,855 | 45 |
| Prakhar Gupta | 2,786 | 844 | 366 | **137** | 4 | 1,421 | 14 |
| Rahul Madaan | 4,148 | 1,245 | 647 | **136** | 4 | 2,102 | 14 |
| Shriyanka Gupta | 7,487 | 1,354 | 648 | **86** | 37 | 5,326 | 36 |
| Ashutosh Ojha | 3,987 | 1,831 | 139 | **85** | 1 | 1,924 | 7 |
| adarsh pandey | 6,323 | 1,307 | 125 | **59** | 39 | 4,707 | 86 |
| Abhishek Tripathi | 1,108 | 453 | 119 | 33 | 0 | 496 | 7 |
| Subham Tak | 2,780 | 933 | 234 | 31 | 2 | 1,571 | 9 |
| Arjun Rathi | 885 | 464 | 80 | 20 | 0 | 320 | 1 |
| Saurabh Sharma | 1,114 | 605 | 41 | 15 | 0 | 453 | 0 |
| Irfan Mahmood | 2,401 | 986 | 261 | 13 | 0 | 1,140 | 1 |
| Nikhil Sharma | 3,895 | 1,242 | 467 | 10 | 4 | 2,162 | 10 |
| Vikhyat Verma | 2,958 | 1,082 | 86 | 6 | 2 | 1,782 | 0 |
| Anchal Awasthi | 419 | 260 | 69 | 5 | 0 | 85 | 0 |
| Neha Advani | 2,837 | 1,339 | 118 | 3 | 4 | 1,365 | 8 |
| Twinkle Sutrakar | 285 | 225 | 11 | 3 | 0 | 46 | 0 |
| Rishi Saraswat | 2,042 | 791 | 112 | 1 | 0 | 1,121 | 17 |
| Kartikey Mishra | 353 | 271 | 18 | 1 | 0 | 63 | 0 |
| **Admin** (parked) | 14,538 | 2,175 | 14 | 0 | 67 | 11,958 | 324 |
| Kaustubh Chauhan | 15 | 10 | 0 | 0 | 0 | 5 | 0 |
| System | 7 | 1 | 0 | 0 | 0 | 6 | 0 |

*(Counts here are from the 26-value probe and total 66,458 — they exclude the ~20,100 leads
on the mis-stringed and undocumented values discovered afterwards, nearly all of which are
Disqualified. Rep-level Disqualified counts are therefore understated; Fresh, Engaged,
Prospect and Customer are complete and accurate.)*

Three things jump out:

- **Pipeline is extremely concentrated.** Six reps hold 673 of the 832 Prospects (81%). Five
  reps have three or fewer live deals each. That is either a coaching signal or a
  territory-quality signal, and the account model should make which one visible.
- **Admin holds 14,538 parked leads** including **67 Customers** — customers with no active
  owner. Those need reassigning before the account-based rollout, not after.
- **Ashutosh Ojha and Neha Advani** are Fresh-heavy (1,831 and 1,339) with thin Engaged
  counts — large un-worked lists rather than un-converted ones. A different problem from
  Shriyanka's 5,326 disqualified.

### Mapping logic, stated plainly

- **A call outcome that can be retried is not a dead lead.** RNR / Didn't Picked / Switched
  Off all mean "we never reached a human" -> Contact stays `Fresh`, and the *reason we
  haven't reached them* moves to `Call Disposition`. This alone rescues **17,019 leads**
  (19.6% of the database) from a bucket that looked terminal and silently fell out of every
  follow-up queue.
- **Reached-a-human outcomes are `Engaged`.** Call me Later and Follow Up both describe a
  person who picked up. Their company moves to `Nurture` — an account we have touched.
- **Requirement stated = a deal exists.** Requirement Gathering (Warm) and Conversation In
  Progress (Hot) both describe a live deal, so both become `Prospect` *and* get an
  Opportunity. Hot is further along, so its Opportunity is created at `In Discussion`, not
  `Prospect` (see section 6, step 4).
- **One terminal state, many reasons.** Every negative value collapses to `Disqualified`
  with the old value preserved as the reason. Nothing is lost; it just stops pretending to
  be a pipeline stage.
- **Channel tags were never stages.** SaaS / FB Lead / Retargeted / ReQualified describe
  where a lead came from or what segment it is. They move to attributes.

### Two deliberate deviations from the literal instruction — both APPROVED 2026-07-28

**(a) `Wrong Number` -> Company `Nurture`, not `Future Prospect`.** The definition is
explicit: *"Lead with a qualified business but contact number mentioned is not correct."*
The **account is qualified** — only the phone number is wrong. Sending it to Future Prospect
buries **4,754 qualified accounts** behind a stage that reads "we already lost this."
Recommended instead: the *contact* is Disqualified (Invalid Contact Data) and the *account*
sits in `Nurture` flagged **needs contact re-sourcing** — which is exactly the kind of work
the account-based model is supposed to surface. This is the single clearest example of why
moving to accounts pays off.

**(b) `Not ICP Fit` accounts are suppressed from working views.** The instruction was that
*any* disqualified contact sends its company to Future Prospect, including ICP misfits. That
is implemented as asked — but "software company that will never want celebrity endorsement"
and "great fit, no budget this quarter" cannot sit in the same bucket without it becoming a
junk drawer reps learn to ignore. So both go to `Future Prospect`, and the **reason
category** drives visibility: `Not ICP Fit` is excluded from rep working views and from the
TAL; everything else surfaces on its revisit date.

---

## 5. Disqualification reason taxonomy

Two levels. Level 1 drives *behaviour* (does this account ever come back?); Level 2 preserves
the detail reps already record.

| L1 Category | Means | Revisit? | L2 reasons that roll up to it |
|---|---|---|---|
| **Not ICP Fit** | Structurally wrong. Will never buy this product. | Never — suppress from TAL | Out of ICP - B2B Not Relevant; No Celebrity Requirement; Invalid / Not a Business |
| **No Requirement** | Right profile, no need now. | Yes, on revisit date | No Current Requirement (Timing); Just Enquiring - No Intent; Does Not Want AI |
| **Commercial Mismatch** | Wants it, price does not work. | Yes, on pricing change | Low Budget / Pricing Mismatch |
| **Supply Gap** | Wants it, our celebrity roster does not cover it. | Yes, on roster change | Celebrity Supply Gap |
| **Unreachable / Bad Data** | Contact-level failure. Account may be fine. | Yes, re-source contact | Invalid Contact Data |
| **Not Interested** | Heard the pitch, declined. | Yes, low priority | Not Interested - No Reason Stated; Went Dark After First Conversation; Legacy - Unclassified |

`Supply Gap` and `Commercial Mismatch` are the two categories worth a standing report — they
are the accounts that convert themselves the moment a celebrity signs or pricing flexes, with
no new prospecting required.

---

## 6. Field engineering — what has to be built

### Already built and usable

- Lead: `mx_Call_Disposition`, `mx_Disqualification_Reason` — created and backfilled for
  35,496 leads on 2026-07-27.
- Opportunity type `EventCode 12000` with `Status` (Open/Won/Lost) and `mx_Custom_2` = Stage
  as a **dependent dropdown under Status**, plus Loss Reason (`mx_Custom_4`), Product,
  Celebrity Assigned, Contract Start/End Date, Renewed From, Expected/Actual Deal Size.

### To build

| Object | Field | Type | How |
|---|---|---|---|
| Lead | `mx_Disqualification_Category` | Dropdown (6 L1 values) | API — `CreateLeadField` |
| Lead | `mx_Segment` | Dropdown (Enterprise/SaaS, SMB, ...) | API |
| Lead | `mx_Revisit_After` | Date | API |
| Company | `Future_Prospect_Reason` | Dropdown (6 L1 values) | **UI only** |
| Company | `Revisit_After` | Date | **UI only** |
| Company | `Needs_Contact_Resourcing` | Yes/No | **UI only** |
| Opportunity | `Agreement Sent Date` | DateTime | UI (Opportunity Type editor) |
| Opportunity | `Invoice Sent Date` | DateTime | UI |

No Company field-creation API exists (confirmed, `memory/07`), so the Company fields are a
manual step — same as the Opportunity Type build was.

### Agreement Sent / Invoice Sent in either order

Reps send these two in whichever order the client needs. Handled without breaking funnel
reporting:

- **Stage always reflects the furthest milestone reached**, in canonical order
  `Prospect < In Discussion < Agreement Sent < Invoice Sent < Payment Received < Customer`.
- **Both date fields are stamped independently**, whenever each event actually happens.

So a rep who invoices first sets Stage = `Invoice Sent` + Invoice Sent Date; when the
agreement follows, Stage **stays** `Invoice Sent` (it is further along) and Agreement Sent
Date is stamped. The deal never moves backwards, nothing is double-counted, and cycle-time
analytics on both events stay accurate.

---

## 7. Migration execution plan

### 7.1 The rename discovery — this is what makes it cheap

Live Opportunity metadata shows `"Value":"Payment Recieved","OldValue":"Closed - Won"`.
LeadSquared **tracks in-place renames of dropdown values**. If a rename carries existing
records' stored values with it, then any bucket whose *entire population* maps to a single
new value needs **zero API writes** — just a UI rename.

Applying that:

| Object | Rename (UI) | Records migrated for free |
|---|---|---|
| Opportunity | Requirement Gathering -> `Prospect` | all |
| Opportunity | Celebrity/Product Proposed -> `In Discussion` | all |
| Opportunity | Contract Sent -> `Agreement Sent` | all |
| Opportunity | Payment Pending -> `Invoice Sent` | all |
| Opportunity | Payment Recieved -> `Payment Received` (fixes the typo) | all |
| Lead | Fresh Lead -> `Fresh` | 1,459 |
| Lead | Disqualified -> `Disqualified` (no change needed) | **25,048** |
| Company | Prospect -> whichever of Fresh / Future Prospect is the larger target bucket | up to 67,036 |

That last row is the big one. Company updates are the migration bottleneck — there is no safe
bulk Company endpoint (`memory/07`: the bulk endpoint matches on CompanyName and is
create-*or*-update, so a name mismatch silently creates a duplicate), meaning 71,467
single-record calls at ~300ms = **~6 hours**. Renaming the 67,036-record `Prospect` value to
whichever target bucket is largest cuts that to roughly 1-2 hours.

> **This must be verified before the plan depends on it.** Test: rename a value on a
> throwaway custom field, then independently re-fetch a record that held the old value and
> confirm it now reads the new one. If renames do *not* carry existing data, fall back to the
> full write path and budget a Friday-night-to-Saturday window instead of a single night.

### 7.2 Sequence

**T-3 days — build (no writes to live records)**
1. Create the Lead fields via API; create Company + Opportunity fields via UI.
2. Run the rename-carry verification test above. Record the result.
3. Add the new stage values alongside the old ones (Lead `ProspectStage`, Company `Stage`,
   Opportunity `mx_Custom_2`). `ProspectStage` is a **system** field and pushing dropdown
   options to system fields via API is unverified (`memory/07`) — do it in the UI.
4. Build and review the full worklist. Read-only, writes nothing, output to
   `data/stage_migration_worklist.json`. Every row: ProspectId, CompanyId, old value, new
   contact stage, new company stage, reason, category. **Eyeball this before proceeding.**

**T-1 day — dry run**
5. Apply to 50 records spanning every source value. Verify each by **independent re-fetch**,
   not response bodies (`CLAUDE.md`). Confirm the Contact -> Company -> Opportunity trio is
   consistent on all 50.

**T-0, Friday 22:00 — the run**
6. Full backup: current Lead stage/disposition, Company stage, Opportunity stage for every
   record, to `data/stage_migration_BACKUP_*.json`. Non-negotiable — this is the rollback.
7. UI renames (minutes, and they migrate the bulk of the population).
8. Delta writes only, **one script, nothing else touching the API** — the rate limit is
   account-wide and running two scripts concurrently already caused 23 silent write failures
   once (`PROJECT_PLAN.md` Phase 2). Order: active-rep-owned records first, Admin-parked
   records second, so if anything breaks it breaks on the set nobody is using.
9. Opportunity creation for the 832 leads becoming `Prospect`: 667 `Requirement Gathering
   (Warm)` + 12 `Requirement Gathering` -> Opportunity at `Prospect`; 147 `Conversation In
   Progress (Hot)` -> Opportunity at `In Discussion`; 6 `Contract Follow Up` -> Opportunity
   at `Agreement Sent`. Check-before-create against `GetOpportunitiesOfLead` — the Capture
   API returns `"IsUnique":true` even for genuine duplicates, so a blind run double-creates.
   Many of these already have an Opportunity from the Phase 3 backfill; the check handles it.
10. Backfill `mx_Disqualification_Reason` for the **20,076 leads missed** by the Phase 5 run
    (`Invalid/ Junk` and `Just Enquiring, No Intent` string mismatch) plus the 104 leads on
    the three undocumented values. Folded in here rather than run separately.

**T+0, Saturday 03:00 — verify**
11. Full count reconciliation: every old bucket's count must equal the sum of its new
    buckets. Any drift is a bug, not a rounding difference.
12. Random-sample 30 records per source value, independently re-fetched.
13. Cross-object consistency check: no contact at `Prospect` without an Opportunity; no
    Company at `Opportunity` without an open deal; no company with two open Opportunities.

**T+2 days, Monday 09:00 — rollout**
14. Rep briefing *before* they log in (section 8 / the SOP).
15. Old stage values hidden from the dropdowns — not deleted, so historical reporting still
    resolves.
16. Contact Stage and Company Stage set read-only for reps.

### 7.3 Volume and timing

| Workload | Records | Mechanism | Est. |
|---|---|---|---|
| Lead stage writes (deltas) | ~60,000 | Bulk UpdateV2, 25/call @1.1s | ~45 min |
| Company stage writes (deltas, post-rename) | ~15-20,000 | Single-record @300ms | ~1.5 hr |
| Opportunity creation | 815 | Capture, check-before-create | ~20 min |
| Opportunity stage remap | ~4,280 | **UI rename — zero writes** | minutes |
| Verification | sample | read-only | ~30 min |

Comfortably inside a Friday night if the rename carries data. If it does not, Company writes
alone become ~6 hours and the window extends into Saturday morning — still fine on a weekend,
which is why this runs Friday and not a weeknight.

### 7.4 Rollback

Every script writes prior values to a backup JSON *before* its first write — the pattern
already proven in `reassign-departed-owners.ps1`. Rollback is re-running the same writer with
source and target swapped. The Phase 2 incident (2,360 of Rishi Saraswat's leads wrongly
reassigned) was recovered exactly this way, so the path is tested, not theoretical.

---

## 8. Going-forward capture — making the outcome mandatory at the call

The migration fixes history. This stops it recurring.

The `01. Phone Call/ Follow Up` activity type **already has** every field needed: `Status`
(Connected / Not Connected), `Connected Outcome` (10 values incl. Interested/Qualified,
Future Prospect, Disqualified), `Not Connected Outcome` (Switched Off, Not Reachable, Wrong
Number/Junk, RNR, Did not pick), `Next Step` (incl. Requirement Gathering), plus per-thread
follow-up dates and Budget / Deliverable / Industry / Location capture.

**Every one of those fields is `IsMandatory: false`.** Nothing stopped a rep logging a call
with all of them blank and editing `ProspectStage` directly instead — which is precisely how
disposition, disqualification and lifecycle collapsed into one field.

Changes required:

1. `Status` becomes **mandatory**.
2. `Connected Outcome` / `Not Connected Outcome` become mandatory, dependent on `Status`.
3. `Next Step` becomes mandatory when `Status = Connected`.
4. Disqualifying outcomes require `Disqualification Category` + `Reason`.

Note what is deliberately **not** on this list: no call outcome creates an Opportunity. The
`Engaged -> Prospect` decision stays with the rep (section 2), so the activity fields exist to
capture *what happened*, not to drive stage machinery. That separation is the fix — the old
model failed precisely because one field tried to be both.

Contact Stage stays **writable** throughout, by design. Company Stage should be read-only for
reps once the sync is live, since nothing they do should require editing it directly.

### The sync engine

Four jobs:

| # | Job | Hops | Native LSQ automation? |
|---|---|---|---|
| 1 | First activity -> Contact `Fresh` to `Engaged` | Activity -> Lead | Likely yes |
| 2 | Contact Stage -> Company Stage | Lead -> Company | Unverified (2 hops) |
| 3 | Contact -> `Prospect` -> create Opportunity + set primary | Lead -> Opportunity | Unverified |
| 4 | Opportunity Stage -> Contact + Company Stage | Opp -> Lead -> Company | **Unverified (3 hops)** |

Job 1 needs the "only if currently Fresh" guard, or every subsequent activity drags a live
deal backwards.

Whether LSQ automation can traverse Opportunity -> Lead -> Company is the **main open
technical risk in this whole plan** and has been flagged unresolved since Phase 6 was written.
It needs a sandbox test or a LeadSquared support answer.

Fallback if native automation cannot do it: a scheduled PowerShell job every 15 minutes,
reading records modified since its last watermark and applying the section 2 sync matrix.
Same API mechanisms already proven in `scripts/archive/`, and the migration scripts in
`scripts/migration/` already implement every write this job needs — the scheduled
version is those same operations on a watermark instead of a full worklist. Slower to
propagate (15 min vs instant) but functionally identical.

**Do not let this question block the migration.** The stage restructure and the sync
automation are independent; migrate first, automate second. In the transition month the
manual `Engaged -> Prospect` move means a rep is never *waiting* on automation to progress a
deal — the worst case is that the company stage lags 15 minutes behind the contact stage.

---

## 9. Decisions — resolved and still open

### Resolved 2026-07-28 (Kaustubh)

1. **`Payment Received` makes an account a Customer.** Contact and Company both flip at
   `Payment Received`, not at the later `Customer` stage. Tranched PIs are knowingly out of
   scope for now — the post-sales half of the opportunity lifecycle gets a separate pass.
2. **`Wrong Number` -> Company `Nurture`.** Approved. 4,753 qualified accounts stay workable
   with a `Needs Contact Resourcing` flag instead of being buried.
3. **`Not ICP Fit` suppressed from working views and the TAL.** Approved.
4. **Contact Stage stays rep-writable**, and `Engaged -> Prospect` is a manual rep decision
   rather than a call-outcome trigger. See section 2.
5. **Nothing is changed in production ahead of the migration.** Schemas and scripts are
   prepared and rehearsed; the whole thing runs as one unattended command on the night.

### Still open

6. **What structure holds the payment schedule?** A contract split into tranches has no object
   representing it — today it is reconstructed by hand from `04. Sales Activity` entries
   (Amount Received / Total Amount / Pending Amount). Needs a child object on Opportunity or a
   strict convention. **Almost certainly where the operational sheets live.** Deferred with
   decision 1, but it is the next thing to design.
7. **`Meeting` activity type has zero custom fields** — no virtual/physical flag, no outcome.
   Client-requested pre-contract meetings are real but structurally unrecorded.
8. **Does a dropdown rename carry existing record values?** Section 7.1 / `MANUAL_STEPS.md`
   step 2a. Sizes the Company step: ~1.5 hr if yes, ~6 hr if no. Not a blocker either way —
   the script writes whatever the rename did not.
9. **Can LSQ automation traverse Opportunity -> Lead -> Company?** Section 8. Determines
   whether the sync is native or a 15-minute scheduled job. Does not block the migration.

---

## 10. Execution — one command

Everything below `scripts/migration/` is built and parse-verified. Nothing has
been run against production.

| File | Does | Writes? |
|---|---|---|
| `scripts/lib/schema.ps1` | Declarative config: stage values, the 29-entry mapping, field defs | No |
| `01-create-fields.ps1` | Creates the 4 new Lead custom fields | Only with `-Execute` |
| `02-build-worklist.ps1` | Enumerates live values, **aborts on any unmapped value**, builds worklists | No |
| `03-backup.ps1` | Full current-state snapshot — this is the rollback | No |
| `04-migrate-leads.ps1` | Contact stages + reason/category/disposition/segment | Only with `-Execute` |
| `05-migrate-companies.ps1` | Company stages + future-prospect reasons | Only with `-Execute` |
| `06-create-opportunities.ps1` | Deals for primary contacts, check-before-create | Only with `-Execute` |
| `07-verify.ps1` | Reconciliation, residue, sampling, cross-object consistency | No |
| `run-migration.ps1` | **Runs all of the above in sequence, unattended** | Only with `-Execute` |
| `MANUAL_STEPS.md` | The UI-only prerequisites | — |

```powershell
# Rehearsal. Safe any time, in business hours, writes nothing:
pwsh ./scripts/migration/run-migration.ps1

# The night run, unattended:
pwsh ./scripts/migration/run-migration.ps1 -Execute -ConfirmManualSteps
```

Safety properties, all implemented rather than intended:

- **Nothing writes without `-Execute`.** The default is a full rehearsal.
- **`-Execute` refuses to start without `-ConfirmManualSteps`**, and separately verifies the
  Lead fields exist first — writing a stage value that is not in the dropdown fails on every
  record.
- **Pre-flight aborts if another LeadSquared script is running.** The rate limit is
  account-wide; a concurrent run has already caused 23 silent write failures on this account.
  Detection is by command line, not process name, because several unrelated `powershell.exe`
  processes exist for IDE tooling.
- **The worklist builder aborts on any unmapped stage value.** A newly added dropdown value
  halts the migration instead of being silently skipped — the exact failure that cost 20,076
  leads last time.
- **Every step is checkpointed and idempotent.** A run that dies at 3am resumes on re-run.
  Records already at their target are skipped, so re-running is cheap.
- **Backup precedes every write**, and rollback is the same writers pointed at the backup.

### What lands when

| Step | Depends on | Blocking? |
|---|---|---|
| Rehearsal run (dry) | — | No — do this first |
| Manual UI steps (`MANUAL_STEPS.md` 1-5) | rehearsal reviewed | Yes |
| Verify rename-carry behaviour | — | Sizes the run only |
| Night migration (one command) | manual steps done | Yes |
| Verification pass | migration | Yes — runs automatically as step 7 |
| Rep briefing + SOP | migration verified | Yes |
| Make activity fields mandatory | rep briefing done | No |
| Sync automation | LSQ traversal answer | No — script fallback exists |
| Payment-schedule design | the sheets | No |
