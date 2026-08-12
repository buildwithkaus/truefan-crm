# SOP — How You Work Your Pipeline

For: TrueFan sales reps. Effective from the changeover date announced in your briefing.
Questions: Kaustubh Chauhan (Founder's Office).

> **Status note for whoever runs the briefing (delete before circulating).** The data migration is
> done and the five stages are live. The **automations described in Part 1 are not built yet** —
> `Fresh` -> `Engaged` on first activity, and auto-creation of the deal record at `Prospect`, are
> still manual. Either build them first or tell reps to set the stage themselves in the interim.
> Do not hand this out claiming automation that is not running. See
> `docs/HANDOVER_2026-07-31.md` section 8.

---

## What changed, in one paragraph

You used to record everything in one field — **Lead Stage** — which had 28 options mixing
three unrelated things: what happened on your last call, why a lead was dead, and how far
along the relationship was. From now on the Lead Stage has **five** options and does one job:
it says how far along the relationship is. What happened on the call, and why a lead is dead,
move to their own fields.

The practical effect: a lead who did not pick up the phone no longer looks the same as a lead
who told you no. About **17,000 leads** were sitting in that confusion — they looked dead, but
they were only un-dialled. Those are coming back into your queues.

---

## The six contact stages

```
Fresh  ->  Engaged  ->  Prospect  ->  Customer
                    |
                    +->  Future Prospect (reason required)   right business, wrong time
                    |
                    +->  Disqualified    (reason required)   out of play
```

| Stage | Means |
|---|---|
| **Fresh** | **Nobody has dialled this contact yet.** This is your hunting pool for new accounts to call. |
| **Engaged** | You have started working this contact. Either you reached a human, or you dialled and did not get through — **Call Disposition tells you which.** |
| **Prospect** | There is a real deal here. A deal record gets created automatically. |
| **Customer** | Payment received. |
| **Future Prospect** | **Right business, wrong time.** They would buy, just not now. Still yours, still coming back. **Reason required.** |
| **Disqualified** | Out of play. **Reason is mandatory.** |

> **`Future Prospect` and `Disqualified` are not the same thing**, and the difference is the
> one that pays you back. A future prospect is an account you will work again when the timing
> changes. A disqualified contact is done. If you mark a "call me next quarter" as
> Disqualified, nothing brings it back to you.

**You own this field.** Two of the moves happen for you; one is your judgement call.

---

## Part 1 — Fresh to Engaged happens automatically

The first time you log **any** activity against a contact — a call, an email, a WhatsApp,
anything — the system moves them from `Fresh` to `Engaged` on its own. Their company moves
from `Fresh` to `Nurture` at the same time.

You do not need to do anything. Just **log the activity**.

This works in one direction only. Once a contact is a `Prospect`, logging another call will
never drag them back to `Engaged`.

### Still log the call outcome properly

Every call gets an activity with an outcome. If it is not logged, it did not happen, and the
contact drops out of your follow-up queue.

**Not Connected** -> pick the reason: Switched Off, Not Reachable, Wrong Number/Junk, RNR,
Did not pick.

> Important: **not reaching someone is not a rejection.** They stay in your queue with a
> callback date. Do not disqualify a lead just because they did not answer.

**Connected** -> record what came of it, and set your Next Step and follow-up date.

---

## Part 2 — Engaged to Prospect is YOUR call

This is the one move you make by hand, and it is the most important decision in the system.

> **When you judge there is a real deal here, set the Contact Stage to `Prospect`.**

There is deliberately no automatic trigger for this. No single call outcome reliably means
"this is a real deal now" — so it is your judgement, not a dropdown's.

Move to `Prospect` when the brand has told you what they actually want: they are looking for
an endorsement, broadly okay with base pricing, and there is a real campaign in view. Anything
softer than that is still `Engaged`.

The moment you set it, the system automatically:

- makes you the **primary contact** for that account
- **creates the Opportunity** at stage `Prospect`
- moves the **company** from `Nurture` to `Opportunity`

You never create a deal by hand. You never edit the company stage. You make one judgement call
and the pipeline builds itself.

---

## Part 3 — Working the deal

Once the Opportunity exists, you drive **the Opportunity Stage**. The contact and company
follow it automatically.

| Stage | Move it here when |
|---|---|
| **Prospect** | Requirement gathered, nothing proposed yet. *(Set for you automatically.)* |
| **In Discussion** | Actively working celebrity / product / pricing with them. |
| **Agreement Sent** | Contract has gone to the client. |
| **Invoice Sent** | Proforma invoice raised. |
| **Payment Received** | Payment has landed. **The contact and company become `Customer` at this point.** |
| **Customer** | Contract fully active, delivery underway. |

### Agreement and Invoice in either order

Sometimes the contract goes first, sometimes the PI does. Both are fine. Two rules:

1. **Always stamp the date field** for whichever you sent — `Agreement Sent Date` or
   `Invoice Sent Date`. Both get filled in eventually, in whatever order they happen.
2. **The Stage only ever moves forward.** If you invoiced first, set Stage = `Invoice Sent`.
   When the agreement follows, stamp `Agreement Sent Date` but **leave the Stage alone** — it
   is already further along.

A deal never moves backwards. If something falls through, that is a Lost outcome with a
reason, not a downgrade.

### Payments in instalments

A contract may be collected across several payments as deliverables ship. Log each one as it
lands with `Amount Received`, `Total Amount` and `Pending Amount`. Keep `Total Amount` as the
**full contract value on every entry** so Pending stays correct. You are not responsible for
delivery — you are responsible for the collection record being true.

---

## Part 4 — Disqualifying properly

You must give a reason. Pick the **category** first — it decides whether we ever come back:

| Category | Use when | What happens to the account |
|---|---|---|
| **Not ICP Fit** | They will never want this — wrong business type entirely (B2B software, not a real business, no interest in celebrity endorsement in any form) | Closed off. Not worked again. |
| **No Requirement** | Right kind of business, no need right now | Comes back on a revisit date |
| **Commercial Mismatch** | They want it, the price does not work | Comes back if pricing changes |
| **Supply Gap** | They want it, our celebrity list does not cover it | **Comes back the moment we sign a relevant celebrity** |
| **Unreachable / Bad Data** | Wrong number or bad details — but the business is real and qualified | Account stays open, flagged to find a better contact |
| **Not Interested** | Heard the pitch, said no | Comes back at low priority |

Then pick the specific reason underneath it.

**Be honest with the category.** "Not ICP Fit" is permanent — it removes the account from
everyone's list for good. If they merely have no budget this quarter, that is Commercial
Mismatch, and it comes back to you.

### The one that pays you back

`Supply Gap` and `Commercial Mismatch` are the closest thing to free pipeline you have. Every
new celebrity we sign and every pricing change turns some of those accounts live again, with
no prospecting. That only works if you tagged them correctly on the way out.

---

## Part 5 — Accounts with several contacts

One company can have several people in it.

- Only **one contact per account owns the deal** — the primary contact. That is whoever you
  first moved to `Prospect`. The system sets it.
- Other contacts at the same account are **stakeholders**. Work them, log calls, move them to
  `Engaged` — but they do not each get their own deal.
- If a second person at an account reaches deal stage while a deal is already open, **do not
  open a second deal.** Add them as a stakeholder, or ask for the primary contact to be
  switched if they are the real decision-maker.

Five people at one company is not five opportunities. It is one opportunity with five people
in the buying committee — a stronger deal, not a bigger number.

> **This applies to everyone, starting the same day.** There is no legacy option to keep
> working the old way — the five stages above are the only stage field from the changeover
> date on. What changes is *where* the detail goes: call outcome and disqualification reason
> now live in their own fields instead of being crammed into the stage.

---

## Quick reference

**Log every activity.** First one moves the contact to `Engaged` automatically.

**`Fresh` -> `Engaged`** — automatic, on first activity.

**`Engaged` -> `Prospect`** — **your judgement call.** Set it when there is a real deal.
Creates the Opportunity and moves the company for you.

**After that** — drive the Opportunity Stage only. Stamp Agreement/Invoice dates whenever they
happen, in any order. Stage only moves forward.

**Payment Received = Customer.** Contact and company both flip automatically.

**Disqualifying** — category first, then reason. "Not ICP Fit" is permanent; use it carefully.

**Not reached is not rejected.** RNR, did not pick and switched off move a lead to `Engaged` with
that outcome in **Call Disposition** — still fully in your queue, just no longer clogging `Fresh`.
`Fresh` is reserved for contacts nobody has dialled yet, so it stays useful as a hunting pool.

**One account, one deal.**

---

## What you should stop doing

- Using stage values as call outcomes ("Didn't Picked", "RNR", "Follow Up") — those are now
  the call's own fields.
- Using stage values as reasons ("Low Budget", "Supply Issue", "Conflict") — those are now the
  Disqualification Reason.
- Editing the company stage by hand. It follows your contact stage.
- Creating deals manually. Moving a contact to `Prospect` does it.
- Keeping your pipeline in a personal sheet. If the CRM does not show your pipeline correctly
  after this change, that is a bug worth reporting — not a reason to rebuild the sheet.

That last one matters. The sheets exist because the CRM could not answer "what is my account
list and where does each one stand." It can now. If it cannot for your book, say so, and it
gets fixed.
