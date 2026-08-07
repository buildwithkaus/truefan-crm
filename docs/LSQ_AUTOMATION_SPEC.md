# LeadSquared Automation — build spec

Native LSQ automation replaces the polling sync script as the primary mechanism. Written
2026-07-28 after confirming the required capabilities exist; revised the same day against
LeadSquared's official **Automation Feature Guide** (`help.leadsquared.com/automation-home`).

Build these in **Workflow > Automation**. Admin access required.

> **Revision note.** An earlier draft of this spec had five automations, three of which shared
> a `Lead Update` trigger. The Feature Guide shows LSQ **refuses to publish** that shape
> (pp.15-16): *"Cannot publish the automation since it creates a loop with the automation"* —
> *"you've created multiple duplicate automation triggers."* Publishing is blocked at design
> time, so this would have failed on the build day rather than in testing. The five are now
> merged into **three**. The funnel logic is unchanged; only the packaging differs, and the 46
> tests in `scripts/sync/test-sync-rules.ps1` still describe the same behaviour.

---

## Why this is buildable natively (it was previously assumed not to be)

Three findings changed the answer:

1. **`Add Opportunity` is a Lead automation action.** It creates an Opportunity on a lead with
   configurable Opportunity Type, Enquiry name, **Owner**, **Status** and **Stage**. It was
   missing from the *Opportunity* automation actions page, which is what caused the earlier
   wrong conclusion — it lives under **Lead** actions, because it acts on a lead.
2. **`Update Account` is a Lead automation action.** LSQ's own documentation gives our exact
   use case: *"automatically transitioning an account's stage from 'Prospect' to 'Customer'
   when the associated lead's stage changes."* This resolves Lead -> Company. Requires admin
   access and an automation configured with **lead and account based triggers**.
3. **Opportunities are activities on the lead.** Verified live on this account: leads with an
   Opportunity carry activities `12000 | Opportunity` and `33 | Opportunity Captured` on their
   own timeline. So an opportunity change is observable from a **Lead** automation — which has
   both `Update Lead` and `Update Account`. The feared three-hop traversal
   (Opportunity -> Lead -> Company) is not needed at all.

Point 3 is the important one. It means every rule in the funnel can be driven from Lead
automations, where all the actions we need already exist.

---

## The three automations

Naming convention `TF-Stage-*` so they group together in the automation list.

**Every condition must be set to evaluate `Latest Data`, not `Triggered Data`** — see the loop
section. This is not optional and is easy to miss, because `Triggered Data` looks equally
correct on screen.

### AUT-1 — First activity moves Fresh to Engaged

| | |
|---|---|
| **Trigger** | New Activity on Lead (any activity type), **`Run only once per lead` CHECKED** |
| **Condition** | Lead Stage **is** `Fresh` *(Latest Data)* |
| **Action 1** | Update Lead -> Lead Stage = `Engaged` |
| **Action 2** | Update Account -> Stage = `Nurture` |

Two independent guards, deliberately. `Run only once per lead` makes re-firing structurally
impossible; the `is Fresh` condition makes it logically impossible. Keep both — without them,
every follow-up call on a live deal drags the contact back to Engaged and the account back to
Nurture, which is the single most damaging thing that can go wrong in the whole set.

### AUT-2 — Lead stage drives the deal and the account

**This is the merge of the old A2, A4 and A5.** One trigger, branched — not three automations
sharing a trigger, which LSQ will not publish.

| | |
|---|---|
| **Trigger** | Lead Update, scoped to the **Lead Stage** field only |
| **Branching** | Multi If/Else on Lead Stage *(Latest Data)* |

| Lead Stage | Guard | Actions |
|---|---|---|
| **`Prospect`** | `If Opportunity Exists` = **No** | Update Lead -> `IsPrimaryContact` = true; **Add Opportunity** (Type `Opportunity` / code 12000, Status `Open`, Stage `Prospect`, Owner = lead owner); Update Account -> `Opportunity` |
| **`Prospect`** | `If Opportunity Exists` = Yes | **Exit** — the deal already exists; this is the re-entry path from AUT-3 |
| **`Disqualified`** | — | Update Account -> `Future Prospect`; Update Account -> `Future Prospect Reason` = mail merge from the lead's `Disqualification Category` |
| **`Engaged`** | Account Stage **is** `Fresh` | Update Account -> `Nurture` |
| **`Customer`** | `If Opportunity Exists` = **No** | Update Lead -> `IsPrimaryContact` = true; **Add Opportunity** (Status `Won`, Stage `Payment Received`); Update Account -> `Customer` |
| **`Customer`** | `If Opportunity Exists` = Yes | Update Account -> `Customer` |

