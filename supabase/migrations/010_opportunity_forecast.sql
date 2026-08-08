-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 010: the opportunity funnel and the forecast (2026-08-09)
--
-- WHAT THIS IS FOR
--
-- The contact journey is Fresh -> Engaged -> Prospect -> (opportunity) -> Won | Lost, with
-- Disqualified as an exit available at any point. Everything up to Prospect is already
-- measured. This migration measures what happens AFTER, which is where revenue actually is.
--
-- Three questions, three surfaces:
--   1. How many prospects is each rep creating, per day?          v_prospects_daily
--   2. Where does every open deal sit right now?                  v_deal_board / v_deal_stage_detail
--   3. What is going to close, for how much, and when?            v_forecast
--
-- THE HONEST PART. Question 3 cannot be answered today, because deal value and expected
-- closure date are blank on most opportunities. That is not a reason to leave the tab out -
-- it is the reason to build it. v_forecast_quality measures the blank space directly, per
-- rep, so "fill in the deal size" stops being a nag and becomes a number: this is how much
-- pipeline we cannot see. A forecast tab that is 80% empty is the most persuasive possible
-- argument for filling it in.
--
-- Nothing here drops or rewrites an existing fact table. Two views from 008 are replaced
-- (v_journey, v_funnel_conversion) because both had a real defect - see the notes on each.
-- =====================================================================================


-- =====================================================================================
-- PART 0 - prerequisite check
--
-- v_qc_pipeline reads v_stage_drift, which 009 creates. Without this guard, running 010
-- first fails several statements in with "relation v_stage_drift does not exist" - true but
-- unhelpful, and it leaves the migration half applied. Fail immediately with the fix.
-- =====================================================================================

do $$
begin
    if to_regclass('public.v_stage_drift') is null then
        raise exception
            'Migration 009_book_nulls.sql has not been run. Run it first, then re-run this file.';
    end if;
end $$;


-- =====================================================================================
-- PART 1 - forecast columns on fact_opportunity
--
-- FINDING, 2026-08-09. These columns will be entirely NULL, and not because reps have not
-- filled them in. scripts/pipeline/04-probe-opportunity-fields.ps1 enumerated the live
-- Opportunity object across 23 real deals: 66 properties, of which exactly FOUR are custom
-- fields - mx_Custom_1 (deal name), mx_Custom_2 (deal stage), and mx_Custom_6 / mx_Custom_8,
-- both empty on every deal and carrying no display name.
--
-- There is no deal-value field and no expected-closure-date field on this account. They do
-- not exist to be filled in. Someone has to create them in LSQ first; until then the
-- Forecast tab measures the size of the hole rather than the pipeline.
--
-- The columns go in now regardless. They cost nothing empty, the forecast views are already
-- written against them, and the day the fields are created this becomes a mapping line in
-- the ingest rather than a schema change plus a re-ingest - which for opportunities means
-- one API call per lead, because there is no bulk opportunity read.
--
-- raw_fields keeps the complete payload so a field that starts being used is already
-- captured and only the view has to change.
-- =====================================================================================

alter table fact_opportunity add column if not exists deal_value          numeric;
alter table fact_opportunity add column if not exists currency            text;
alter table fact_opportunity add column if not exists expected_close_date date;
alter table fact_opportunity add column if not exists closed_at_utc       timestamptz;
alter table fact_opportunity add column if not exists opportunity_id      text;
alter table fact_opportunity add column if not exists raw_fields          jsonb;

create index if not exists idx_opp_status    on fact_opportunity (status);
create index if not exists idx_opp_close     on fact_opportunity (expected_close_date);

-- A deal value of 0 is indistinguishable from "not filled in" for forecasting purposes, and
-- LSQ writes 0 for an untouched numeric field. Treated as unknown everywhere below via this
-- helper so the rule lives in exactly one place.
create or replace function opp_value_known(v numeric) returns boolean
language sql immutable as $$ select v is not null and v > 0 $$;


