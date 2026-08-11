-- =====================================================================================
-- TrueFan CRM - 027: materialise the ICP base (2026-08-11)
--
-- THE SYMPTOM. channel_bundle started returning HTTP 500 after ~9s and FOUR tabs went blank
-- at once - Channels, Book Health, Disqualified and ICP. Nothing was wrong with any of them.
--
-- THE CAUSE. Every view in the bundle is fast on its own (0.2-1.9s measured). The bundle is
-- ONE statement, and v_icp_contact is expensive: 90,796 rows from dim_contact_book with two
-- lateral aggregates each. icp_cut() scans it once per dimension - four times for
-- v_icp_funnel - and v_icp_scorecard then reads v_icp_funnel again plus a baseline pass.
-- Roughly nine full passes, in one statement, against a statement timeout.
--
-- It only appeared today because fact_touch grew from 16,500 to 56,917 rows during the trail
-- load, pushing the total over the limit. Which means it was always going to happen - the
-- data only ever grows - and a fix that just trims rows would buy weeks, not a solution.
--
-- THE FIX. v_icp_contact is a per-contact snapshot whose inputs change once a day, when the
-- book is reloaded. Recomputing it nine times per refresh, every 30 minutes, was work with no
-- purpose. It becomes a materialized view refreshed by the loader that changes its inputs.
--
-- Same reasoning as fact_book_snapshot: when the source is a daily full scan, the derived
-- table should be daily too, not recomputed on every read.
-- =====================================================================================

drop materialized view if exists mv_icp_contact;

create materialized view mv_icp_contact as
select
    b.prospect_id,
    b.owner_name,
    b.contact_stage,
    b.source,
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

-- A unique index is required for REFRESH ... CONCURRENTLY, which is what lets the refresh
-- run without blocking readers. Without it every refresh would take the tab offline for its
-- duration - trading one outage for another.
create unique index if not exists idx_mv_icp_prospect on mv_icp_contact (prospect_id);
create index if not exists idx_mv_icp_ads      on mv_icp_contact (ads);
create index if not exists idx_mv_icp_category on mv_icp_contact (category);

revoke all on mv_icp_contact from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- icp_cut now reads the materialized copy. Identical logic and identical thresholds - the
-- ONLY change is the source table.
-- --------------------------------------------------------------------------------------
create or replace function icp_cut(p_dimension text)
returns table (
    dimension     text, value        text, contacts     bigint, untouched    bigint,
    worked        bigint, connected  bigint, prospects   bigint, deals        bigint,
    won           bigint, connect_pct numeric, prospect_pct numeric, win_pct  numeric,
    suppressed    text
)
language sql stable as $$
    with cfg as (
        select
            (select value::int from app_config where key = 'icp_min_worked')    as min_worked,
            (select value::int from app_config where key = 'icp_min_wins')      as min_wins,
            (select value::int from app_config where key = 'icp_min_prospects') as min_prospects
    ),
    base as (
        select
            case p_dimension
                when 'ads'      then ads
                when 'category' then category
                when 'city'     then city
                when 'source'   then coalesce(nullif(btrim(source), ''), '<unknown>')
            end as value,
            touched, connected, prospect, has_deal, won
        from mv_icp_contact
    ),
    agg as (
        select
            value,
            count(*)                            as contacts,
            count(*) filter (where not touched) as untouched,
            count(*) filter (where touched)     as worked,
            count(*) filter (where connected)   as connected,
            count(*) filter (where prospect)    as prospects,
            count(*) filter (where has_deal)    as deals,
            count(*) filter (where won)         as won
        from base
        where value is not null
        group by value
    )
    select
        p_dimension, a.value,
        a.contacts, a.untouched, a.worked, a.connected, a.prospects, a.deals, a.won,
        case when a.worked >= c.min_worked
             then round(100.0 * a.connected / nullif(a.worked, 0), 1) end,
        case when a.worked >= c.min_worked and a.prospects >= c.min_prospects
             then round(100.0 * a.prospects / nullif(a.worked, 0), 1) end,
        case when a.worked >= c.min_worked and a.won >= c.min_wins
             then round(100.0 * a.won / nullif(a.worked, 0), 1) end,
        case
            when a.worked < c.min_worked then 'n<' || c.min_worked || ' worked'
            when a.won < c.min_wins and a.prospects < c.min_prospects
                 then 'too few wins/prospects to rate'
            when a.won < c.min_wins then 'win rate: only ' || a.won || ' won'
            when a.prospects < c.min_prospects then 'prospect rate: only ' || a.prospects
        end
    from agg a cross join cfg c
    order by a.worked desc, a.contacts desc;
