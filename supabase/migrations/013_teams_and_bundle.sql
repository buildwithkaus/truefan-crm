-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 013: team structure, the disposition trend, a clearer rep funnel, and one bundled read
--      (2026-08-09)
--
-- FOUR THINGS.
--
-- 1. TEAMS. Every rep-facing tab is read by team, not as a flat alphabetical list. The
--    structure lives here rather than in the Apps Script so the Sheet, Excel and any ad-hoc
--    query group identically.
--
-- 2. THE DISPOSITION TREND. Daily Trend gains one column per call disposition, generated
--    from live values - never a hardcoded list, because this account invents disposition
--    values faster than it uses the existing ones.
--
-- 3. A REP FUNNEL THAT CAN BE EXPLAINED. The old one mixed journey milestones with deal
--    outcomes and had a "Touched" column nobody could define. Every column is now either
--    "how many contacts are in this state right now" or "what did this rep do in the
--    window", and the two groups are visually separated on the tab.
--
-- 4. ONE BUNDLED READ. Apps Script blew its 20,000/day UrlFetch quota, which took out
--    Pipeline State, Exceptions and QC with "Service invoked too many times for one day".
--    refreshReports was making ~14 separate PostgREST calls every 10 minutes. report_bundle()
--    returns all of them in a single response.
-- =====================================================================================


-- =====================================================================================
-- PART 1 - teams
--
-- Matched on lower(trim(name)) everywhere. LeadSquared stores 'adarsh pandey' in lower case
-- while the org chart writes 'Adarsh Pandey', and an exact-match join would silently drop
-- the team lead's own book - which is the largest book on his team.
-- =====================================================================================

create table if not exists dim_team (
    rep_name    text primary key,          -- as LSQ stores it, lower-cased
    display_name text not null,            -- as the org chart writes it
    team        text not null,
    team_lead   text not null,
    is_lead     boolean not null default false,
    sort_order  integer not null default 0
);

truncate dim_team;
insert into dim_team (rep_name, display_name, team, team_lead, is_lead, sort_order) values
    -- Team #ONE
    ('adarsh pandey',     'Adarsh Pandey',     'Team #ONE',      'Adarsh Pandey', true,  0),
    ('nikhil sharma',     'Nikhil Sharma',     'Team #ONE',      'Adarsh Pandey', false, 1),
    ('rishi saraswat',    'Rishi Saraswat',    'Team #ONE',      'Adarsh Pandey', false, 2),
    ('subham tak',        'Subham Tak',        'Team #ONE',      'Adarsh Pandey', false, 3),
    ('vikhyat verma',     'Vikhyat Verma',     'Team #ONE',      'Adarsh Pandey', false, 4),
    ('rahul madaan',      'Rahul Madaan',      'Team #ONE',      'Adarsh Pandey', false, 5),
    ('abhishek tripathi', 'Abhishek Tripathi', 'Team #ONE',      'Adarsh Pandey', false, 6),
    ('akshita sharma',    'Akshita Sharma',    'Team #ONE',      'Adarsh Pandey', false, 7),
    ('saurabh sharma',    'Saurabh Sharma',    'Team #ONE',      'Adarsh Pandey', false, 8),
    -- Team Achievers
    ('mayank arora',      'Mayank Arora',      'Team Achievers', 'Mayank Arora',  true,  0),
    ('ashutosh ojha',     'Ashutosh Ojha',     'Team Achievers', 'Mayank Arora',  false, 1),
    ('twinkle sutrakar',  'Twinkle Sutrakar',  'Team Achievers', 'Mayank Arora',  false, 2),
    ('kartikey mishra',   'Kartikey Mishra',   'Team Achievers', 'Mayank Arora',  false, 3),
    ('prakhar gupta',     'Prakhar Gupta',     'Team Achievers', 'Mayank Arora',  false, 4),
    ('arjun rathi',       'Arjun Rathi',       'Team Achievers', 'Mayank Arora',  false, 5),
    ('neha advani',       'Neha Advani',       'Team Achievers', 'Mayank Arora',  false, 6);

alter table dim_team enable row level security;
grant select on dim_team to anon, authenticated;
drop policy if exists dim_team_read on dim_team;
create policy dim_team_read on dim_team for select to anon, authenticated using (true);


