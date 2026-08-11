# 13 - Channel census and ICP field readiness

*Written 2026-08-10. Every number here was pulled live the same day by
`scripts/pipeline/09-activity-census.ps1` and `scripts/reports/enumerate-icp-readiness.ps1`,
both read-only. Raw output: `data/activity_census_20260810-112524.json`,
`data/icp_readiness_20260810-151611.json`.*

## Why this was run

Phase 10 measures the phone. The question was what else is happening, and whether the fields
needed for an ICP conversion analysis actually hold data. Both were answerable cheaply and
neither had ever been measured.

---

## Part 1 - the channel census

### The activity-type catalogue endpoint exists

`ProspectActivity.svc/ActivityTypes.Get` (a **GET**) returns all activity types with full form
metadata. `data/activity_types_schema.json` had been sitting in `data/` since 2026-07-27 with no
generator script and no record of where it came from. It is this endpoint.

**58 types live, against 57 in the cached dump. The new one is EventCode 209 "Call Disposition",
created 2026-08-06.** See Part 3.

### Whole-book last activity (complete population, 91,033 leads, reconciled 91,033/91,033)

| Last activity | Leads |
|---|---|
| AI Phone Call / Follow Up (Callkaro) | 38,520 |
| Outbound Phone Call Activity | 28,722 |
| **WhatsApp Message** | **7,700** |
| *(none)* | 4,965 |
| Facebook Lead Ads Submissions | 2,997 |
| Opportunity | 2,746 |
| Lead Capture | 2,467 |
| Inbound Phone Call Activity | 1,658 |
| 01. Phone Call/ Follow Up | 802 |
| Dynamic Form Submission | 449 |
| Converse Chat / 03. Payment / Sales Activity / Opportunity Captured / Had a Phone Conversation | 3 / 1 / 1 / 1 / 1 |

This is a **lower bound** - the field holds one value, so a type that never lands last is
invisible here. It is never safe as a hard exclusion (gotcha 14).

### Trail census, stratum 1 (uniform random, n=300 - the only stratum a rate may be read from)

| Code / name | Events | Leads | % of contacts | Distinct actors |
|---|---|---|---|---|
| 3002 StageChange | 1,139 | 296 | 99% | 36 |
| 208 AI Phone Call (Callkaro) | 886 | 177 | 59% | 2 |
| **22 Outbound Phone Call** | **864** | **242** | **81%** | 27 |
| **3001 LeadAssigned** | **611** | **287** | **96%** | 7 |
| **3011 WhatsApp Message** | **435** | **173** | **58%** | **1** |
| **201 WhatsApp Message** | **307** | **180** | **60%** | **1** |
| 3006 LeadAssociated | 302 | 300 | 100% | 0 |
| 23 Lead Capture | 121 | 99 | 33% | 0 |
| 202 Facebook Lead Ads | 83 | 83 | 28% | 1 |
| 21 Inbound Phone Call | 42 | 26 | 9% | 15 |
| 203 01. Phone Call/ Follow Up | 32 | 20 | 7% | 11 |
| 97 Dynamic Form Submission | 24 | 20 | 7% | 0 |
| 12000 / 33 / 3004 / 3011-Opportunity | 18 / 17 / 16 / 16 | | | |

**78.3% of contacts hold at least one non-call channel activity.**

A second stratum deliberately over-sampled non-call leads (n=300) to observe rare channels. It
is biased by construction and is never pooled with stratum 1 - it answers what a channel looks
like, never how common it is.

### The finding that changes how WhatsApp should be reported

**WhatsApp has exactly ONE actor across all 600 sampled leads**, against 27 for outbound calling.
It is a broadcast / integration channel, not per-rep outreach. It touches roughly as many
contacts as calling does (60% vs 81%) and is completely absent from every report - but it must
not be credited to reps in a scorecard. `ref_channel.actor_kind = 'integration'` encodes this.

Field usage across both strata (1,509 WhatsApp events):

