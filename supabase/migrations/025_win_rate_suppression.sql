-- =====================================================================================
-- TrueFan CRM - 025: suppress win rates on the NUMERATOR too (2026-08-11)
--
-- THE DEFECT. icp_cut() gated every rate on worked >= 30 - a denominator test. That is
-- right for connect and prospect rates, whose numerators run in the hundreds. It is wrong
-- for the win rate, whose numerator is 0-3 in every category cell:
--
--     Real Estate   1,080 worked, 1 win   -> 0.1%   printed as though it were a measurement
--     Fintech         474 worked, 2 wins  -> 0.4%
--     Jewellery       138 worked, 0 wins  -> 0.0%
--
-- 1,080 contacts passes the n>=30 gate comfortably, so the cell rendered a confident-looking
-- percentage built on a single closed deal. A rate is only as reliable as its rarest event,
-- and there are 150 won deals in the entire account.
--
-- THE FIX. Each rate now gates on its own numerator as well as the denominator. Where the
-- numerator is too thin the cell shows the COUNT instead of a rate, because "1 win" is a
-- true and useful statement while "0.1%" invites a comparison the data cannot support.
--
-- Thresholds live in app_config so they can be raised as the deal book grows.
-- =====================================================================================

insert into app_config (key, value) values
    ('icp_min_worked',     '30'),   -- denominator floor, unchanged
    ('icp_min_wins',       '10'),   -- numerator floor for a WIN rate
    ('icp_min_prospects',  '10')    -- numerator floor for a PROSPECT rate
on conflict (key) do nothing;


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

        -- Connect rate: numerator runs in the hundreds, so the denominator gate is enough.
        case when a.worked >= c.min_worked
             then round(100.0 * a.connected / nullif(a.worked, 0), 1) end,

        -- Prospect rate: needs both. A category with 3 prospects out of 400 worked should
        -- report "3", not "0.8%".
        case when a.worked >= c.min_worked and a.prospects >= c.min_prospects
             then round(100.0 * a.prospects / nullif(a.worked, 0), 1) end,

        -- Win rate: the rarest event in the system. 150 wins account-wide means almost every
        -- cell is legitimately unmeasurable, and saying so is the honest output.
        case when a.worked >= c.min_worked and a.won >= c.min_wins
             then round(100.0 * a.won / nullif(a.worked, 0), 1) end,

        -- One note per row explaining WHICH rate was withheld and why, so a blank cell is
        -- never read as a zero.
        case
            when a.worked < c.min_worked then 'n<' || c.min_worked || ' worked'
            when a.won < c.min_wins and a.prospects < c.min_prospects
                 then 'too few wins/prospects to rate'
            when a.won < c.min_wins then 'win rate: only ' || a.won || ' won'
            when a.prospects < c.min_prospects then 'prospect rate: only ' || a.prospects
        end
    from agg a
    cross join cfg c
    order by a.worked desc, a.contacts desc;
$$;


-- --------------------------------------------------------------------------------------
-- v_icp_scorecard - lift must be computed only where BOTH sides survive suppression.
--
-- Previously it filtered on `suppressed is null`, which under the old rule meant only
-- "worked >= 30". A cell can now carry a connect rate but no prospect rate, so the lift
-- columns have to test the rate they are actually differencing rather than a single flag -
-- otherwise a null prospect_pct silently produces a null lift that sorts to the top.
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
    case when f.prospect_pct is not null
         then round(f.prospect_pct - b.prospect_pct, 1) end as prospect_lift_pp,
    case when f.connect_pct is not null
         then round(f.connect_pct - b.connect_pct, 1) end   as connect_lift_pp,
    f.suppressed
from v_icp_funnel f
cross join b
where f.connect_pct is not null      -- at minimum the cell must support ONE real rate
order by prospect_lift_pp desc nulls last, connect_lift_pp desc nulls last;

revoke all on v_icp_scorecard from anon, authenticated;
