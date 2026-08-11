-- =====================================================================================
-- TrueFan CRM - 023: the ICP funnel (2026-08-11)
--
-- Answers "which kind of business actually converts" - by Meta-ads status, category,
-- industry, city and source. Measured on the whole book, not the enriched slice.
--
-- THE FIELDS ARE CHOSEN FROM MEASURED FILL RATES, not from what sounds useful. From
-- enumerate-icp-readiness.ps1 over all 91,033 leads:
--
--   mx_Ads          34.3% of book, 99.7% of the ICP list, exactly Yes(2,059)/No(29,139)
--   mx_Category     38.8% of book, 100%  of the ICP list, 55 clean values
--   mx_Industry_Type 62.4% of book but 11,515 distinct values against a 15-option dropdown
--                   - carried as data, NEVER as a filter, because 11,503 of those values
--                     are not selectable and no rep can reproduce a cut built on them
--   mx_City         28.9% of book, 97.9% of the ICP list
--
-- Excluded as dead on the ICP population: Segment, Company revenue, Selected Product,
-- Qualified Business, State, Sub Sector, Marketing Budget, Country, and mx_Categoey (the
-- typo twin of mx_Category, empty in all 91,033 rows).
--
-- THREE RULES THAT DECIDE WHETHER THIS IS ANALYSIS OR NOISE:
--
--  1. CELL SUPPRESSION. There are 150 won deals in the entire account. A 12-way category
--     split leaves ~12 wins per cell at best, so any rate on fewer than 30 contacts renders
--     as 'n<30' rather than as a number somebody will quote.
--  2. DENOMINATOR DISCIPLINE. Conversion is computed over WORKED contacts, with the
--     untouched count shown beside it. Otherwise a category that is merely unworked reads
--     as a category that does not convert - and the two demand opposite responses.
--  3. NO VALUE-WEIGHTING. Deal value is absent from this CRM by every route (2 of 1,398
--     opportunities filled, one a test; and activities 204/205/206 carry no amounts). Every
--     number here is a COUNT. A revenue-weighted view would be fabrication.
-- =====================================================================================


-- --------------------------------------------------------------------------------------
-- dim_contact_book - the whole book at row level, with its ICP attributes.
--
-- Distinct from dim_contact, which is the enrichment cache the calling pipeline fills on
-- demand (~17,800 rows). This is all ~91,000, refreshed by a full scan that already has to
-- page every lead, so the ICP columns are close to free.
-- --------------------------------------------------------------------------------------
create table if not exists dim_contact_book (
    prospect_id       text primary key,
    company_id        text,
    company_name      text,
    owner_id          text,
    owner_name        text,
    contact_stage     text,
    source            text,
    -- ICP attributes, live field names confirmed against LeadsMetaData.Get
    ads               text,   -- mx_Ads: 'Yes' | 'No'
    category          text,   -- mx_Category: 55 clean values
    industry_type     text,   -- mx_Industry_Type: data only, NOT a filter (see header)
    city              text,   -- mx_City
    designation       text,   -- mx_Designation
    disq_reason       text,
    created_on        timestamptz,
    last_activity_at  timestamptz,
    refreshed_at      timestamptz not null default now()
);

create index if not exists idx_book_owner    on dim_contact_book (owner_id);
create index if not exists idx_book_ads      on dim_contact_book (ads);
create index if not exists idx_book_category on dim_contact_book (category);

alter table dim_contact_book enable row level security;
revoke all on dim_contact_book from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- v_icp_contact - one row per contact with its funnel position resolved.
--
-- Stage is taken from the CONTACT, and deal presence from fact_opportunity, so a contact can
-- be counted as reached without a deal and as a deal without a win. Each step is a boolean
-- rather than a single ordinal, because the funnel is not strictly ordered in practice - a
-- contact can be disqualified from any stage.
-- --------------------------------------------------------------------------------------
create or replace view v_icp_contact as
select
    b.prospect_id,
    b.owner_name,
    b.contact_stage,
    b.source,
    -- '<unknown>' LAST in every coalesce (gotcha 18): a non-null placeholder upstream
    -- defeats the fallbacks below it.
    coalesce(nullif(btrim(b.ads), ''), '<unknown>')       as ads,
    coalesce(nullif(btrim(b.category), ''), '<unknown>')  as category,
    coalesce(nullif(btrim(b.city), ''), '<unknown>')      as city,
    b.industry_type,

    (c.calls > 0)                                          as touched,
    (c.connects > 0)                                       as connected,
    coalesce(c.calls, 0)                                   as calls,
    (b.contact_stage in ('Engaged','Prospect','Customer'))  as engaged,
    (b.contact_stage in ('Prospect','Customer'))            as prospect,
    (o.opps > 0)                                            as has_deal,
    (b.contact_stage = 'Customer' or o.won > 0)             as won,
    (b.contact_stage = 'Disqualified')                      as disqualified
from dim_contact_book b
left join lateral (
    select count(*) as calls, count(*) filter (where connected) as connects
    from fact_call fc where fc.prospect_id = b.prospect_id and fc.direction = 'outbound'
) c on true
left join lateral (
    select count(*) as opps, count(*) filter (where status = 'Won') as won
    from fact_opportunity fo where fo.prospect_id = b.prospect_id
) o on true;