- `Status`: blank 904, **FAILED 368**, READ 127, received 88, DELIVERED 69, SENT 20
- `mx_Custom_2` Direction: blank 904, Outbound 584, Inbound 88

Two things follow. **Of the messages that carry a status at all, 55% are FAILED** - that is a
channel-health problem nobody is watching. And the casing is inconsistent (`FAILED` / `READ` /
`received` / `SENT` against a dropdown defined as lowercase), so any grouping must normalise
case or it will report the same status twice.

### Money on activities - answered, and the answer is no

EventCodes 204 / 205 / 206 (Contract, Sales Activity with Amount Received / Total / Pending,
Payment) were the hypothesis that closed-won revenue might be recoverable from activities even
though the Opportunity value fields are empty. Across 600 sampled leads: **1 activity found, 0
carrying an amount.** The deal book has no value data anywhere. **ICP and funnel analysis stays
count-based** - do not build a value-weighted view.

### EventCode 3001 LeadAssigned carries the previous AND new owner

```
Data[ PreviousOwner=Admin (admin.sales@true-fan.in)
    | CurrentOwner=Subham Tak (subham.tak@true-fan.in)
    | CreatedBy=System ]
```

Present on **287 of 300 contacts (96%)**, with records going back to February 2025.
`ActivityFields` is absent entirely - everything is in `Data[]`, same shape as 3002.

This closes three gaps `memory/` records as unanswered:

1. **"Fresh means untouched *by me*"** - assignment date per owner is now derivable.
2. **Time to first touch** - assignment to first call by that owner.
3. **Lead ageing** - days held by the current owner.

Owners are given as `Name (email)`, not GUIDs. **Join on the email, never the name** - the
Piyush/Rishi incident is exactly what name-joining costs. `dim_rep` has no email column yet;
`OwnerIdEmailAddress` is available on `Leads.Get` and should be loaded with the book scan.

**3001 cannot be subscribed to.** Confirmed 2026-08-10: `Webhook.svc/Create` with
`ActivityEvent=3001` returns HTTP 500, while all 14 catalogued activity types created cleanly
in the same run. The 3xxx family is in the trail but not in the ActivityTypes catalogue, and
the webhook API only accepts catalogued types. **`fact_assignment` is therefore trail-derived,
not webhook-fed** - which is fine, because the history it needs is already in the trails. For
forward capture the fallback is a `Lead_Field_Change` hook on `OwnerId` (a different mechanism,
untested).

---

## Part 2 - ICP field readiness (all 91,033 leads, 4,689 on `Source = 'Kaustubh ICP'`)

| Field | Fill % (book) | Fill % (ICP) | Distinct | Verdict |
|---|---|---|---|---|
| `mx_Industry_Type` | 62.4% | 99.2% | **11,515** | **Unusable as a dropdown** - see below |
| `mx_Business_Location` | 42.7% | 1.3% | 11,809 | Not on the ICP population |
| **`mx_Category`** | **38.8%** | **100%** | **55** | **The ICP industry dimension. Use this.** |
| `mx_Budget` | 36.1% | 1.0% | 119 | Not on the ICP population |
| **`mx_Ads`** | **34.3%** | **99.7%** | **2** | **Usable. Yes/No.** |
| `mx_Designation` | 32.1% | 97.0% | 6,047 | Usable after normalising - top values are clean |
| `mx_City` | 28.9% | 97.9% | 1,530 | Usable |
| `mx_Business_Model` | 12.7% | 0.2% | 7,006 | Same drift problem as Industry Type |
| `mx_Segment` | 1.4% | 0.1% | 5 | Dead |
| `mx_Company_revenue` | 1.3% | 0% | 12 | Dead |
| `mx_Selected_Product` | 0.6% | 0% | 5 | Dead |
| `mx_Qualified_Business` | 0.4% | 0.1% | 2 | Dead |
| `mx_State` / `mx_Sub_Sector` / `mx_Marketing_Budget_monthly` / `mx_Country` | <0.2% | 0% | | Dead |
| `mx_Categoey` *(the typo duplicate)* | **0%** | 0% | 0 | **Empty everywhere. Safe to retire.** |