-- --------------------------------------------------------------------------------------
-- Deal stages, enumerated live 2026-08-09 from 136 real opportunities:
--     117  Prospect
--      15  Requirement Gathering      <-- LEGACY
--       4  In Discussion
--
-- 'Requirement Gathering' is a pre-restructure value that scripts/lib/schema.ps1 lists in
-- OpportunityStageRenames as becoming 'Prospect'. That rename is a UI step on the dropdown
-- and has evidently not been applied, so 15 live deals still carry it. It ranks WITH
-- Prospect - it means the same thing - but v_deal_stage_drift below counts it separately so
-- the outstanding rename does not quietly become permanent.
--
-- 008's version of this function did not know the value and returned 0 for it, which sorted
-- those 15 deals above 'Prospect' on the board. That was the safety behaviour working as
-- intended (an unknown value is conspicuous rather than dropped), but now that we know what
-- it is, it should sort correctly.
-- --------------------------------------------------------------------------------------
create or replace function opp_stage_rank(s text) returns integer
language sql immutable as $$
    select case s
        when 'Prospect'              then 1
        when 'Requirement Gathering' then 1   -- legacy alias of Prospect; rename outstanding
        when 'In Discussion'         then 2
        when 'Agreement Sent'        then 3
        when 'Invoice Sent'          then 4
        when 'Payment Received'      then 5
        when 'Customer'              then 6
        when 'Closed - Lost'         then 99
        else 0                                -- unknown sorts first, so it gets noticed
    end;
$$;

insert into ref_canonical_value (field, value) values
    ('opportunity_status','Open'),
    ('opportunity_status','Won'),
    ('opportunity_status','Lost')
on conflict (field, value) do nothing;


-- --------------------------------------------------------------------------------------
-- v_deal_stage_drift - deals on a stage value that is not in the canonical list.
--
-- Same job as v_stage_drift does for contacts. A drifted deal stage is invisible to a rep's
-- own LSQ filter and silently breaks every stage-based deal report, so it needs to be
-- watchable rather than rediscovered six weeks later.
-- --------------------------------------------------------------------------------------
create or replace view v_deal_stage_drift as
select
    coalesce(o.stage, '<blank>')                                    as non_canonical_stage,
    coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
    count(*)                                                        as opportunities
from fact_opportunity o
left join dim_contact ct on ct.prospect_id = o.prospect_id
left join dim_rep r      on r.owner_id     = o.owner_id
where coalesce(o.stage, '') not in (
    select value from ref_canonical_value where field = 'opportunity_stage'
)
group by 1, 2;


-- =====================================================================================
-- PART 2 - one opportunity per contact
--
-- 008's v_journey joined fact_opportunity directly to dim_contact. A contact with two
-- opportunities therefore appeared twice in the journey and was counted twice in the funnel.
-- Rare today (the primary-contact rule keeps it rare) but it is a silent double-count, and
-- the funnel is the number that will be quoted in a review.
--
-- "The" opportunity for a contact is the furthest-advanced one, tie-broken by most recent.
-- =====================================================================================

create or replace view v_opportunity_primary as
select distinct on (prospect_id)
    prospect_id, activity_id, opportunity_id, opportunity_name, stage, status,
    owner_id, deal_value, currency, expected_close_date,
    created_at_utc, created_date_ist, modified_at_utc, closed_at_utc
from fact_opportunity
order by prospect_id,
         (status = 'Won') desc,
         opp_stage_rank(stage) desc,
         coalesce(modified_at_utc, created_at_utc) desc;


-- =====================================================================================
-- PART 3 - prospects created, per day, per rep
--
-- Counted from stage TRANSITIONS, not from the contact's current stage: a contact that
-- became a Prospect on Tuesday and was disqualified on Thursday still counts for Tuesday.
-- Reading current stage instead would erase the rep's work retroactively, which is both
-- wrong and demoralising.
--
-- net_new separates first-ever entries from re-entries. A contact bouncing Prospect ->
-- Engaged -> Prospect is real (a deal that went quiet and came back) but it is not a new
-- prospect, and counting it as one is the easiest way to inflate this number.
-- =====================================================================================