The `Prospect` branch is where the whole design turns: it is the manual rep decision from the
SOP. The rep sets one field; the deal, the primary-contact flag and the account stage all
follow.

The `Engaged` branch is the safety net for accounts left at `Fresh` when a contact was moved
to `Engaged` by hand rather than by AUT-1's activity trigger.

The `Customer` branch handles a rep jumping a contact straight to `Customer` without ever
passing through `Prospect` — rare, but it would otherwise leave a paying account with no deal
record and no revenue attached to it. This matches `Get-OpportunityStageForNewDeal` in
`sync-rules.ps1`, which creates the deal already Won for exactly this case.

### AUT-3 — Opportunity stage drives contact and account

| | |
|---|---|
| **Trigger** | Activity Update on Lead, activity type = **Opportunity (12000)** |
| **Branching** | Multi If/Else on the Opportunity `Stage` field (`mx_Custom_2`) *(Latest Data)* |

| Opportunity Stage | Update Lead -> Stage | Update Account -> Stage |
|---|---|---|
| Prospect / In Discussion / Agreement Sent / Invoice Sent | `Prospect` | `Opportunity` |
| **Payment Received** | **`Customer`** | **`Customer`** |
| Customer | `Customer` | `Customer` |
| Closed - Lost | `Disqualified` | `Future Prospect` |

Activity automations can trigger on activities posted against **accounts, leads or
opportunities**, so this trigger shape is supported. Use the **Multi If/Else** card rather than
four separate automations — LSQ shipped a Triggered Activity filter for exactly this, and it
avoids the duplicate-trigger problem.

---

## Loop prevention — read before building

LSQ automations trigger each other: `Update Lead` fires the `Lead Update` trigger, which can
re-run an automation, which updates the lead again. LSQ takes this seriously enough to **block
publishing** configurations it believes can loop, so this is a build-time concern, not just a
runtime one.

### The five rules

1. **Never give two automations the same trigger.** This is the one that blocks publishing.
   The Feature Guide's support thread shows the exact failure — *"multiple duplicate automation
   triggers... can't run as it could cause an infinite loop."* It is why A2/A4/A5 are now the
   single branched AUT-2.
2. **Every branch must be conditioned on the state it is leaving, not the state it is
   entering.** AUT-1 fires only when the stage *is* `Fresh`, so once it writes `Engaged` it
   cannot re-fire.
3. **All conditions must use `Latest Data`, never `Triggered Data`.** `Triggered Data`
   evaluates the field's value *at the moment the automation fired*; `Latest Data` evaluates
   its *current* value. A guard on `Triggered Data` reads stale state and fires anyway,
   silently defeating rules 2 and 4. Both options look equally plausible in the UI — this is
   the easiest correctness bug to introduce here.
4. **Guard the `Prospect` branch with `If Opportunity Exists`.** AUT-3 writes the Lead Stage,
   and AUT-2 triggers on it — so AUT-3 setting `Prospect` re-enters AUT-2. With the guard, the
   second pass finds an existing Opportunity and hits `Exit` instead of creating a duplicate
   deal. This is the designed re-entry path, not an accident.
5. **Scope AUT-2's trigger to the Lead Stage field specifically**, not "any field update".
   Otherwise the disqualification-reason write re-triggers AUT-2 on itself.

### Built-in backstops

- **50 triggers per lead per day auto-terminates the automation.** LSQ's own circuit breaker.
  Note the wording: it *terminates*, it does not throttle — so a runaway loop does not just
  spin, it silently stops working for the affected records. Check the **Automation Termination
  Report** for anything appearing there.
- **`Exit` action** removes a lead from the flow when conditions are met, and no further actions
  run for that lead. Cleaner than an empty else-branch on the guarded `Prospect` path.

### If AUT-3 still will not publish

Rule 4 makes the loop harmless at runtime, but LSQ's detector may be **static** — analysing
structure rather than conditions — and still refuse the AUT-2/AUT-3 pair. If that happens:

1. Try inverting AUT-3's write so it targets a staging field rather than Lead Stage directly.
2. Failing that, use a **Lapp** — LSQ's serverless functions can update lead fields and are
   callable from an automation, which breaks the static trigger chain. The Feature Guide
   confirms this pattern for exactly this class of problem.