### `mx_Ads` - the Meta-ads flag is real

**31,198 leads filled, exactly two values: `No` 29,139 and `Yes` 2,059.** 99.7% filled on the ICP
population. It is a free-text `Textbox(50)` rather than a dropdown, but in practice it behaves as
a clean boolean, so the assumption it encodes was correct.

**2,059 accounts are confirmed to run Meta ads.** That is the population an ads-based ICP cut is
measured on, and it is large enough to survive an n>=30 cell rule across a handful of dimensions
- not across many at once.

### `mx_Category` - 55 values, and they are the right shape

Real Estate 6,596 - Food & Beverage 4,744 - Fintech 4,026 - Business Services 1,993 -
Fashion 1,916 - SaaS 1,793 - Manufacturing 1,450 - Healthcare 1,335 - Home Decor 1,321 -
Education 1,297 - Travel 1,286 - Jewellery 1,044 - ...

100% filled on the ICP population. This is the industry dimension the funnel should use.

### `mx_Industry_Type` is a dropdown-drift incident larger than the one already recorded

A `Select` field with a **15-option dropdown holding 11,515 distinct stored values, 11,503 of
them not selectable**. The stored values are a different taxonomy altogether - an MCA/CIN-style
one (`Business Services` 13,427, `Manufacturing (Food stuffs)` 4,050, `Real Estate and Renting`
3,676) mass-imported into a field whose dropdown lists `Real Estate`, `Education`,
`Manufacturing`. A handful of rows match by coincidence.

This is the same failure as the 61,919-lead Disqualification Reason incident (gotcha 10) and
**bigger**: 56,831 leads carry a value no rep can filter on. It needs a decision - convert the
field to Text, or extend the dropdown to cover the values that actually exist - and it is not
blocking, because `mx_Category` is the better dimension anyway.

---

## Part 3 - EventCode 209 "Call Disposition"

Created 2026-08-06, **not used yet** (zero events across 600 sampled leads). Its form carries:

| Field | Meaning |
|---|---|
| `ActivityEvent_Note` | **Notes** |
| `Status` | Qualified Business (Yes/No) |
| `mx_Custom_1` | Call Disposition (9 options) |
| `mx_Custom_2` | Last Call Status (Connected / Not Connected) |
| `mx_Custom_3` | Disqualification Category (the 6 canonical L1 values) |
| `mx_Custom_4` | Disqualification Reason (14 options) |

This is the first structure in this CRM that can hold **per-call disposition history** - the
lead field keeps no history at all, which `memory/12` records as permanently unrecoverable - and
a **first-class rep note**, which `memory/11` records as structurally impossible (0 captured,
ever).

It is subscribed to in advance, before it has any traffic, precisely because there is no bulk
activity read: anything not captured as it happens cannot be recovered later at any price.

**Notes are not entirely absent after all.** Of 55 sampled 203/209 activities, **4 carry a real
note** - the first evidence of any note capture in this system. All on 203, since 209 is unused.

Its disposition option list contains values the *lead field* dropdown does not offer -
`Requirement Gathering (Warm)`, `Not Interested - Wrong Contact`, `Not Interested - No Reason
Gauged`. Those are the same "non-canonical" values `memory/12` flagged as drift on
`mx_Call_Disposition`. **They may not be drift at all**; they may be this activity type, or its
predecessor 203, writing a vocabulary the lead field was never extended to accept.

---

---

## Part 4 - what the live pipeline showed once it was running (2026-08-11)

2,500 contacts' trails loaded: 16,055 touches, 5,412 assignments, 0 failures. All 9 QC checks
pass, each against something that does not share its arithmetic.

### CORRECTION: EventCode 3011 is a MIRROR, and Part 1 double-counted WhatsApp

