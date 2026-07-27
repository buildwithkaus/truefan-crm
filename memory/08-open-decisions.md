# Open decisions — need a human call, not resolvable from data alone

- **`mx_Budget` vs `mx_Marketing_Budget_monthly`** both feed the proposed
  `Budget_Company` field. Same number in different units, or genuinely two different
  things? Unresolved — check with whoever owns lead-form field design before backfilling
  `Budget_Company`.
- **Havishma Haranath vs Havishma H** — two different LSQ OwnerId GUIDs. Same person with
  two accounts (data hygiene issue, worth merging) or two different people? Not resolved.
- **`Follow Up` stage value** is used ambiguously today — sometimes as a genuine lifecycle
  stage, sometimes as a call disposition. Needs a decision before the stage-taxonomy
  migration (`06-stage-taxonomy-design.md`) can cut over this specific value.
- **Company.Stage as automated rollup** — can LeadSquared's native automation traverse
  Opportunity → Lead → Company to update a Company field, or does this need a scheduled
  API job instead? Not validated either way; validate with LeadSquared support or a
  sandbox test before committing to native automation.
- **897 live-stage leads reassigned to Admin** (see `05-departed-owner-reassignment.md`) —
  Admin isn't a working account. This was a deliberate short-term call (blanket transfer
  simplicity over cherry-picking), but it should be revisited once the account-based
  rep-assignment model is live, so these don't sit dead indefinitely.
- **"Future Prospect" and "Payment Received"** in the old `ProspectStage` list — do they
  map to a lifecycle stage or to "Converted to Opportunity"? Flagged in
  `06-stage-taxonomy-design.md`, not fully resolved.
