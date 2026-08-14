# Why leads don't buy — the disqualification analysis (2026-08-13)

Asked: of ~91k contacts, ~61.6k are Disqualified and 98% carry a reason, 42% of them
`Not Interested - No Reason Stated`. Is that a lead-quality/ICP problem, a prospecting
problem, or something else?

Scripts: `scripts/reports/disqualification-deep-dive.ps1` (full-book scan),
`disq-call-evidence.ps1` (rep-made disqualifications + call timelines),
`disq-one-call-cohort.ps1` (the one-connected-call cohort),
`export-disqualification-workbook.ps1` and `export-onecall-workbook.ps1` (Excel).

---

## 1. The reason field is a relabelled legacy stage, not diagnosis

Full live scan, 91,056 contacts, reconciles exactly, negative control passed:

| Contact Stage | Count | % |
|---|---|---|
| Disqualified | 61,595 | 67.6% |
| Engaged | 20,895 | 22.9% |
| Fresh | 4,389 | 4.8% |
| Future Prospect | 2,771 | 3.0% |
| Prospect | 1,189 | 1.3% |
| Customer | 196 | **0.2%** |

**96.7% of disqualifications (59,572) carry a reason that is a rename of the legacy
`ProspectStage` value the contact already held** before the July restructure. Only 1,704
(2.8%) were disqualified *from* a live working stage. Proven from
`mx_Previous_Contact_Stage`, which the migration backfilled across the book: every reason
string maps 1:1 onto exactly one legacy stage, counts differing by <2%
(`Just Enquiring - No Intent` 2,697 vs legacy `Just Enquiring, No Intent` 2,693).

So "98% have a reason" measures how completely the migration ran. It is not sales feedback.

Reason split (of 61,595): No Reason Stated 25,626 (42%) · Invalid/Not a Business 16,972 (28%)
· Low Budget 5,758 (9%) · Invalid Contact Data 4,875 (8%) · Just Enquiring 2,697 (4%) ·
No Celebrity Requirement 1,983 (3%) · everything else + blank 3,684 (6%).

## 2. Reps are NOT quitting early — a corrected figure

An earlier pass reported "leads written off after **1.38 calls**". That was wrong: it counted
only calls inside the warehouse window (from 1 Aug) rather than each contact's full history.
Measured across complete trails for all 1,520 contacts a **named rep** moved to Disqualified
between 1–13 Aug (Kaustubh's 1,114, Admin's 113 and 1,859 blank-actor bulk writes excluded,
including the 3,021-row sweep on 11 Aug):

- **4.92 calls** on average before a write-off; only 0.7% got none; 47.6% got 5+
- **92.8%** connected at least once first
- **88.6%** disqualified straight after a **connected** call, **93.8%** within one hour
- **43.1% (655)** had exactly one connected call, averaging 49s
- Previous stage: Fresh 54%, Engaged 41.7%, Prospect 3.4%

Reps dial persistently, reach the person, and mark the outcome immediately. The judgement is
sound; the input is not.

## 3. What the disqualifying calls actually say

200 disqualifying calls read in full from the cohort that is **Disqualified + reason
`Not Interested - No Reason Stated` + exactly one connected call + transcribed** (pool: 25,626
on that reason → 1,965 whose last activity was a call since 1 Jul → 723 with one connected
call → 314 transcribed → 200 sampled, fixed seed):

| Family | n | % |
|---|---|---|
| **No reason was obtainable** | 96 | **48%** |
| Should never have been called | 47 | 23.5% |
| Genuine commercial reason | 22 | 11% |
| No requirement right now (soft) | 21 | 10.5% |
| **Our own process lost it** | 14 | **7%** |

Top single reasons: refused on the spot with no reason (66, 33%) · no real conversation
possible — call cut, language (30, 15%) · no requirement now (21) · wrong person or not a
business (15) · runs no marketing at all (14).

**The label is largely honest.** Half these calls genuinely produced nothing to record — a
20–30 second cold call ending in "not interested, thank you". No process change extracts a
reason that was never given.

**Price appears 3 times in 200.** It is not the story in this cohort.

Structurally-impossible prospects are the sharp end of the 23.5%: a Tanishq franchisee who
cannot advertise the brand, an insurance broker barred by IRDA, a chartered accountant barred
by his own body, B2B-only manufacturers, marketplace-only sellers, a retired man, a Shopify
employee, someone who answered "मैं 12th pass हूँ".