-- --------------------------------------------------------------------------------------
-- icp_cut - the funnel for one dimension, as a function so every cut is computed by the
-- SAME arithmetic. Three copies of this SQL would drift, and the drift would be invisible.
--
-- p_dimension: 'ads' | 'category' | 'city' | 'source'
-- --------------------------------------------------------------------------------------
create or replace function icp_cut(p_dimension text)
returns table (
    dimension     text,
    value         text,
    contacts      bigint,
    untouched     bigint,
    worked        bigint,
    connected     bigint,
    prospects     bigint,
    deals         bigint,
    won           bigint,
    connect_pct   numeric,
    prospect_pct  numeric,
    win_pct       numeric,
    suppressed    text
)
language sql stable as $$
    with base as (
        select
            case p_dimension
                when 'ads'      then ads
                when 'category' then category
                when 'city'     then city
                when 'source'   then coalesce(nullif(btrim(source), ''), '<unknown>')
            end as value,
            touched, connected, prospect, has_deal, won
        from v_icp_contact
    ),
    agg as (
        select
            value,
            count(*)                                as contacts,
            count(*) filter (where not touched)     as untouched,
            count(*) filter (where touched)         as worked,
            count(*) filter (where connected)       as connected,
            count(*) filter (where prospect)        as prospects,
            count(*) filter (where has_deal)        as deals,
            count(*) filter (where won)             as won
        from base
        where value is not null
        group by value
    )
    select
        p_dimension,
        a.value,
        a.contacts, a.untouched, a.worked, a.connected, a.prospects, a.deals, a.won,
        -- Every rate is over WORKED contacts, never over the whole cell. A category nobody
        -- has called must not read as a category that does not convert.
        case when a.worked >= 30 then round(100.0 * a.connected / nullif(a.worked, 0), 1) end,
        case when a.worked >= 30 then round(100.0 * a.prospects / nullif(a.worked, 0), 1) end,
        case when a.worked >= 30 then round(100.0 * a.won       / nullif(a.worked, 0), 1) end,
        case when a.worked < 30 then 'n<30' end
    from agg a
    order by a.worked desc, a.contacts desc;
$$;


-- --------------------------------------------------------------------------------------
-- v_icp_funnel - all four cuts stacked, which is what the tab renders.
-- --------------------------------------------------------------------------------------
create or replace view v_icp_funnel as
select * from icp_cut('ads')
union all select * from icp_cut('category')
union all select * from icp_cut('city')
union all select * from icp_cut('source');


-- --------------------------------------------------------------------------------------
-- v_icp_scorecard - lift against the account baseline, for the dimensions with enough data.
--
-- Lift is the point: a 6% prospect rate means nothing until you know the account runs at 4%.
-- Restricted to cells that survive suppression, so nothing here is computed on a handful of
-- contacts. 'ads' is included whole because both its values are large.
-- --------------------------------------------------------------------------------------
create or replace view v_icp_scorecard as
with baseline as (
    select
        count(*) filter (where touched)   as worked,
        count(*) filter (where connected) as connected,
        count(*) filter (where prospect)  as prospects,
        count(*) filter (where won)       as won
    from v_icp_contact
),
b as (
    select
        round(100.0 * connected / nullif(worked, 0), 1) as connect_pct,
        round(100.0 * prospects / nullif(worked, 0), 1) as prospect_pct,
        round(100.0 * won       / nullif(worked, 0), 1) as win_pct
    from baseline
)
select
    f.dimension,
    f.value,
    f.worked,
    f.connect_pct,
    f.prospect_pct,
    f.win_pct,
    b.connect_pct                              as baseline_connect_pct,
    b.prospect_pct                             as baseline_prospect_pct,
    round(f.prospect_pct - b.prospect_pct, 1)  as prospect_lift_pp,
    round(f.connect_pct - b.connect_pct, 1)    as connect_lift_pp
from v_icp_funnel f
cross join b
where f.suppressed is null
order by prospect_lift_pp desc nulls last;


-- --------------------------------------------------------------------------------------
-- v_qc_icp - is the book loaded, and does it agree with the independent snapshot?
-- --------------------------------------------------------------------------------------
create or replace view v_qc_icp as
select 'contact book is loaded'::text as check_name,
       '>80000'::text                  as expected,
       (select count(*)::text from dim_contact_book) as actual,
       case when (select count(*) from dim_contact_book) > 80000 then 'PASS' else 'WARN' end as status,
       'dim_contact_book row count'::text as compared_against
union all
select 'book size agrees with the daily snapshot',
       (select sum(contacts)::text from fact_book_snapshot
         where snapshot_date = (select max(snapshot_date) from fact_book_snapshot)),
       (select count(*)::text from dim_contact_book),
       -- Two independent counts of the same population: the aggregate snapshot and the
       -- row-level load. Within 1% is fine - they are taken minutes apart on a live system.
       case when abs(coalesce((select sum(contacts) from fact_book_snapshot
                                where snapshot_date = (select max(snapshot_date) from fact_book_snapshot)), 0)
                     - (select count(*) from dim_contact_book)) < 1000
            then 'PASS' else 'FAIL' end,
       'fact_book_snapshot vs dim_contact_book'
union all
select 'ads field is usable',
       '>1000',
       (select count(*)::text from dim_contact_book where btrim(coalesce(ads,'')) <> ''),
       case when (select count(*) from dim_contact_book where btrim(coalesce(ads,'')) <> '') > 1000
            then 'PASS' else 'WARN' end,
       'dim_contact_book.ads fill';

revoke all on v_icp_contact   from anon, authenticated;
revoke all on v_icp_funnel    from anon, authenticated;
revoke all on v_icp_scorecard from anon, authenticated;
revoke all on v_qc_icp        from anon, authenticated;