3. Last resort: keep AUT-1 and AUT-2 native and run the opportunity-to-contact leg from
   `sync-engine.ps1`. That leg alone is a fraction of the work and the script already handles it.

### After go-live

Leave it running 24h, then check the **Automation Report** execution counts against the real
number of stage changes. Counts far above it mean a loop. Also check the **Automation Failure
Report** and **Automation Termination Report** — both are native and neither is on by default
in anyone's routine, which is the actual risk.

### Rolling back an automation

Unpublishing offers **Immediate** (stops all in-flight leads now) or **Delayed** (drains the
leads already in the workflow, admits no new ones). Use Immediate if an automation is doing
damage. Note that a **deleted automation cannot be restored** — unpublish rather than delete.

---

## These must be built by hand — there is no automation API

**Confirmed 2026-07-28 against the live account.** Thirteen candidate endpoints were probed
(`Automation.svc/*`, `AutomationManagement.svc/*`, `Workflow.svc/*`, `WorkflowManagement.svc/*`,
`MarketingAutomation.svc/*`, `Automation/*`) — **every one returned 404**, while the control
call `LeadManagement.svc/LeadsMetaData.Get` returned 200, proving auth and host were correct.
apidocs.leadsquared.com has no Automation or Workflow category at all.

So these three automations are a **UI build**, like the Opportunity Type was. Budget ~1 hour.

What *can* be automated is the verification: `scripts/sync/test-automations-live.ps1`
runs the whole test plan below end to end against a real throwaway lead and reports which
automations fired correctly. Build by hand, verify by script.

*(A Webhooks API does exist with full CRUD, which would allow an external service to react to
lead events instead. Not used here — it needs a hosted endpoint to receive the callbacks, which
this project does not have, and native automation is the better answer anyway.)*

## What to verify while building

Two remain. Four are resolved: `Add Opportunity` **can** set Owner dynamically from the contact
owner and the publish limit is not a constraint (both confirmed by Kaustubh, 2026-07-28);
`If Opportunity Exists` is a documented condition; and activity automations do trigger on
activities against accounts, leads or opportunities.

| # | Check | If it fails |
|---|---|---|
| 1 | `Update Account` appears with a **New Activity on Lead** trigger (AUT-1) | Drop the account half of AUT-1; AUT-2's `Engaged` branch already covers it |
| 2 | `Update Account` can mail-merge a value **from the lead** (the disqualification reason) | Set a static reason, or keep the reason on the lead only |

Neither is build-blocking — both have a working fallback, and the test harness will show you
immediately if either one silently did nothing.

---

## Test plan — before switching on for all 18 reps

**This is scripted**: `scripts/sync/test-automations-live.ps1 -Execute` runs the
whole table below against a throwaway account and reports pass/fail per check.

Worth using rather than clicking through it, because automations are **asynchronous** — "I
changed the stage and nothing happened" is indistinguishable by eye from "it had not fired
yet." The script polls with a timeout instead of guessing, and it asserts the three
*negative* cases (steps 3, 5, 8) that a human checking by hand naturally skips, since there is
nothing to look at when the correct outcome is "nothing moved."

It creates 2 leads, 1 company and 1 opportunity, all tagged `TESTAUTO-<timestamp>`. Delete
them in the UI afterwards — opportunities cannot be deleted via API (`CanDelete: false`).

The steps, if you would rather do it by hand on **one real account with two contacts**:

| Step | Do | Expect |
|---|---|---|
| 1 | Create a fresh test lead with a company | Contact `Fresh`, Company `Fresh` |
| 2 | Log any activity | Contact `Engaged`, Company `Nurture` |
| 3 | Log a second activity | **No change** — the AUT-1 guards hold |
| 4 | Set Contact Stage = `Prospect` | Opportunity created at `Prospect`, `IsPrimaryContact` set, Company `Opportunity` |
| 5 | Log another activity | **No change** — contact stays `Prospect`, no second deal |
| 6 | Move Opportunity to `Invoice Sent` | Contact stays `Prospect`, Company stays `Opportunity` |
| 7 | Move Opportunity to `Payment Received` | Contact `Customer`, Company `Customer` |
| 8 | Add a second contact at the same account, set it to `Prospect` | **No second Opportunity** — the `If Opportunity Exists` guard sends it to `Exit` |
| 9 | Move the Opportunity to `Closed - Lost` | Contact `Disqualified`, Company `Future Prospect` |
| 10 | Check the Automation Report execution counts | Roughly one execution per real change, not hundreds |
| 11 | Check the Automation Termination Report | **Empty.** Anything here means a lead hit the 50-trigger cap — a loop |