$$;


-- --------------------------------------------------------------------------------------
-- v_icp_scorecard - baseline from the materialized copy too. This view was the second half
-- of the cost: it read v_icp_funnel (four more passes) AND computed its own baseline.
-- --------------------------------------------------------------------------------------
create or replace view v_icp_scorecard as
with baseline as (
    select
        count(*) filter (where touched)   as worked,
        count(*) filter (where connected) as connected,
        count(*) filter (where prospect)  as prospects,
        count(*) filter (where won)       as won
    from mv_icp_contact
),
b as (
    select
        round(100.0 * connected / nullif(worked, 0), 1) as connect_pct,
        round(100.0 * prospects / nullif(worked, 0), 1) as prospect_pct,
        round(100.0 * won       / nullif(worked, 0), 1) as win_pct
    from baseline
)
select
    f.dimension, f.value, f.worked, f.connect_pct, f.prospect_pct, f.win_pct,
    b.connect_pct as baseline_connect_pct,
    b.prospect_pct as baseline_prospect_pct,
    case when f.prospect_pct is not null
         then round(f.prospect_pct - b.prospect_pct, 1) end as prospect_lift_pp,
    case when f.connect_pct is not null
         then round(f.connect_pct - b.connect_pct, 1) end   as connect_lift_pp,
    f.suppressed
from v_icp_funnel f
cross join b
where f.connect_pct is not null
order by prospect_lift_pp desc nulls last, connect_lift_pp desc nulls last;


-- --------------------------------------------------------------------------------------
-- Staleness has to be visible. A materialized view that silently stops refreshing looks
-- exactly like one that is simply quiet - the dim_rep lesson, in a different shape.
-- --------------------------------------------------------------------------------------
create or replace view v_qc_icp as
select 'contact book is loaded'::text as check_name,
       '>80000'::text                  as expected,
       (select count(*)::text from dim_contact_book) as actual,
       case when (select count(*) from dim_contact_book) > 80000 then 'PASS' else 'WARN' end as status,
       'dim_contact_book row count'::text as compared_against
union all
select 'ICP snapshot matches the loaded book',
       (select count(*)::text from dim_contact_book),
       (select count(*)::text from mv_icp_contact),
       case when (select count(*) from dim_contact_book) = (select count(*) from mv_icp_contact)
            then 'PASS' else 'FAIL' end,
       -- A mismatch means the materialized view was not refreshed after the last book load,
       -- so every ICP number on the tab describes an older book.
       'dim_contact_book vs mv_icp_contact'
union all
select 'ads field is usable',
       '>1000',
       (select count(*)::text from dim_contact_book where btrim(coalesce(ads,'')) <> ''),
       case when (select count(*) from dim_contact_book where btrim(coalesce(ads,'')) <> '') > 1000
            then 'PASS' else 'WARN' end,
       'dim_contact_book.ads fill';

revoke all on v_icp_scorecard from anon, authenticated;
revoke all on v_qc_icp        from anon, authenticated;

-- --------------------------------------------------------------------------------------
-- PostgREST cannot issue REFRESH MATERIALIZED VIEW - it only calls functions - so the
-- refresh needs a callable wrapper. SECURITY DEFINER because refreshing requires ownership,
-- and the loader authenticates as service_role rather than as the view's owner.
--
-- CONCURRENTLY keeps the tabs serving during the rebuild; it requires the unique index
-- created above, and falls back to a plain refresh if that index is ever dropped, so a
-- missing index degrades speed rather than breaking the pipeline outright.
-- --------------------------------------------------------------------------------------
create or replace function refresh_icp_snapshot()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
    begin
        refresh materialized view concurrently mv_icp_contact;
        return 'refreshed concurrently';
    exception when others then
        refresh materialized view mv_icp_contact;
        return 'refreshed (non-concurrent fallback): ' || sqlerrm;
    end;
end;
$$;

refresh materialized view mv_icp_contact;