-- --------------------------------------------------------------------------------------
-- Resolve any rep name to a team. Anyone not on the org chart lands in 'Unassigned' rather
-- than vanishing - Irfan Mahmood, Shriyanka Gupta and Admin all hold real books, and a join
-- that dropped them would quietly shrink the account.
-- --------------------------------------------------------------------------------------
create or replace function rep_team(p_rep text) returns text
language sql stable as $$
    select coalesce(
        (select team from dim_team where rep_name = lower(btrim(p_rep))),
        'Unassigned')
$$;

create or replace function rep_team_sort(p_rep text) returns integer
language sql stable as $$
    -- Team #ONE first, then Achievers, then Unassigned; leads at the top of their team.
    select coalesce(
        (select case team when 'Team #ONE' then 1 when 'Team Achievers' then 2 else 8 end * 100
                + case when is_lead then 0 else 1 end * 10
                + sort_order
         from dim_team where rep_name = lower(btrim(p_rep))),
        900)
$$;


-- =====================================================================================
-- PART 2 - dispositions per day, for the Daily Trend tab
--
-- Long format, one row per date per disposition. The Sheet pivots it into columns, ordering
-- them by total volume, so a newly invented disposition simply appears rather than being
-- dropped by a hardcoded column list.
-- =====================================================================================

create or replace view v_daily_disposition as
select
    call_date_ist                        as report_date,
    coalesce(nullif(btrim(disposition), ''), '<blank>') as disposition,
    sum(calls)                           as calls,
    sum(connects)                        as connects
from v_pivot_disposition
group by 1, 2;


-- =====================================================================================
-- PART 3 - the rep funnel, rebuilt so every column has one meaning
--
-- Two blocks, and the tab keeps them visually apart:
--
--   THE BOOK - what the rep holds right now, from today's snapshot. Every contact is in
--   exactly one of these states, so Fresh + Engaged + Prospect + Customer + Disqualified +
--   Other = Book. They add up, which the old version's columns did not.
--
--   THE WORK - what happened in the reporting window, plus the deal book.
--
-- Deliberately dropped: "Touched". It counted rows in v_journey, which is a modelling
-- artifact rather than anything a rep would recognise, and it was the column Kaustubh could
-- not define. Replaced by "Called 30d", which is exactly what it says.
--
-- "Prospect" and "Deals" are now shown side by side with the gap between them, because the
-- operational rule is that they should be equal - every Prospect contact should carry an
-- opportunity. Showing both makes the 84 missing ones visible instead of implied.
-- =====================================================================================

