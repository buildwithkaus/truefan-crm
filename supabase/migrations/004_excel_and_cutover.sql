-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 004: disposition-history cutover, and read-only access for the Excel dashboard
--
-- Two unrelated changes that both landed on 2026-08-08. Safe to re-run.
-- =====================================================================================

-- --------------------------------------------------------------------------------------
-- 1. The disposition-history cutover.
--
-- mx_Call_Disposition is a LEAD field holding only its CURRENT value. LeadSquared keeps no
-- history of it, and no activity records the change - so for any call before we started
-- listening, the disposition that applied AT THE TIME is unrecoverable. Full stop.
--
-- Three field-change webhooks were created on 2026-08-08 (mx_Call_Disposition,
-- ProspectStage, mx_Disqualification_Reason), so from that date forward the history is
-- captured properly.
--
-- Decision (Kaustubh, 2026-08-08): show NOTHING rather than something approximate. Before
-- the cutover the disposition column reads '<no history>'. Using the contact's present
-- disposition would be right for the many contacts called once and untouched since, and
-- quietly wrong for every repeatedly-worked one - and a number nobody can tell is
-- approximate eventually gets quoted as fact in a review.
--
-- Stage is NOT subject to this: EventCode 3002 carries PreviousStage/CurrentStage with a
-- timestamp and the backfill loads the whole history, so stage-at-call-time is exact all
-- the way back.
-- --------------------------------------------------------------------------------------
insert into app_config (key, value)
values ('disposition_history_from', '2026-08-08')
on conflict (key) do nothing;

-- Projected in a CTE first, then aggregated. The disposition column is now a CASE
-- expression, so it must be computed BEFORE the GROUP BY and referenced by its alias -
-- reaching back to the raw e.call_disposition in the select list is what Postgres rejects
-- with "must appear in the GROUP BY clause".
create or replace view v_pivot_disposition as
with cutover as (
    select coalesce(
        (select value from app_config where key = 'disposition_history_from'),
        '2999-01-01'
    )::date as from_date
),
base as (
    select
        e.call_date_ist,
        coalesce(e.contact_owner_name, e.actor_name) as rep,
        e.stage_at_call                              as contact_stage,
        case
            when e.call_date_ist < (select from_date from cutover) then '<no history>'
            else e.call_disposition
        end                                          as disposition,
        e.prospect_id,
        e.connected,
        e.duration_sec
    from v_call_enriched e
    where e.direction = 'outbound'
)
select
    call_date_ist,
    rep,
    contact_stage,
    disposition,
    count(*)                            as calls,
    count(distinct prospect_id)         as contacts,
    count(*) filter (where connected)   as connects,
    round(sum(duration_sec) / 60.0, 1)  as talk_min,
    -- Only meaningful once the value is real; a placeholder is not "unselectable".
    (disposition not in ('<no history>', '<blank>')
     and not exists (select 1 from ref_canonical_value v
                     where v.field = 'call_disposition' and v.value = disposition))
                                        as disposition_not_selectable
from base
group by 1, 2, 3, 4;


-- --------------------------------------------------------------------------------------
-- 2. Read-only access for Excel.
--
-- The Excel workbook lives on OneDrive and gets shared with the team, so whatever key it
-- carries is effectively handed to everyone who opens it. The service_role key must NEVER
-- go in that file - it bypasses RLS and grants full write access to the whole database.
--
-- The anon key is granted SELECT on the aggregate views ONLY. Base tables stay unreachable,
-- so a leaked workbook exposes reporting aggregates and nothing else. Note fact_call is
-- deliberately NOT granted: it carries phone numbers and call-recording URLs.
-- --------------------------------------------------------------------------------------
grant usage on schema public to anon;

grant select on
    v_rep_day,
    v_pivot_disposition,
    v_daily_totals,
    v_funnel_movement,
    v_hygiene_exceptions,
    v_pipeline_health
to anon;

-- Views run as their owner, so they read the RLS-protected base tables on anon's behalf
-- without anon ever being able to query those tables directly. Confirm that holds:
--
--   with the anon key:  select * from fact_call limit 1;    -- must fail / return nothing
--                       select * from v_rep_day limit 1;    -- must return rows
