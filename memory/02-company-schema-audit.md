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
| `mx_Marketing_Budget_monthly`, `mx_Budget` | `Budget_Company` | exists, empty — reconcile the two Lead fields into one value first (see `08-open-decisions.md`, unresolved — same number in different units, or genuinely two different things?) |
| `mx_Website_URL` | `Website` | exists, empty — backfill |
| `mx_Business_Model` (B2B/B2C) | — | new Company custom field needed |
| `mx_Qualified_Business` | — | new Company custom field needed, replaces per-lead Y/N |

## Company field creation via API

Confirmed: **no documented API to create custom fields on the Company/Account object**
(unlike Lead, which has `LeadManagement.svc/CreateLeadField`). Treat as UI-only
(My Account > Settings > Customization) until proven otherwise. See
`07-write-capability-matrix.md`.