Steps 3, 5, 8 and 11 are the ones that matter — the regression guards. Steps 3, 5 and 8 are the
same cases as the 46 offline tests in `scripts/sync/test-sync-rules.ps1`, so the
expected behaviour is already pinned down precisely; run those tests to see the intended
semantics before building.

---

## What happens to the sync script

It stops being the mechanism and becomes the **safety net**, which is a better use for it:

| Script | New role |
|---|---|
| `sync-engine.ps1` | Not scheduled. Kept for the one-off `-FullScan` backfill and as fallback if verification check 1 fails or AUT-3 will not publish |
| `validate-consistency.ps1` | Nightly drift detector. LSQ's native Failure/Termination reports cover *whether an automation errored*; this covers **whether the data is actually right** — cross-object checks no single-object report can make (a contact at Prospect with no deal, an account with two primary contacts). Complementary, not redundant |
| `test-sync-rules.ps1` | The executable specification of intended behaviour. The automation build must agree with it |
| `report-reactivation.ps1` | Unchanged - Supply Gap / Commercial Mismatch mining |

Automations only act on records that change *after* they are switched on. Existing records are
still migrated by the one-command migration, not by automation.

LSQ also has an **`At Regular Intervals`** automation type, so some reconciliation could in
principle move native. Not recommended for the consistency check — it needs to compare state
across Lead, Company and Opportunity and emit an auditable report file, which the script does
and a single-object automation does not.

---

## Build order

```
[ ] 1. MANUAL_STEPS.md 1-5 complete (stage values must exist before any automation references them)
[ ] 2. Migration run and verified
[ ] 3. Build AUT-1, publish
[ ] 4. Build AUT-2, publish        <- set every condition to LATEST DATA as you go
[ ] 5. Build AUT-3, publish
[ ] 6. pwsh ./scripts/sync/test-automations-live.ps1 -Execute
[ ] 7. Fix anything it reports, re-run until clean. Delete the TESTAUTO-* records in the UI
[ ] 8. After 24h: Automation Report execution counts + Termination Report + Failure Report
[ ] 9. Rep briefing
[ ] 10. Make activity fields mandatory
[ ] 11. Schedule validate-consistency.ps1 nightly
```

Automations must be built **after** the migration, not before — otherwise they fire on 86,628
records mid-migration.

Set every condition to `Latest Data` as you build each card. Retrofitting that across finished
Multi If/Else branches is tedious and easy to miss one.

---

## Sources

- **Automation – Feature Guide** (`help.leadsquared.com/automation-home`, PDF reviewed
  2026-07-28) — automation types incl. `At Regular Intervals`; the 50-triggers-per-lead-per-day
  auto-termination; `Run only once per lead`; `Latest Data` vs `Triggered Data`; the `Exit`
  action; Immediate vs Delayed unpublish; deleted automations are unrecoverable; publish limits
  vary by plan; the Failure / Termination / Usage / per-object reports; and the support thread
  showing **duplicate triggers block publishing**, which is why this spec has three automations
  rather than five
- [Lead Automation Actions – Lead Actions](https://help.leadsquared.com/automation-actions-lead-actions/) — `Add Opportunity` with Type/Enquiry/Owner/Status/Stage
- [Lead Automation – Account Update Actions](https://help.leadsquared.com/lead-automation-account-update-actions/) — `Update Account`, and the stage-transition example
- [Triggers in Lead, Opportunity, Activity and Task Automations](https://help.leadsquared.com/triggers-lead-automation/) — no dedicated stage-change trigger; use `Lead Update` scoped to the stage field
- [Opportunity Automation Actions](https://help.leadsquared.com/opportunity-automation-actions/) — confirms opportunity automations do **not** offer Update Lead / Update Account, which is why AUT-3 is built as a Lead automation
- [Actions in LeadSquared Automation](https://help.leadsquared.com/actions-in-leadsquared-automation/) — action categories, incl. Custom/webhook and Lapps
- Opportunity-as-activity on the lead timeline: verified live on this account, 2026-07-28
