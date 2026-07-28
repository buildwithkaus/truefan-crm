# Company (Account) object — schema audit (pulled 2026-07-27)

CompanyTypeName in this account is `"Company"` (not the LSQ defaults "Customers"/
"Partners" — was configured/renamed as part of setup).

## Fields (from a live record — no dedicated metadata endpoint exists for Company, unlike
Lead's `LeadsMetaData.Get`; field list below is everything present on `companyPropertyList`)

Address1, Address2, AlternateName, AnnualRevenue, City, CompanyAutoId, CompanyId,
CompanyIdentifier, CompanyName, CompanyNumber, Country, CreatedBy/CreatedOn/CreatedByName/
CreatedByEmail, Currency, Description, DoNotCall, DoNotEmail, EmailAddress, Employees,
Entity, FacebookUrl, Industry, Language, LastActivityOn, LinkedInUrl, ModifiedBy/ModifiedOn/
ModifiedByName/ModifiedByEmail, **CIN_Company**, **Custom_2**, **Budget_Company** (these 3
are the custom fields — already exist, already map to Lead fields, see reparenting table
below), Notes, Origin, OwnerId, OwnerName, OwnerEmail, Phone, ZipCode, Source, **Stage**,
State, TimeZone, TwitterUrl, Website.

## Scale and provenance

**71,467 records**, all bulk-created **2026-07-22** (by Kaustubh, confirmed — part of the
process, not a surprise) from the Lead's free-text `Company` field. This predates the
"Pipeline Centralization" email by 2 days.

`Stage` field: exactly 3 values — Prospect (67,036), Opportunity (4,289), Customer (142).
Sums to 71,467 exactly. This is the field the Pipeline Centralization email called "too
coarse."

## Enrichment fill rate — effectively zero (1,000-record sample, 2026-07-27)

- Industry: 0/1000 (0%)
- Annual Revenue: 2/1000 (0.2%)
- Employees: 6/1000 (0.6%)
- Phone: 0/1000 (0%)
- Website: 111/1000 (11%)

**This is the hard blocking dependency for ICP tiering** (see `00-business-context.md` —
GTM engineer's TAL work needs to enrich these same fields on these same records, not
build a parallel dataset).

Duplication: directionally real (searching the object for single well-known brands
returns multiple records — `HDFC`→10, `Amazon`→15) but not cleanly quantifiable via the
API without a proper name-normalization pass; don't quote a precise dedup % without
redoing this analysis with fuzzy matching.

## Field reparenting map (Lead field → Company field — data already exists, just
duplicated per-contact instead of centralized)

| Lead field (mx_) | Company field | Status |
|---|---|---|
| `mx_Industry_Type` | `Industry` | exists, empty — backfill |
| `mx_Company_revenue` | `AnnualRevenue` | exists, empty — backfill |
| `mx_CIN` | `CIN_Company` | exists, empty — backfill |
| `mx_Budget` | `Budget_Company` | exists, empty — backfill from `mx_Budget` specifically. **Resolved 2026-07-27** (`08-open-decisions.md`): use `mx_Budget`, not `mx_Marketing_Budget_monthly`. **Confirmed backfill-compatible** (smoke-tested 2026-07-27 — values like `between_3_lakh_to_5_lakhs` write cleanly) |
| `mx_Website_URL` | `Website` | exists, empty — backfill. **Confirmed backfill-compatible** |
| `mx_Business_Model` (B2B/B2C) | `mx_business_model` | **Created 2026-07-27.** Company side is a strict dropdown (only accepts `B2B`/`B2C`, case-insensitive — confirmed via test writes). **Lead side is NOT clean**: only 369 of 86,627 leads (0.4%) hold an exact `B2B`/`B2C` value; the rest is free-text industry description leaking into the wrong field (e.g. "financial services provider", "Dairy business"). Backfill scripted to pass through only the 369 clean matches, normalized to uppercase — everything else is skipped, not force-written |
| `mx_Qualified_Business` | `qualified_business` | **Created 2026-07-27.** Confirmed backfill-compatible (accepts `Yes`/`No`), but source fill rate is very low: only 324 of 86,627 leads (0.4%) have a value at all |
| `mx_Industry_Type` | `Industry` | **Excluded from Phase 4 automated backfill 2026-07-27** — Company's `Industry` is a strict dropdown (rejects free text, e.g. "Dairy business" → `MXInvalidEntityReferenceException`), but `mx_Industry_Type` on Lead is free text. No Company-side field-metadata endpoint exists to discover the dropdown's valid option list (confirmed, see "Company field creation via API" below), so an automated safe backfill isn't possible without first learning those options from the LSQ UI. Flagged in `08-open-decisions.md` |
| `mx_Company_revenue` | `AnnualRevenue` | **Excluded from Phase 4 automated backfill 2026-07-27** — Company's `AnnualRevenue` expects a `Decimal`, but `mx_Company_revenue` on Lead is bucketed range text (e.g. "0 to 10 cr"), which the API rejects outright (`MXInvalidDataTypeException`). Needs a bucket-to-number conversion rule (e.g. take the midpoint) before this can backfill — a judgment call, flagged in `08-open-decisions.md`, not something to silently invent |

## Company field creation via API

Confirmed: **no documented API to create custom fields on the Company/Account object**
(unlike Lead, which has `LeadManagement.svc/CreateLeadField`). Treat as UI-only
(My Account > Settings > Customization) until proven otherwise. See
`07-write-capability-matrix.md`.