create or replace view v_rep_funnel as
with book as (
    select
        coalesce(owner_name, owner_id)                                     as rep,
        sum(contacts)                                                      as book_size,
        sum(contacts) filter (where contact_stage = 'Fresh')               as fresh,
        sum(contacts) filter (where contact_stage = 'Engaged')             as engaged,
        sum(contacts) filter (where contact_stage = 'Prospect')            as prospect,
        sum(contacts) filter (where contact_stage = 'Customer')            as customer,
        sum(contacts) filter (where contact_stage = 'Disqualified')        as disqualified,
        sum(contacts) filter (where contact_stage not in
            ('Fresh','Engaged','Prospect','Customer','Disqualified'))      as off_taxonomy,
        sum(contacts) filter (where contact_stage in ('Fresh','Engaged','Prospect')) as workable
    from fact_book_snapshot
    where snapshot_date = (select max(snapshot_date) from fact_book_snapshot)
    group by 1
),
called as (
    -- Distinct contacts this rep personally dialled in the window. Owner-attributed, so a
    -- previous owner's calls on an inherited lead do not count (migration 011).
    select contact_owner_name as rep,
           count(distinct prospect_id)                          as called_contacts,
           count(*)                                             as dials,
           count(*) filter (where connected)                    as connects
    from v_call_enriched
    where is_owner_call and direction = 'outbound'
      and call_date_ist >= current_date - 30
    group by 1
),
deals as (
    select coalesce(r.lsq_name, ct.owner_name, o.owner_id) as rep,
           count(*)                                        as deals,
           count(*) filter (where o.temperature = 'Hot')   as hot,
           count(*) filter (where o.temperature = 'Warm')  as warm,
           count(*) filter (where o.temperature = 'New')   as new_deals,
           count(*) filter (where o.status = 'Won')        as won,
           count(*) filter (where o.status = 'Lost')       as lost
    from v_opportunity_primary o
    left join dim_contact ct on ct.prospect_id = o.prospect_id
    left join dim_rep r      on r.owner_id     = o.owner_id
    group by 1
),
moved as (
    select coalesce(nullif(h.changed_by_name, ''), ct.owner_name) as rep,
           count(distinct h.prospect_id) filter (where h.current_stage = 'Prospect')     as to_prospect_30d,
           count(distinct h.prospect_id) filter (where h.current_stage = 'Disqualified') as to_disqualified_30d
    from v_stage_history h
    left join dim_contact ct on ct.prospect_id = h.prospect_id
    where h.changed_at_utc >= now() - interval '30 days'
    group by 1
),
allreps as (
    select rep from book
    union select rep from called
    union select rep from deals
    union select rep from moved
)
select
    a.rep,
    rep_team(a.rep)                                as team,
    rep_team_sort(a.rep)                           as team_sort,
    -- THE BOOK (these six add up to book_size)
    coalesce(b.book_size, 0)                       as book_size,
    coalesce(b.fresh, 0)                           as fresh,
    coalesce(b.engaged, 0)                         as engaged,
    coalesce(b.prospect, 0)                        as prospect,
    coalesce(b.customer, 0)                        as customer,
    coalesce(b.disqualified, 0)                    as disqualified,
    coalesce(b.off_taxonomy, 0)                    as off_taxonomy,
    coalesce(b.workable, 0)                        as workable,
    -- THE WORK, last 30 days
    coalesce(c.called_contacts, 0)                 as called_30d,
    coalesce(c.dials, 0)                           as dials_30d,
    coalesce(c.connects, 0)                        as connects_30d,
    coalesce(m.to_prospect_30d, 0)                 as new_prospects_30d,
    coalesce(m.to_disqualified_30d, 0)             as disqualified_30d,
    -- THE DEAL BOOK
    coalesce(d.deals, 0)                           as deals,
    coalesce(d.hot, 0)                             as hot,
    coalesce(d.warm, 0)                            as warm,
    coalesce(d.new_deals, 0)                       as new_deals,
    coalesce(d.won, 0)                             as won,
    coalesce(d.lost, 0)                            as lost,
    -- Every Prospect should carry a deal. Positive means deals are missing.
    greatest(coalesce(b.prospect, 0) - coalesce(d.deals, 0), 0) as prospects_missing_deal,
    -- RATES
    round(100.0 * coalesce(c.called_contacts, 0) / nullif(b.workable, 0), 1) as coverage_pct,
    round(100.0 * coalesce(c.connects, 0) / nullif(c.dials, 0), 1)           as connect_pct,
    round(100.0 * coalesce(d.hot, 0) / nullif(d.deals, 0), 1)                as hot_pct,
    round(100.0 * coalesce(d.won, 0) / nullif(d.won + d.lost, 0), 1)         as win_rate_pct
from allreps a
left join book   b on b.rep = a.rep
left join called c on c.rep = a.rep
left join deals  d on d.rep = a.rep
left join moved  m on m.rep = a.rep
where a.rep is not null;


-- Team-level roll-up, for the header row of each team block.
create or replace view v_team_summary as
select
    team,
    min(team_sort)                     as team_sort,
    count(*)                           as reps,
    sum(book_size)                     as book_size,
    sum(workable)                      as workable,
    sum(fresh)                         as fresh,
    sum(engaged)                       as engaged,
    sum(prospect)                      as prospect,
    sum(called_30d)                    as called_30d,
    sum(dials_30d)                     as dials_30d,
    sum(connects_30d)                  as connects_30d,
    sum(new_prospects_30d)             as new_prospects_30d,
    sum(deals)                         as deals,
    sum(hot)                           as hot,
    sum(warm)                          as warm,
    sum(won)                           as won,
    round(100.0 * sum(called_30d) / nullif(sum(workable), 0), 1) as coverage_pct,
    round(100.0 * sum(connects_30d) / nullif(sum(dials_30d), 0), 1) as connect_pct
