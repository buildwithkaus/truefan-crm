# Apps Script files — which goes where

**Apps Script concatenates every `.gs` file in a project into ONE global scope, and the last
definition of a name wins.** There is no module system and no warning. Two files that both
define `doPost` or `TABS` will silently disagree, and which one wins depends on the file order
in the editor — something nobody thinks to check.

That makes "which file is in which project" a correctness question, not housekeeping.

## The two live projects

| File | Project | Role |
|---|---|---|
| `CallingPipeline.gs` | **the pipeline** | Everything. Receives webhooks, normalises, upserts to Supabase, enriches leads, renders every tab. |
| `WebhookCapture.gs` | **a separate, throwaway project** | Records raw webhook payloads to a sheet so an unknown shape can be read. Used by `scripts/pipeline/01-manage-webhooks.ps1 -Url ...` when probing. |

> **`WebhookCapture.gs` must never share a project with `CallingPipeline.gs`.** Both define
> `doPost` and `ok_`. If the capture file wins, live webhooks are written to a capture sheet
> and never reach Supabase — the pipeline goes quiet and nothing reports an error, because
> from LeadSquared's side every request still returns 200.

## After changing `CallingPipeline.gs`

1. Paste and **save** (Ctrl-S). Saving is what updates the code the editor runs.
2. Run `diagnose()` and check the first line: `CODE_VERSION` must match what you pasted. If it
   does not, the paste did not save — and every other symptom you are looking at is stale.
3. Run `setUp()` **only if the trigger schedule changed** — it deletes and recreates all
   triggers.
4. **Deploy > Manage deployments > Edit > Version: New version** — required for the *webhook
   URL* to serve the new code. Saving alone does not update the deployed web app.

Steps 1–3 affect what runs from the editor and on triggers. Step 4 affects what LeadSquared
talks to. They are independent, which is why "I redeployed and nothing changed" is usually
"I redeployed but never ran anything".

## `archive/`

Superseded, kept for reference, and **must not be pasted into the live project**:

- **`SheetsSync.gs`** — the first Sheets renderer, before the pipeline absorbed it. Collides
  with `CallingPipeline.gs` on `TABS`, `writeTable_`, `writeRepDay_`, `writeTrend_`,
  `writeExceptions_`, `writeMeta_`, `cfg_` and the three `ist*` helpers. Its `TABS` has no
  Teams entry, so if it loaded last the Teams tab would never be created and several tabs
  would render from the old code — indistinguishable, from the Sheet, from "my paste did not
  work".
- **`Dashboard.gs` / `Dashboard.html`** — the realtime web-app view. Never deployed; the
  Sheet plus Excel covered the need. Collides on `doGet`.