A `3011|WhatsApp Message` carries the **same top-level `Id`** as the `201|WhatsApp Message` it
shadows; a `3011|Opportunity` the same Id as its `12000`. It is a second view of one record
under a different code, not a separate event.

Part 1 above reported "1,565 WhatsApp events (201 + 3011)". **That double counts.** The honest
event figure is the 201 count alone. Contact *coverage* (~60% of contacts carry WhatsApp) is
unaffected, because it was measured on distinct leads.

It also breaks writes: two rows sharing a primary key make PostgreSQL refuse the `ON CONFLICT`
and PostgREST returns an opaque HTTP 500. `ref_channel` now marks both 3011 rows inactive, the
loader skips the code, and `Invoke-SbUpsert` dedupes on the key as a general guard.

### Reps use exactly one channel

`v_channel_mix_rep`, over the loaded book:

| Actor | Channel | Touches | Contacts | Share of that actor |
|---|---|---|---|---|
| **System** | whatsapp | 2,885 | 2,691 | **100%** |
| Ashutosh Ojha | phone | 1,530 | 1,292 | 99.9% |
| Twinkle Sutrakar | phone | 1,450 | 1,312 | 100% |
| ...every other rep | phone | | | **100%** |

**Not one rep has a single non-phone touch.** The "full channel flexibility" in the SMB
Outreach Model is not happening. WhatsApp reaches 2,691 contacts and is entirely a broadcast
run by a system account - real volume, no attribution, and until now no measurement.

So the multi-channel question is not "which channel converts better". There is only one rep
channel. The comparison cannot be made yet, and saying so is the finding.

### Book saturation - reps are not short of leads

17,811 contacts, every one in exactly one bucket (QC-verified):

| Bucket | Count |
|---|---|
| terminal | 9,050 |
| in_progress | 3,920 |
| connected_recent (spoke within 7 days) | 1,888 |
| **never_touched** | **1,347** |
| connected_progressing | 837 |
| **one_and_done** | **337** |
| **connected_no_progress** (spoke, then silence) | **136** |
| **under_worked** | **91** |
| **saturated** (genuinely worked out) | **61** |

**61 contacts in the whole book are exhausted. 1,911 are recoverable.** The largest components
are contacts never dialled at all (1,347) and contacts dialled once and dropped (337) - not
stalled follow-ups.

Per rep the untouched pools are concentrated: Mayank Arora 206, Rahul Madaan 181, Admin 175,
adarsh pandey 142, Prakhar Gupta 136.

### A defect worth remembering: a bucket that tested state but not time

`connected_no_progress` originally meant "connected and still at Engaged", with no recency
test. First measurement: **2,024 - of which 1,888 had been connected within 7 days.** 93% of
the bucket was live conversations being labelled as neglect, which would have made the most
active reps look like the worst. The true stalled figure is 136.

Every other bucket already tested staleness; this one was written as a stage test and
inherited none of it. Migration 018 fixes it and adds a QC check asserting the fix directly,
so it cannot silently regress. Same family as counting Callkaro as rep activity, or crediting
a rep with a previous owner's calls: a definition that inverts who looks good.

## Backfill pricing (the decision this was run to inform)

| Scope | API calls | Nights at 8,000/day |
|---|---|---|
| Whole book | 91,033 | 12 |
| Workable book (Fresh/Engaged/Prospect) | 26,302 | 4 |
| Touched since 2026-08-01 | 16,092 | 3 |
| Non-call last activity only | 16,366 | 3 |

78.3% of contacts would yield at least one channel row. **Decision still open (Kaustubh,
2026-08-10).** Webhooks go live regardless, because forward capture is what turns the scope into
a choice rather than a deadline.

Related: `[[12-calling-pipeline]]`, `[[11-crm-hygiene-findings]]`,
`[[10-rep-activity-measurement]]`, `[[09-icp-assignment-programme]]`.
