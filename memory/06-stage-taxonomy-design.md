# Stage taxonomy — target design

Splits the single overloaded `ProspectStage` field into four layers, each answering one
question. This is the core of both prior email plans, unified.

| Layer | Lives on | Answers | Status |
|---|---|---|---|
| Contact Lifecycle Stage | Lead (`ProspectStage`, redefined) | Have we reached this person, are they engaged? | Redesign — additive migration, see below |
| Activity Disposition | Activity | What happened on the last touch? | Mostly already correct — activity custom fields (Status: Connected/Not Connected, Next Step, etc.) already do this well |
| Opportunity Stage | Opportunity (new object) | Where is this specific deal in its cycle? | New build, see `03-object-model-and-relationships.md` |
| Company Stage | Company (`Stage`, exists) | Has this account ever converted? | Should become a rollup off Opportunity, not manually set — open technical question, see `08-open-decisions.md` |

## Lead lifecycle stage — target list (6 states)

Fresh Lead → Contacted → Engaged → Requirement Gathering (Warm) → Hot → Converted to
Opportunity, plus a terminal Disqualified state.

## Migration mapping for the current 26 `ProspectStage` values

See `01-lead-schema-audit.md` for the full current-state list. Mapping:

- **Kept, renamed if needed**: Fresh Lead, Requirement Gathering (Warm), Conversation In
  Progress (Hot) → Hot
- **Moves to a new `Call Disposition` field** (on the lead's last-touch, or captured at
  activity level going forward): RNR, Didn't Picked, Call me Later, Switched Off/Not
  Reachable, Wrong Number
- **Moves to a new `Disqualification Reason` field** (paired with a single `Disqualified`
  lifecycle stage): Low Budget, Supply Issue, Conflict, No Requirement of Celeb in Ads,
  Does not want AI, Just Enquiring No Intent, Invalid/Junk, Not Active After First
  Conversation, B2B-Disqualified
- **Moves to Source/Segment attributes** (not a stage at all): SaaS, FB Lead - Website,
  Retargetedlead, RetargetedleadEMAIL, ReQualified By WhatsApp
- **Becomes Converted to Opportunity**: Payment Received, Future Prospect (arguable —
  Future Prospect may belong in lifecycle stage rather than converted; not fully resolved,
  flag for a human call before migrating this one)
- **Follow Up**: ambiguous — currently used both as a genuine stage and as a disposition.
  Needs a decision before migration (see `08-open-decisions.md`).

## Migration approach — Lead object is live, additive only

Per `CLAUDE.md`: do not delete or repurpose `ProspectStage` or its values while reps are
actively selecting from that live dropdown. Sequence:

1. Add the new fields (`Call Disposition`, `Disqualification Reason`) alongside the
   existing `ProspectStage` — reps keep using the old field during transition.
2. Backfill the new fields from historical `ProspectStage` values using the mapping above
   (a script, not manual re-entry).
3. Only after reps are trained onto the new fields (see SOP/training workstream in
   `PROJECT_PLAN.md`) does `ProspectStage` itself get cut over to the clean 6-value list
   and the old values get retired.

Do not attempt step 3 before reps are trained — that's the "be careful" instruction this
whole approach is built around.