## 4. The 7% we lose ourselves — the actionable part

Verbatim, from the recordings:

- *"I think we already deal with your company, so don't call me directly."* — an **existing
  customer**, cold-called and then disqualified.
- *"बीच में TrueFan का connect ही कट गया था"* — a **Prospect-stage partner** who stopped
  selling because we stopped calling.
- *"वो तो complete हो गया… हमने book कर लिया है। उस time पर कोई revert नहीं आया"* — **lost to
  a competitor because nobody followed up.**
- *"I raised the inquiry but I couldn't get proper answers and feedback, so I kept that to a
  side."*
- *"मैंने पहले भी unsubscribe वाला button… वो करा हुआ है"* and *"do not disturb 16 साल से है"*
  — opt-outs that do not suppress dialling (5 of 200).
- Nine asked for a proposal, samples or a callback and were marked Not Interested anyway.

## 5. ICP: enrichment bought reachability, not demand

Time-matched (numerator and denominator both 1–13 Aug, so older sources cannot bank prospects
earned before the call window): baseline prospect rate 4.6%. No industry, city or "runs Meta
ads" signal separates buyers. Across all 24 industries with n≥300 on the full book, the share
ever reaching Prospect/Customer runs **0.3%–2.0%**; the *unenriched* inbound population sits at
1.9%, as good as anything deliberately targeted. `mx_Ads = Yes` gives +7pp connect and no
conversion lift. The ICP list has the **best connect rate in the book (53.8%)** and
below-baseline conversion — and is the cleanest list by far (0.4% junk vs 31% on FB Lead Ads).

## 6. Lead quality is a channel problem, upstream of sales

Whole book, by source: FB Lead Ads 36,651 contacts / 79.9% disqualified / **31% marked
"Invalid — Not a Business"** (11,372) / 97 customers. Inbound Phone call **47.9%** invalid.
01_enterprise_truefan_in 44%. Website-ai-ad 31.8%. Kaustubh ICP **0.4%**.

## 7. The deal book has never recorded a loss

1,498 opportunities: 154 Won, **0 Lost, ever**; `loss_reason` 0% filled; 1,202 still sitting on
the first stage; 62 open deals on already-disqualified contacts. Deals are abandoned, not lost.

## 8. Disposition capture is still ~zero

21,088 calls since 1 Aug, **7,143 connected conversations, none carrying a disposition** in the
warehouse. EventCode 209 exists and is now used on **3%** of rep-disqualified contacts (46 of
1,520) — real values, tiny volume. And **923 of those 1,520 rep-made disqualifications left the
reason field blank entirely** (61%); only 226 chose `Not Interested - No Reason Stated`.

## What to do (ranked, each traced to a finding above)

1. **Qualify the list before it reaches a rep** — trading status, B2B-only, regulated sectors,
   franchisees, contact-to-company check. ~23.5% of dialled calls in the one-call cohort could
   never have bought. Biggest lever, sits entirely outside the sales team.
2. **Put call history, current stage and opt-out status on the dialler screen.** We are
   cold-calling our own customers and people who unsubscribed.
3. **Add monthly ad spend as a qualifying field**, at the ₹1–2 lakh bar reps already apply
   informally (one rep worked it out mid-call and disqualified on it unprompted).
4. **Make disposition + a one-line note mandatory on a connected call**, and add the values the
   transcripts show: *Cannot advertise (regulated/franchisee)*, *Below budget*, *Wrong contact*,
   *Already a customer*, *No decision — material sent*.
5. **Make Closed-Lost a real stage with a mandatory reason**; close the 62 open deals on
   disqualified contacts.
6. **Do not** push reps to call more or disqualify less. On this evidence they are the part of
   the system working properly.

## Method notes worth keeping

- The disqualifying call = last call at or before the stage change, +2h grace. See gotcha 41
  for why the first attempt at this was invalid.
- Population is trail-derived via EventCode 3002 where the warehouse cannot reach (gotcha 40).
- Transcript coverage is 31.6% and skews connected — section 3 reads the transcribed slice
  (gotcha 39). The structural figures in section 2 have no such gap: they cover all 1,520.
- Workbooks: `data/TrueFan_Disqualification_Analysis.xlsx` (10 sheets, all 1,520 + the 7,553-row
  call timeline) and `data/TrueFan_OneCall_NotInterested_200.xlsx` (the 200-contact sample,
  master with reasons, rep × reason).