create or replace view v_prospects_daily as
with entries as (
    select
        h.prospect_id,
        ((h.changed_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date as entry_date_ist,
        h.changed_at_utc,
        -- Attribute to WHOEVER MADE THE CHANGE, falling back to the contact's owner.
        --
        -- Actor-first is the deliberate choice. In normal use a rep promotes their own
        -- contacts, so actor and owner are the same person and it makes no difference. They
        -- diverge only on admin edits, bulk operations and integration writes - and those
        -- are exactly the promotions that should NOT land in a rep's production count. This
        -- way they appear as their own column, visibly, instead of quietly inflating
        -- somebody's number. The 2026-07-30/31 restructure will show up this way.
        coalesce(nullif(h.changed_by_name, ''), ct.owner_name, '<unknown>') as rep,
        row_number() over (partition by h.prospect_id order by h.changed_at_utc) as entry_seq
    from v_stage_history h
    left join dim_contact ct on ct.prospect_id = h.prospect_id
    where h.current_stage = 'Prospect'
      and coalesce(h.previous_stage, '') <> 'Prospect'
)
select
    entry_date_ist                                    as report_date,
    rep,
    count(distinct prospect_id)                       as prospects_created,
    count(distinct prospect_id) filter (where entry_seq = 1) as net_new,
    count(distinct prospect_id) filter (where entry_seq > 1) as re_entered
from entries
group by 1, 2;


-- =====================================================================================
-- PART 4 - the deal board
--
-- v_deal_stage_detail is the long form (rep x stage x status), which pivots cleanly in
-- Sheets or Excel. v_deal_board is the wide per-rep summary that a manager reads first.
--
-- Open / Won / Lost is the status axis reps work to. Deal stage (mx_Custom_2) is the finer
-- axis inside Open, and it is NOT hardcoded anywhere - opp_stage_rank orders the known
-- values and returns 0 for anything new, so an invented stage sorts to the top and is seen
-- rather than silently dropped.
-- =====================================================================================

create or replace view v_deal_stage_detail as
select
    coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
    coalesce(o.status, '<blank>')                                   as status,
    coalesce(o.stage, '<blank>')                                    as stage,
    opp_stage_rank(o.stage)                                         as stage_rank,
    count(*)                                                        as opportunities,
    count(*) filter (where opp_value_known(o.deal_value))           as with_value,
    coalesce(sum(o.deal_value) filter (where opp_value_known(o.deal_value)), 0) as known_value
from v_opportunity_primary o
left join dim_contact ct on ct.prospect_id = o.prospect_id
left join dim_rep r      on r.owner_id = o.owner_id
group by 1, 2, 3, 4;


create or replace view v_deal_board as
with base as (
    select
        coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
        o.status, o.deal_value, o.expected_close_date, o.created_at_utc
    from v_opportunity_primary o
    left join dim_contact ct on ct.prospect_id = o.prospect_id
    left join dim_rep r      on r.owner_id = o.owner_id
)
select
    rep,
    count(*)                                                as total_opps,
    count(*) filter (where status = 'Open')                 as open_opps,
    count(*) filter (where status = 'Won')                  as won,
    count(*) filter (where status = 'Lost')                 as lost,
    count(*) filter (where status is null or status not in ('Open','Won','Lost')) as other_status,
    -- Win rate is computed on DECIDED deals only. Including open deals in the denominator
    -- makes every rep with a healthy pipeline look like they are losing, which is backwards.
    round(100.0 * count(*) filter (where status = 'Won')
          / nullif(count(*) filter (where status in ('Won','Lost')), 0), 1) as win_rate_pct,
    coalesce(sum(deal_value) filter (where status = 'Open' and opp_value_known(deal_value)), 0)
                                                            as open_known_value,
    coalesce(sum(deal_value) filter (where status = 'Won'  and opp_value_known(deal_value)), 0)
                                                            as won_value,
    count(*) filter (where status = 'Open' and not opp_value_known(deal_value)) as open_unvalued,
    count(*) filter (where status = 'Open' and expected_close_date is null)     as open_no_close_date,
    min(created_at_utc)                                     as oldest_opp_created
from base
group by rep;


-- =====================================================================================
-- PART 5 - the forecast
--
-- One row per OPEN opportunity: what it is worth, when it is expected to close, and whether
-- anyone has touched it lately. Sorted by expected close date, blanks last.
--
-- The flag columns are the point of this view. Today most rows will show missing_value and
-- missing_close_date true, which is exactly the picture that needs to be seen - a pipeline
-- that cannot be forecast. stale_days and overdue work even on rows with no value, so the
-- tab is useful for deal hygiene from day one, before a single amount is filled in.
-- =====================================================================================

create or replace view v_forecast as
with lastcall as (
    select prospect_id,
           max(called_at_utc)                            as last_call_utc,
           count(*)                                      as calls,
           count(*) filter (where connected)             as connects
    from fact_call
    group by prospect_id
),
prospect_since as (
    select prospect_id, min(changed_at_utc) as became_prospect_utc
    from v_stage_history
    where current_stage = 'Prospect'
    group by prospect_id
)
select
    coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
    ct.company_name,
    ct.full_name                        as contact_name,
    o.prospect_id,
    o.opportunity_name,
    coalesce(o.stage, '<blank>')        as stage,
    o.status,
    o.deal_value,
    o.currency,
    o.expected_close_date,
    ps.became_prospect_utc,
    lc.last_call_utc,
    coalesce(lc.calls, 0)               as calls,
    coalesce(lc.connects, 0)            as connects,

    (current_date - o.created_at_utc::date)                       as days_open,
    (o.expected_close_date - current_date)                        as days_to_close,
    (current_date - lc.last_call_utc::date)                       as days_since_last_call,

    not opp_value_known(o.deal_value)                             as missing_value,
    (o.expected_close_date is null)                               as missing_close_date,
    (o.expected_close_date is not null and o.expected_close_date < current_date) as overdue,
    -- 14 days is the working definition of stale on a 1-to-12-month contract cycle: long
    -- enough that a weekly cadence does not trip it, short enough that a deal cannot go
    -- quiet for a fortnight unnoticed. Change it here, not in the sheet.
    (lc.last_call_utc is null or lc.last_call_utc < now() - interval '14 days') as stale,
    opp_stage_rank(o.stage)                                       as stage_rank
from v_opportunity_primary o
left join dim_contact  ct on ct.prospect_id = o.prospect_id
left join dim_rep      r  on r.owner_id     = o.owner_id
left join lastcall     lc on lc.prospect_id = o.prospect_id
left join prospect_since ps on ps.prospect_id = o.prospect_id
where coalesce(o.status, 'Open') = 'Open';


-- =====================================================================================
-- PART 6 - forecast quality: how much of the pipeline can we actually see
--
-- This is the tab that makes the case. Per rep:
--   forecastable_pct   share of open deals carrying BOTH a value and a close date
--   known_value        what we can see
--   est_blind_value    what the unvalued deals would be worth at this rep's own average
--
-- est_blind_value is explicitly an estimate and is labelled as one everywhere it is shown.
-- It is not a forecast; it is the size of the hole in the forecast. Where a rep has no
-- valued deals at all there is no basis for an average, so it stays NULL rather than 0 -
-- a zero would read as "nothing missing", the exact opposite of the truth.
-- =====================================================================================

create or replace view v_forecast_quality as
with per_rep as (
    select
        rep,
        count(*)                                                       as open_opps,
        count(*) filter (where not missing_value)                      as with_value,
        count(*) filter (where not missing_close_date)                 as with_close_date,
        count(*) filter (where not missing_value and not missing_close_date) as forecastable,
        coalesce(sum(deal_value) filter (where not missing_value), 0)  as known_value,
        avg(deal_value) filter (where not missing_value)               as avg_known_value,
        count(*) filter (where missing_value)                          as unvalued_opps,
        count(*) filter (where overdue)                                as overdue_opps,
        count(*) filter (where stale)                                  as stale_opps
    from v_forecast
    group by rep
)
select
    rep, open_opps, with_value, with_close_date, forecastable,
    round(100.0 * forecastable / nullif(open_opps, 0), 1) as forecastable_pct,
    round(100.0 * with_value   / nullif(open_opps, 0), 1) as valued_pct,
    known_value,
    round(avg_known_value, 0)                             as avg_known_value,
    unvalued_opps,
    round(avg_known_value * unvalued_opps, 0)             as est_blind_value,
    overdue_opps,
    stale_opps
from per_rep;


-- =====================================================================================
-- PART 7 - the journey, and the funnel, corrected
--
-- Replaces 008's versions. Two defects fixed:
--
--   1. The opportunity join is now v_opportunity_primary, so a contact with two deals is
--      one row rather than two (008 double-counted them into the funnel).
--   2. The milestone window was hardcoded to >= 2026-08-01, which silently truncated the
--      journey of any contact engaged before the backfill window and made days-between
--      metrics wrong rather than absent. It now reads every milestone available and exposes
--      history_from so a reader can see where the data actually starts.
--
-- DROP, not CREATE OR REPLACE. Postgres will not let a replace insert a column into the
-- middle of a view's column list or remove one, and both happen here (v_journey gains
-- last_call_utc / deal_value / expected_close_date; v_funnel_conversion loses
-- avg_days_to_prospect). v_funnel_conversion has to go first because 008's version depends
-- on v_journey and Postgres refuses to drop a view something else reads.
-- =====================================================================================

drop view if exists v_funnel_conversion;
drop view if exists v_funnel_rep;
drop view if exists v_journey;

create view v_journey as
with ms as (
    select
        prospect_id,
        min(changed_at_utc) filter (where current_stage = 'Engaged')      as engaged_at,
        min(changed_at_utc) filter (where current_stage = 'Prospect')     as prospect_at,
        min(changed_at_utc) filter (where current_stage = 'Customer')     as customer_at,
        min(changed_at_utc) filter (where current_stage = 'Disqualified') as disqualified_at
    from v_stage_history
    group by prospect_id
),
firstcall as (
    select prospect_id,
           min(called_at_utc)                as first_call_utc,
           max(called_at_utc)                as last_call_utc,
           count(*)                          as total_calls,
           count(*) filter (where connected) as total_connects
    from fact_call
    group by prospect_id
)
select
    ct.prospect_id,
    coalesce(ct.owner_name, '<unassigned>')  as rep,
    ct.company_name,
    ct.full_name                             as contact_name,
    ct.contact_stage                         as stage_now,
    fc.first_call_utc,
    fc.last_call_utc,
    ms.engaged_at,
    ms.prospect_at,
    coalesce(ms.customer_at, ms.disqualified_at) as closed_at,
    case when ms.customer_at      is not null then 'Customer'
         when ms.disqualified_at  is not null then 'Disqualified'
         else 'Open' end                     as outcome,
    coalesce(fc.total_calls, 0)              as calls,
    coalesce(fc.total_connects, 0)           as connects,
    o.stage                                  as deal_stage,
    o.status                                 as deal_status,
    o.deal_value,
    o.expected_close_date,
    round(extract(epoch from (ms.engaged_at  - fc.first_call_utc)) / 86400.0, 1) as days_call_to_engaged,
    round(extract(epoch from (ms.prospect_at - ms.engaged_at))     / 86400.0, 1) as days_engaged_to_prospect,
    round(extract(epoch from (coalesce(ms.customer_at, ms.disqualified_at) - ms.prospect_at)) / 86400.0, 1)
                                                                                 as days_prospect_to_close
from dim_contact ct
left join ms                    on ms.prospect_id = ct.prospect_id
left join firstcall fc          on fc.prospect_id = ct.prospect_id
left join v_opportunity_primary o on o.prospect_id = ct.prospect_id
where ms.engaged_at is not null
   or ct.contact_stage in ('Prospect','Customer')
   or o.prospect_id is not null;


-- --------------------------------------------------------------------------------------
-- v_funnel_rep - the full funnel per rep, from assigned book through to a closed deal.
--
-- Deliberately sourced from TWO places, because they answer different questions and mixing
-- them is the classic funnel error:
--   * book columns come from fact_book_snapshot - the whole assigned book, whether or not
--     anyone has ever touched it. This is the denominator that matters for coverage.
--   * movement columns come from the journey - what actually happened.
-- A funnel built only on touched contacts always looks healthy, because the untouched ones
-- are invisible. Both halves sit on one row so the gap is unavoidable.
-- --------------------------------------------------------------------------------------
create view v_funnel_rep as
with book as (
    select coalesce(owner_name, owner_id) as rep,
           sum(contacts)                                                    as book_size,
           sum(contacts) filter (where contact_stage in ('Fresh','Engaged','Prospect')) as workable,
           sum(contacts) filter (where contact_stage = 'Fresh')             as fresh
    from fact_book_snapshot
    where snapshot_date = (select max(snapshot_date) from fact_book_snapshot)
    group by 1
),
moved as (
    select rep,
           count(*)                                              as touched,
           count(*) filter (where engaged_at   is not null)      as engaged,
           count(*) filter (where prospect_at  is not null)      as prospect,
           count(*) filter (where deal_stage   is not null)      as with_opportunity,
           count(*) filter (where deal_status = 'Won')           as won,
           count(*) filter (where deal_status = 'Lost')          as lost,
           count(*) filter (where outcome = 'Disqualified')      as disqualified
    from v_journey
    group by rep
)
select
    coalesce(b.rep, m.rep)                        as rep,
    coalesce(b.book_size, 0)                      as book_size,
    coalesce(b.workable, 0)                       as workable,
    coalesce(b.fresh, 0)                          as untouched_fresh,
    coalesce(m.touched, 0)                        as in_journey,
    coalesce(m.engaged, 0)                        as engaged,
    coalesce(m.prospect, 0)                       as prospect,
    coalesce(m.with_opportunity, 0)               as opportunities,
    coalesce(m.won, 0)                            as won,
    coalesce(m.lost, 0)                           as lost,
    coalesce(m.disqualified, 0)                   as disqualified,
    round(100.0 * coalesce(m.engaged, 0)  / nullif(b.workable, 0), 1)  as book_to_engaged_pct,
    round(100.0 * coalesce(m.prospect, 0) / nullif(m.engaged, 0), 1)   as engaged_to_prospect_pct,
    round(100.0 * coalesce(m.with_opportunity, 0) / nullif(m.prospect, 0), 1) as prospect_to_opp_pct,
    round(100.0 * coalesce(m.won, 0) / nullif(m.won + m.lost, 0), 1)   as win_rate_pct
from book b
full outer join moved m on m.rep = b.rep;

-- 008's v_funnel_conversion is superseded by v_funnel_rep. Kept as a thin alias so anything
-- already pointing at it keeps working rather than erroring at refresh time.
create view v_funnel_conversion as
select rep,
       engaged                  as contacts_engaged,
       prospect                 as reached_prospect,
       opportunities            as has_opportunity,
       won, lost,
       engaged_to_prospect_pct,
       win_rate_pct             as prospect_to_customer_pct
from v_funnel_rep;


-- =====================================================================================
-- PART 7b - forward compatibility for per-call disposition, recording and transcript
--
-- Three changes are already in flight and all three land on fact_call:
--   * LSQ is being asked for a per-call disposition, so a rep marks the outcome of THAT
--     call instead of overwriting one field on the contact.
--   * Recording URLs start being stored per call.
--   * Call transcripts follow, to feed the AI analysis this dataset is being built for.
--
-- The columns go in now, nullable and unused. Adding a nullable column to a 8,000-row table
-- is instant; retrofitting one after 200,000 rows exist, with a re-ingest that costs one API
-- call per lead because there is no bulk activity read, is not. This is the cheap moment.
--
-- disposition_at_call below then needs no further change: the day real per-call values start
-- arriving it prefers them automatically, and everything before that keeps using the
-- inference. The coalesce order matters - fact_call.disposition is NULL when absent, so it
-- is safe upstream. A placeholder string there would defeat the whole chain (gotcha 18).
-- =====================================================================================

alter table fact_call add column if not exists disposition     text;
alter table fact_call add column if not exists transcript      text;
alter table fact_call add column if not exists transcript_url  text;

create or replace view v_call_disposition_at_time as
select
    c.activity_id,
    c.prospect_id,
    c.called_at_utc,
    coalesce(
        -- Preferred: the disposition the rep marked against THIS call. Empty until LSQ
        -- ships per-call dispositions.
        c.disposition,
        -- Fallback: the first value written to the contact-level field within 12 hours of
        -- the call. An inference, and only available from the field-change cutover onward.
        (
            select f.new_value
            from fact_field_change f
            where f.prospect_id = c.prospect_id
              and f.field_name = 'mx_Call_Disposition'
              and f.changed_at_utc >= c.called_at_utc
              and f.changed_at_utc < c.called_at_utc + interval '12 hours'
            order by f.changed_at_utc asc
            limit 1
        )
    ) as disposition_at_call,
    case when c.disposition is not null then 'per-call' else 'inferred' end as disposition_source
from fact_call c;


-- =====================================================================================
-- PART 8 - QC
--
-- Every number on every tab has to survive a check that does not share its arithmetic.
-- These run against the warehouse; scripts/pipeline/verify-against-oracle.ps1 runs the
-- other half against LeadSquared itself.
--
-- Shape is deliberately one row per check with expected / actual / status, so the QC tab is
-- readable by someone who did not write it and a regression shows up as a FAIL rather than
-- as a number that quietly looks slightly different.
-- =====================================================================================

create or replace view v_data_boundaries as
select 'fact_call'          as stream,
       count(*)             as row_count,
       min(call_date_ist)::text as earliest,
       max(call_date_ist)::text as latest,
       'Exact from the backfill start date; live from the webhook cutover.' as note
from fact_call
union all
select 'fact_stage_change', count(*), min(changed_at_utc)::date::text, max(changed_at_utc)::date::text,
       'Full history per contact - 3002 is unbounded by date in the backfill.'
from fact_stage_change
union all
select 'fact_field_change', count(*), min(change_date_ist)::text, max(change_date_ist)::text,
       'Disposition and stage history begins at the webhook cutover 2026-08-08 11:51 IST. Nothing before that is recoverable.'
from fact_field_change
union all
select 'fact_opportunity', count(*), min(created_date_ist)::text, max(created_date_ist)::text,
       'Current state per opportunity. Deal-stage history begins only when an opportunity update webhook fires.'
from fact_opportunity
union all
select 'fact_book_snapshot', count(*), min(snapshot_date)::text, max(snapshot_date)::text,
       'One snapshot of the whole assigned book per run day.'
from fact_book_snapshot;


create or replace view v_qc_pipeline as

-- 1. Duplicate facts. The PK makes this impossible, so a non-zero here means the PK is not
--    what we think it is - worth one cheap check rather than an assumption.
select 1 as seq, 'No duplicate call activity ids' as check_name,
       '0'::text as expected,
       (count(*) - count(distinct activity_id))::text as actual,
       case when count(*) = count(distinct activity_id) then 'PASS' else 'FAIL' end as status,
       'fact_call'::text as scope
from fact_call

union all
-- 2. Enrichment coverage. A call whose contact was never enriched has no rep name, no
--    company and no stage, so it silently vanishes from every grouped view. This is the
--    single most common cause of a dashboard total that is lower than LSQ's own filter.
select 2, 'Every call joins to an enriched contact',
       '0',
       count(*)::text,
       case when count(*) = 0 then 'PASS' else 'WARN' end,
       'fact_call left join dim_contact'
from fact_call c
left join dim_contact ct on ct.prospect_id = c.prospect_id
where ct.prospect_id is null

union all
-- 3. Connected is derived from duration, so the two must never disagree.
select 3, 'connected flag matches duration > 0',
       '0',
       count(*)::text,
       case when count(*) = 0 then 'PASS' else 'FAIL' end,
       'fact_call'
from fact_call
where connected <> (duration_sec > 0)

union all
-- 4. The AI dialler must never be stored. If 208 ever appears it inflates every coverage
--    number in the account, and it looks like rep activity.
select 4, 'No Callkaro AI-dialler calls stored',
       '0',
       count(*)::text,
       case when count(*) = 0 then 'PASS' else 'FAIL' end,
       'fact_call.event_code in (21,22) only'
from fact_call
where event_code not in ('21','22')

union all
-- 5. The dashboard pivot must sum to the same total as the raw fact table for the same day.
--    These two numbers are computed by different SQL; if they ever diverge, the pivot is
--    dropping rows - which is precisely how a disposition value nobody enumerated goes
--    missing.
select 5, 'Pivot total equals raw dials (today)',
       (select count(*)::text from fact_call
         where call_date_ist = ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date
           and direction = 'outbound'),
       coalesce((select sum(calls)::text from v_pivot_disposition
                  where call_date_ist = ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date), '0'),
       case when (select count(*) from fact_call
                   where call_date_ist = ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date
                     and direction = 'outbound')
               = coalesce((select sum(calls) from v_pivot_disposition
                            where call_date_ist = ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date), 0)
            then 'PASS' else 'FAIL' end,
       'v_pivot_disposition vs fact_call'

union all
-- 6. Contacts sitting at Prospect with no opportunity behind them. Not a bug in the
--    pipeline - a gap in the CRM, and the operational definition of the Prospect stage says
--    it should be zero. Reported as a number to work, not as a failure.
select 6, 'Prospect-stage contacts that have an opportunity',
       (select count(*)::text from dim_contact where contact_stage = 'Prospect'),
       (select count(distinct o.prospect_id)::text
          from v_opportunity_primary o
          join dim_contact ct on ct.prospect_id = o.prospect_id
         where ct.contact_stage = 'Prospect'),
       'INFO',
       'dim_contact vs fact_opportunity'

union all
-- 7. Opportunities whose contact is not in dim_contact at all. Means the deal board will
--    show '<unassigned>' for a real rep.
select 7, 'Every opportunity joins to a contact',
       '0',
       count(*)::text,
       case when count(*) = 0 then 'PASS' else 'WARN' end,
       'fact_opportunity left join dim_contact'
from fact_opportunity o
left join dim_contact ct on ct.prospect_id = o.prospect_id
where ct.prospect_id is null

union all
-- 8. Stage taxonomy drift. The 2026-07-31 migration left zero non-canonical values; any
--    number here is new drift, and drifted values are invisible to a rep's own UI filter.
select 8, 'Contacts on a non-canonical stage',
       '0',
       coalesce((select sum(contacts)::text from v_stage_drift), '0'),
       case when coalesce((select sum(contacts) from v_stage_drift), 0) = 0 then 'PASS' else 'FAIL' end,
       'fact_book_snapshot vs canonical stage list'

union all
-- 9. Forecast coverage. Not a pass/fail on the pipeline - it is the business number this
--    whole migration exists to expose.
select 9, 'Open opportunities that can be forecast',
       (select coalesce(sum(open_opps), 0)::text from v_forecast_quality),
       (select coalesce(sum(forecastable), 0)::text from v_forecast_quality),
       case when (select coalesce(sum(open_opps), 0) from v_forecast_quality) = 0 then 'INFO'
            when (select coalesce(sum(forecastable), 0) from v_forecast_quality)
               = (select coalesce(sum(open_opps), 0) from v_forecast_quality) then 'PASS'
            else 'GAP' end,
       'v_forecast_quality'

union all
-- 10. Deal-stage drift, the opportunity-side twin of check 8. On 2026-08-09 this was 15
--     deals still on 'Requirement Gathering', a value the restructure was supposed to rename
--     to 'Prospect' via a UI edit that was never applied.
select 10, 'Deals on a non-canonical stage',
       '0',
       coalesce((select sum(opportunities)::text from v_deal_stage_drift), '0'),
       case when coalesce((select sum(opportunities) from v_deal_stage_drift), 0) = 0
            then 'PASS' else 'FAIL' end,
       'fact_opportunity vs canonical deal stage list'

union all
-- 11. Deal value and expected close date do not exist as LSQ fields yet (see PART 1). This
--     check is here so that the day they ARE created, the number starts moving on its own
--     instead of someone having to remember to look.
select 11, 'Open deals carrying a deal value',
       (select coalesce(sum(open_opps), 0)::text from v_forecast_quality),
       (select coalesce(sum(with_value), 0)::text from v_forecast_quality),
       case when (select coalesce(sum(open_opps), 0) from v_forecast_quality) = 0 then 'INFO'
            when (select coalesce(sum(with_value), 0) from v_forecast_quality) = 0
                 then 'NO FIELD'
            else 'GAP' end,
       'v_forecast_quality - the LSQ field itself does not exist yet'

union all
-- 12. THE CLIPPED-STREAM CHECK. Two fact streams are documented as unbounded by date -
--     stage changes and opportunities - because working out what stage a contact was in when
--     it was called, or which deal is live on it, needs history older than any reporting
--     window. If either one's earliest record lands exactly on the earliest CALL date, it is
--     not unbounded: it is being clipped to the call window.
--
--     This is not hypothetical. On 2026-08-09 the backfill's date gate sat above the
--     opportunity branch instead of below it, so every deal created before the window was
--     dropped. Phase 3 had created 4,404 opportunities in July; the deal board showed 254.
--     It looked plausible and was internally consistent, which is exactly why it needed a
--     check that compares two streams rather than examining one.
select 12, 'Unbounded streams are not clipped to the call window',
       'earliest opportunity and stage change both older than earliest call',
       coalesce((select 'opp ' || min(created_date_ist)::text from fact_opportunity), 'opp none')
         || ' / stage ' ||
       coalesce((select min(changed_at_utc)::date::text from fact_stage_change), 'none')
         || ' / call ' ||
       coalesce((select min(call_date_ist)::text from fact_call), 'none'),
       case
         when (select count(*) from fact_opportunity) = 0 then 'INFO'
         when (select min(created_date_ist) from fact_opportunity)
              >= (select min(call_date_ist) from fact_call)
           or (select min(changed_at_utc)::date from fact_stage_change)
              >= (select min(call_date_ist) from fact_call)
         then 'FAIL'
         else 'PASS'
       end,
       'fact_opportunity / fact_stage_change vs fact_call'

union all
-- 13. Book snapshot freshness. Every pipeline-state and funnel number is only as current as
--     the last snapshot, and a stale snapshot looks exactly like a current one.
select 13, 'Book snapshot is from today',
       ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date::text,
       coalesce((select max(snapshot_date)::text from fact_book_snapshot), 'never'),
       case when (select max(snapshot_date) from fact_book_snapshot)
               = ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date
            then 'PASS' else 'STALE' end,
       'fact_book_snapshot';


-- =====================================================================================
-- PART 9 - grants
--
-- anon reads aggregate views only, so the Excel workbook can be shared without shipping a
-- key that reads phone numbers or recording URLs. v_forecast is deliberately INCLUDED
-- despite naming companies and contacts - a forecast without deal names is unusable, and it
-- carries no phone number or recording. fact_* stay revoked.
-- =====================================================================================

grant select on v_prospects_daily, v_deal_board, v_deal_stage_detail, v_forecast,
                v_forecast_quality, v_funnel_rep, v_funnel_conversion, v_journey,
                v_opportunity_primary, v_qc_pipeline, v_data_boundaries,
                v_deal_stage_drift
          to anon, authenticated;
