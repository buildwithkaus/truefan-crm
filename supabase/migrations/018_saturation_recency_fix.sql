-- =====================================================================================
-- TrueFan CRM - 018: connected_no_progress must test RECENCY (2026-08-11)
--
-- THE DEFECT. 016's bucket CASE assigned connected_no_progress to any contact that had been
-- reached and was still at Engaged, with no test of when. Measured on the first real load:
--
--     connected_no_progress total          2,024
--       last attempt within 7 days         1,888   <-- actively being worked
--       last attempt more than 7 days ago    136   <-- actually stalled
--
-- So 93% of the bucket was contacts a rep had spoken to THIS WEEK. Reported as-is it would
-- have said "2,024 conversations went nowhere" when the true figure is 136, and it would
-- have made the most active reps look like the worst ones - the same inversion the
-- Callkaro-inclusion and the inherited-calls bugs each produced in their turn.
--
-- Every other bucket already tested staleness. This one was written as a stage test and
-- inherited none of it.
--
-- THE FIX. Split by recency, and give the recent half its own honest name rather than
-- letting it fall through to connected_progressing - which would have been a second wrong
-- label, since "progressing" should mean the stage actually moved.
-- =====================================================================================

-- --------------------------------------------------------------------------------------
-- DROP ORDER FIRST. CREATE OR REPLACE VIEW can only APPEND columns - it cannot rename or
-- reorder them:
--
--     ERROR 42P16: cannot change name of view column "saturated" to "connected_recent"
--
-- v_book_health gains connected_recent in the middle of its column list, so it has to be
-- dropped and recreated. And its dependents must go first: v_qc_saturation reads
-- v_book_health, so dropping health alone fails on the dependency.
--
-- Migration 012 hit exactly this ("fix 012 drop order: v_qc_pipeline has to go before
-- v_forecast_quality"). Dependents down, then rebuild up.
--
-- v_book_saturation itself only changes the VALUES in its bucket column, not the column
-- list, so create-or-replace is still safe for it.
-- --------------------------------------------------------------------------------------
drop view if exists v_qc_saturation;
drop view if exists v_book_health;

create or replace view v_book_saturation as
with cfg as (
    select
        (select value::int from app_config where key = 'saturation_payoff_attempts') as payoff,
        (select value::int from app_config where key = 'saturation_stale_days')      as stale
)
select
    w.*,
    case
        -- Done. No further work is owed on these, whatever the attempt count says.
        when w.contact_stage in ('Customer', 'Disqualified')            then 'terminal'
        when w.attempts_by_owner = 0                                    then 'never_touched'

        -- Reached a human AND the stage moved past Engaged: this is working.
        when w.connects_by_owner > 0
             and w.contact_stage <> 'Engaged'                           then 'connected_progressing'
        -- Reached a human, still at Engaged, and nothing since: genuinely stalled. THIS is
        -- the coaching bucket - the follow-up failed, not the dialling.
        when w.connects_by_owner > 0
             and coalesce(w.days_since_last_attempt, 9999) > (select stale from cfg)
                                                                        then 'connected_no_progress'
        -- Reached a human recently and still at Engaged: a live conversation, not a failure.
        when w.connects_by_owner > 0                                    then 'connected_recent'

        -- Never reached. The measured attempt curve decides exhausted vs abandoned.
        when w.attempts_by_owner >= (select payoff from cfg) + 1        then 'saturated'
        when w.attempts_by_owner = 1
             and w.days_since_last_attempt > (select stale from cfg)    then 'one_and_done'
        when w.days_since_last_attempt > (select stale from cfg)        then 'under_worked'
        else 'in_progress'
    end                                                                 as bucket
from v_contact_work w;


-- --------------------------------------------------------------------------------------
-- v_book_health - connected_recent added as its own column so it can never be silently
-- folded into either the exhausted or the recoverable side. It is neither: it is work in
-- flight, and counting it as either would misstate the answer to "can I have more leads".
-- --------------------------------------------------------------------------------------
create view v_book_health as
select
    rep,
    count(*)                                                       as contacts,
    count(*) filter (where bucket = 'never_touched')               as never_touched,
    count(*) filter (where bucket = 'one_and_done')                as one_and_done,
    count(*) filter (where bucket = 'under_worked')                as under_worked,
    count(*) filter (where bucket = 'connected_no_progress')        as connected_no_progress,
    count(*) filter (where bucket = 'connected_recent')             as connected_recent,
    count(*) filter (where bucket = 'saturated')                    as saturated,
    count(*) filter (where bucket = 'connected_progressing')        as progressing,
    count(*) filter (where bucket = 'terminal')                     as terminal,
    count(*) filter (where bucket = 'in_progress')                  as in_progress,

    count(*) filter (where bucket in ('terminal','saturated','connected_progressing'))
                                                                    as exhausted,
    count(*) filter (where bucket in ('never_touched','one_and_done','under_worked','connected_no_progress'))
                                                                    as recoverable,
    round(100.0 * count(*) filter (where bucket in ('never_touched','one_and_done','under_worked','connected_no_progress'))
          / nullif(count(*), 0), 1)                                 as recoverable_pct,

    round(avg(attempts_by_owner), 2)                                as mean_attempts,
    round(avg(days_to_first_touch), 1)                              as mean_days_to_first_touch,
    -- Coverage. Everything above is computed over contacts the warehouse can see;
    -- days_held and days_to_first_touch additionally need assignment history, which is
    -- loaded per lead at one API call each. A low number here means the ageing columns
    -- describe a sample, and saying so is the difference between a report and a guess.
    count(*) filter (where assigned_at_utc is not null)              as with_assignment_history
from v_book_saturation
group by rep
order by recoverable desc;


-- --------------------------------------------------------------------------------------
-- v_qc_saturation - the bucket-sum check has to learn the new bucket, or it fails on
-- correct data. That failure mode (a check that cries wolf) is what 017 fixed for channels.
-- --------------------------------------------------------------------------------------
create view v_qc_saturation as
select 'every contact lands in exactly one bucket'::text as check_name,
       (select count(*)::text from v_contact_work)        as expected,
       (select count(*)::text from v_book_saturation)     as actual,
       case when (select count(*) from v_contact_work) = (select count(*) from v_book_saturation)
            then 'PASS' else 'FAIL' end                   as status,
       'v_contact_work vs v_book_saturation'::text        as compared_against
union all
select 'buckets sum to the contact count',
       (select count(*)::text from v_book_saturation),
       (select (sum(exhausted) + sum(recoverable) + sum(in_progress) + sum(connected_recent))::text
          from v_book_health),
       case when (select count(*) from v_book_saturation)
               = (select sum(exhausted) + sum(recoverable) + sum(in_progress) + sum(connected_recent)
                    from v_book_health)
            then 'PASS' else 'FAIL' end,
       'v_book_health column sums'
union all
select 'connected_no_progress is stale-only',
       '0',
       (select count(*)::text from v_book_saturation
         where bucket = 'connected_no_progress'
           and days_since_last_attempt <= (select value::int from app_config where key = 'saturation_stale_days')),
       case when (select count(*) from v_book_saturation
                   where bucket = 'connected_no_progress'
                     and days_since_last_attempt <= (select value::int from app_config where key = 'saturation_stale_days')) = 0
            then 'PASS' else 'FAIL' end,
       -- Asserts the 018 fix directly. Without it the bucket silently reverts to counting
       -- live conversations as failures the next time this CASE is edited.
       'v_book_saturation recency test'
union all
select 'assignment history loaded',
       '>0',
       (select count(*)::text from fact_assignment),
       case when (select count(*) from fact_assignment) > 0 then 'PASS' else 'WARN' end,
       'fact_assignment row count';

revoke all on v_book_saturation  from anon, authenticated;
revoke all on v_book_health      from anon, authenticated;
revoke all on v_qc_saturation    from anon, authenticated;
