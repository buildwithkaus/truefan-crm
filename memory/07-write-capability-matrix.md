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
| Create an Activity Type + its custom fields | **Yes, in one call** | `POST ProspectActivity.svc/CreateType` — core props plus an optional `Fields` array in the same request, up to 50 custom fields (`mx_Custom_1`...`mx_Custom_50`). |
| Rate limits | Documented | Pro plan: 10 calls/5s standard, 5 calls/5s bulk, 10,000/day + 1,000/user/day. Super plan roughly 2x. Exceeding returns HTTP 429. |

## The one hard manual step

**Opportunity Type creation cannot be automated.** Everything else in the Opportunity
build-out (once the Type exists) can be scripted. This is the one place the plan needs a
human in the LSQ UI before any script can proceed — see `PROJECT_PLAN.md` Phase 3.