from v_rep_funnel
group by team;


-- =====================================================================================
-- PART 3b - enrichment work lists
--
-- enrichLeads used to pull up to 4,000 fact_call rows AND the whole of dim_contact (16,000+
-- rows and growing) on every run, purely to diff them in Apps Script memory. Worse, once the
-- backlog was clear it fell through to re-fetching 200 of today's contacts every single run
-- with no staleness test - about 28,800 UrlFetch calls a day against a 20,000 quota.
--
-- Postgres does the set difference; Apps Script asks for a short list.
-- =====================================================================================

create or replace view v_calls_awaiting_enrichment as
select distinct c.prospect_id, max(c.called_at_utc) as last_call_utc
from fact_call c
left join dim_contact ct on ct.prospect_id = c.prospect_id
where ct.prospect_id is null
group by c.prospect_id
order by max(c.called_at_utc) desc;

-- Contacts called TODAY, oldest cached copy first. The caller adds the staleness bound; this
-- view only decides who is a candidate.
create or replace view v_contacts_needing_refresh as
select ct.prospect_id, ct.last_refreshed_at
from dim_contact ct
where exists (
    select 1 from fact_call c
    where c.prospect_id = ct.prospect_id
      and c.call_date_ist = ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date
)
order by ct.last_refreshed_at asc nulls first;

grant select on v_calls_awaiting_enrichment, v_contacts_needing_refresh to anon, authenticated;


-- =====================================================================================
-- PART 4 - one bundled read
--
-- refreshReports was issuing about fourteen PostgREST calls every ten minutes. Combined with
-- enrichLeads, that exhausted Apps Script's 20,000/day UrlFetch quota by mid-afternoon and
-- the later tabs died with "Service invoked too many times for one day" - which looks like a
-- code failure and is actually a budget failure.
--
-- This returns every small and medium dataset in ONE response. The two genuinely large ones
-- (Forecast, Exceptions) stay separate so a single payload never gets unwieldy: three calls
-- per refresh instead of fourteen.
--
-- p_from bounds the daily series. Defaults to 1 August 2026, the start of recorded history.
-- =====================================================================================

create or replace function report_bundle(p_from date default '2026-08-01')
returns json
language sql stable as $$
select json_build_object(
    'generated_at',   now(),
    'from_date',      p_from,

    'pivot',          (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_pivot_disposition
                          where call_date_ist >= p_from order by rep) t),

    'daily_totals',   (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_daily_totals
                          where report_date >= p_from order by report_date desc) t),

    'daily_disp',     (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_daily_disposition
                          where report_date >= p_from order by report_date desc) t),

    'rep_day',        (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_rep_day
                          where report_date >= p_from
                          order by report_date desc, dials desc) t),

    'pipeline_state', (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_pipeline_state_wide order by book_size desc) t),

    'book_coverage',  (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_book_coverage) t),

    'rep_funnel',     (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_rep_funnel order by team_sort, rep) t),

    'team_summary',   (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_team_summary order by team_sort) t),

    'prospects_daily',(select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_prospects_daily
                          where report_date >= p_from order by report_date desc) t),

    'movement',       (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_funnel_movement
                          where report_date >= p_from order by report_date desc) t),

    'deal_board',     (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_deal_board order by open_opps desc) t),

    'deal_detail',    (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_deal_stage_detail
                          where status = 'Open' order by stage_rank) t),

    'forecast_quality',(select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_forecast_quality order by open_opps desc) t),

    'qc',             (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_qc_pipeline order by seq) t),

    'boundaries',     (select coalesce(json_agg(t), '[]'::json) from (
                          select * from v_data_boundaries) t),

    'hygiene',        (select coalesce(json_agg(t), '[]'::json) from (
                          select issue, count(*) as items from v_opportunity_hygiene
                          group by issue order by count(*) desc) t),

    'health',         (select row_to_json(t) from (select * from v_pipeline_health) t)
);
$$;

grant execute on function report_bundle(date) to anon, authenticated;
grant select on v_daily_disposition, v_rep_funnel, v_team_summary to anon, authenticated;
