# What's API-possible vs. UI/manual-only (researched 2026-07-27)

Sources: apidocs.leadsquared.com, help.leadsquared.com. Verify against current docs before
relying on this for anything load-bearing — LSQ's API surface changes.

| Capability | Possible via API? | How |
|---|---|---|
| Bulk update Leads | **Yes** | `POST LeadManagement.svc/Lead/Bulk/UpdateV2` — 25 records/call, `SearchByKey` (e.g. `ProspectId`), rate limit ~5 calls/5s on bulk endpoints. Verified working live 2026-07-27. |
| Single-record update Lead | **Yes** | `POST LeadManagement.svc/Lead.Update?...&leadId=X`, body `[{"Attribute":..,"Value":..}]`. Verified working. |
| Bulk update Companies | **Yes, but risky** | `POST CompanyManagement.svc/Company/Bulk/CreateOrUpdate` — matches by `CompanyName`/`CompanyNumber`/`CompanyIdentifier` only, **not CompanyId**, and is create-*or*-update. A name mismatch can silently create a duplicate. Avoided for the owner-reassignment migration for this reason. |
| Single-record update Company | **Yes** | `POST CompanyManagement.svc/Company.Update?...&companyId=X`. Verified working, precise (matches by internal ID). Prefer this over bulk when you have exact CompanyIds. |
| Create custom Lead field | **Yes** | `POST LeadManagement.svc/CreateLeadField` — DisplayName, DataType, IsMandatory, OptionsJson for dropdowns. New field gets `mx_<Display_Name>` schema name. |
| Create custom Company field | **No (not documented)** | Account Management API surface is only Create/Get/Update/Delete/BulkCreateOrUpdate — no field-creation endpoint found. UI: My Account > Settings > Customization. |
| Add options to an existing Lead dropdown | **Yes, for custom (`mx_`) fields; unverified for system fields** | `POST LeadManagement.svc/LeadField/Dropdown/Options/Push` (non-dependent) or `.../Dependency/Dropdown/Options/Push` (parent/child). Docs' own examples only show `mx_` fields — whether this works on a built-in field like `ProspectStage` is untested. Test on a throwaway custom field first if this matters. |
| Add options to a Company dropdown | **No endpoint found** | UI only, presumed. |
| Create an Opportunity Type (Stage list, Status, fields) | **No — UI only, confirmed** | My Profile > Settings > Opportunities > Opportunity Types > Create (3-tab wizard: Basic Details, Field Configuration, Form Configuration). `GetOpportunityTypeMetadata` only *reads* an existing type. This is the one genuinely manual step blocking the Opportunity build. |
| Create/read/update an **Automation (workflow)** | **No — UI only, confirmed 2026-07-28** | **No automation API exists at all.** 13 candidate endpoints probed live (`Automation.svc/*`, `AutomationManagement.svc/*`, `Workflow.svc/*`, `WorkflowManagement.svc/*`, `MarketingAutomation.svc/*`, `Automation/*`) — every one returned 404 while the control (`LeadManagement.svc/LeadsMetaData.Get`) returned 200, so auth and host were correct. apidocs.leadsquared.com has no Automation/Workflow category. Automations must be built in Workflow > Automation by hand. Spec: `docs/LSQ_AUTOMATION_SPEC.md`. |
| Create/update/delete a **Webhook** | **Yes** | Documented CRUD (Create/Retrieve/Update/Delete). Relevant only as an alternative to automation if a hosted receiving endpoint ever exists — not used in this project. |
| Bulk-read Opportunities | **No** | No bulk endpoint; per-lead only via `GetOpportunitiesOfLead?leadId=X&opportunityType=12000` (the `opportunityType` param is required). 8 candidate names probed 2026-07-28, all 404. |
| Create an Activity Type + its custom fields | **Yes, in one call** | `POST ProspectActivity.svc/CreateType` — core props plus an optional `Fields` array in the same request, up to 50 custom fields (`mx_Custom_1`...`mx_Custom_50`). |
| Rate limits | Documented | Pro plan: 10 calls/5s standard, 5 calls/5s bulk, 10,000/day + 1,000/user/day. Super plan roughly 2x. Exceeding returns HTTP 429. |

## The one hard manual step — done

**Opportunity Type creation cannot be automated**, and this step is now complete (done
2026-07-27 — confirmed live via `GetOpportunityTypes`/`GetOpportunityTypeMetadata`, see
`03-object-model-and-relationships.md`). The two Company custom fields
(`mx_business_model`, `qualified_business`) needed for Phase 4 were also created the same
day. Everything else in the Opportunity build-out and Company enrichment can now be
scripted — see `PROJECT_PLAN.md` Phase 3/4.
