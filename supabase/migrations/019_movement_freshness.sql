-- =====================================================================================
-- TrueFan CRM - 019: Stage Movement had silently stopped three days ago (2026-08-11)
--
-- THE BUG. v_funnel_movement (migration 002) reads fact_stage_change directly. That table is
-- fed ONLY by the trail backfill - there is no live EventCode 3002 ingest, because the 3xxx
-- system codes cannot be subscribed to (gotcha 37). Live stage changes have instead been
-- landing in fact_field_change via the ProspectStage field-change webhook since 2026-08-08.
--
-- Measured today:
--     fact_stage_change  latest row   2026-08-08
--     fact_field_change  latest row   2026-08-11 06:18 UTC
--
-- So the Stage Movement tab has been three days stale while looking perfectly healthy - no
-- error, no gap, just a tab whose last row quietly stopped advancing. That is the exact
-- failure mode this project keeps hitting: absence that reads as a quiet day.
--
-- v_stage_history (migration 006) already unions the two sources and exists precisely for
-- this. The movement view simply never got repointed at it.
--
-- WHY THIS IS NOT A ONE-LINE SWAP: v_stage_history exposes changed_at_utc, not the generated
-- change_date_ist column, so the IST conversion has to be done here. Every "which day" answer
-- in this warehouse uses IST - a call at 02:00 IST is the PREVIOUS date in UTC, and reporting
-- on the UTC date misfiles exactly the late-evening work a daily tab is judged on.
-- =====================================================================================

create or replace view v_funnel_movement as
select
    ((s.changed_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date as report_date,
    coalesce(r.lsq_name, s.changed_by_name, '<unknown>')  as rep,
    coalesce(s.previous_stage, '<none>')                  as from_stage,
    s.current_stage                                       as to_stage,
    count(distinct s.prospect_id)                         as contacts
from v_stage_history s
-- Name join, unavoidably: EventCode 3002 records changed_by as a DISPLAY NAME and no GUID
-- exists on the record. The webhook arm of v_stage_history has already resolved its own
-- names from owner_id, so this only affects trail rows.
left join dim_rep r on lower(btrim(r.lsq_name)) = lower(btrim(s.changed_by_name))
where ((s.changed_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date >= date '2026-08-01'
  and s.current_stage is not null
  and coalesce(s.previous_stage, '') is distinct from s.current_stage
group by 1, 2, 3, 4;


-- --------------------------------------------------------------------------------------
-- v_qc_movement - assert the tab is actually current.
--
-- A staleness check has to compare against something OUTSIDE its own source, or it just
-- confirms that the stale data is consistently stale. This compares the movement view's
-- newest date against the newest call in fact_call: if reps were calling yesterday, stages
-- moved yesterday, and a gap between the two is a broken feed rather than a quiet day.
-- --------------------------------------------------------------------------------------
create or replace view v_qc_movement as
select
    'stage movement is current with calling activity'::text as check_name,
    (select max(call_date_ist)::text from fact_call)         as expected,
    (select max(report_date)::text from v_funnel_movement)   as actual,
    case
        when (select max(report_date) from v_funnel_movement)
             >= (select max(call_date_ist) from fact_call) - 1 then 'PASS'
        else 'FAIL'
    end                                                      as status,
    'v_funnel_movement vs fact_call'::text                   as compared_against
union all
select
    'stage-change feeds both have recent rows',
    (select max(change_date_ist)::text from fact_stage_change),
    (select max((changed_at_utc at time zone 'UTC')::date)::text
       from fact_field_change where field_name = 'ProspectStage'),
    -- INFO, not FAIL: fact_stage_change is backfill-only by design and will always lag.
    -- Surfaced so the difference is visible rather than mistaken for a fault.
    'INFO',
    'fact_stage_change (backfill) vs fact_field_change (live)';

revoke all on v_funnel_movement from anon, authenticated;
revoke all on v_qc_movement     from anon, authenticated;
