-- =====================================================================================
-- TrueFan CRM - 030: 'Future Prospect' is a contact stage (2026-08-12)
--
-- It was modelled as a Company stage only, so the 2026-07-31 restructure treated it as a
-- legacy CONTACT value and mapped it to Disqualified. It is a real contact stage
-- (Kaustubh, 2026-08-12): "right business, no need right now" - a live revisit list, not a
-- closed account.
--
-- WHAT THE EARLIER READING COST. 2,729 contacts were moved to Disqualified on 2026-08-11 and
-- rolled back on 2026-08-12, after reps noticed their accounts had gone. The rollback is only
-- durable if the taxonomy agrees, in all four places that encode it:
--
--   scripts/lib/schema.ps1                    ContactStages + StageMap  (done)
--   supabase/functions/_shared/schema.ts      CONTACT_STAGES            (done)
--   ref_canonical_value                       this file
--   views that hardcode the five values       this file
--
-- Miss one and the stage reads as drift somewhere: the reconciler moves it back, or a QC
-- check fails forever, or contacts vanish into an 'other' bucket on a tab.
-- =====================================================================================

insert into ref_canonical_value (field, value) values
    ('contact_stage', 'Future Prospect')
on conflict (field, value) do nothing;


-- --------------------------------------------------------------------------------------
-- v_pipeline_state_wide - the book, pivoted. It filters on a FIXED list of stage names, so
-- 'Future Prospect' was landing in 'other' - 2,756 contacts in a column labelled as taxonomy
-- drift rather than as a stage.
--
-- Given its own column, and counted as WORKABLE: a future prospect is a live account waiting
-- on timing, which is the opposite of done. Leaving it out of the workable pool would make
-- every rep's book look smaller than it is and every coverage rate look better.
-- --------------------------------------------------------------------------------------
create or replace view v_pipeline_state_wide as
with latest as (select max(snapshot_date) as d from fact_book_snapshot)
select
    coalesce(b.owner_name, b.owner_id)                                as rep,
    sum(b.contacts)                                                   as book_size,
    sum(b.contacts) filter (where b.contact_stage = 'Fresh')          as fresh,
    sum(b.contacts) filter (where b.contact_stage = 'Engaged')        as engaged,
    sum(b.contacts) filter (where b.contact_stage = 'Prospect')       as prospect,
    sum(b.contacts) filter (where b.contact_stage = 'Customer')       as customer,
    sum(b.contacts) filter (where b.contact_stage = 'Disqualified')   as disqualified,
    sum(b.contacts) filter (where b.contact_stage = 'Future Prospect') as future_prospect,
    sum(b.contacts) filter (where b.contact_stage not in
        ('Fresh','Engaged','Prospect','Customer','Disqualified','Future Prospect')) as other,
    sum(b.contacts) filter (where b.contact_stage in
        ('Fresh','Engaged','Prospect','Future Prospect'))             as workable,
    round(100.0 * sum(b.contacts) filter (where b.contact_stage = 'Fresh')
          / nullif(sum(b.contacts) filter (where b.contact_stage in
              ('Fresh','Engaged','Prospect','Future Prospect')), 0), 1)  as pct_untouched,
    round(100.0 * sum(b.contacts) filter (where b.contact_stage = 'Prospect')
          / nullif(sum(b.contacts) filter (where b.contact_stage in
              ('Fresh','Engaged','Prospect','Future Prospect')), 0), 1)  as pct_at_prospect,
    max(b.snapshot_date)                                              as as_of
from fact_book_snapshot b
join latest l on b.snapshot_date = l.d
group by 1;


-- --------------------------------------------------------------------------------------
-- v_book_saturation - 'terminal' means no further work is owed. A future prospect is owed
-- work, just not yet, so it gets its own bucket rather than being filed with Customer and
-- Disqualified.
--
-- It is NOT counted as recoverable either: chasing an account that said "not now" before its
-- revisit date is exactly the behaviour the stage exists to prevent. It sits apart, which is
-- the honest answer - work that is scheduled rather than owed or finished.
-- --------------------------------------------------------------------------------------
create or replace view v_book_saturation as
with cfg as (
    select
        (select value::int from app_config where key = 'saturation_payoff_attempts') as payoff,
        (select value::int from app_config where key = 'saturation_stale_days')      as stale
)
select
    w.*,
    case
        when w.contact_stage = 'Future Prospect'                        then 'future_prospect'
        when w.contact_stage in ('Customer', 'Disqualified')            then 'terminal'
        when w.attempts_by_owner = 0                                    then 'never_touched'
        when w.connects_by_owner > 0
             and w.contact_stage <> 'Engaged'                           then 'connected_progressing'
        when w.connects_by_owner > 0
             and coalesce(w.days_since_last_attempt, 9999) > (select stale from cfg)
                                                                        then 'connected_no_progress'
        when w.connects_by_owner > 0                                    then 'connected_recent'
        when w.attempts_by_owner >= (select payoff from cfg) + 1        then 'saturated'
        when w.attempts_by_owner = 1
             and w.days_since_last_attempt > (select stale from cfg)    then 'one_and_done'
        when w.days_since_last_attempt > (select stale from cfg)        then 'under_worked'
        else 'in_progress'
    end                                                                 as bucket
from v_contact_work w;


-- v_book_health gains the column. Dropped first because CREATE OR REPLACE VIEW cannot add a
-- column mid-list (ERROR 42P16), and v_qc_saturation depends on it - dependents down first.
drop view if exists v_qc_saturation;
drop view if exists v_book_health;

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
    count(*) filter (where bucket = 'future_prospect')              as future_prospect,
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
    count(*) filter (where assigned_at_utc is not null)              as with_assignment_history
from v_book_saturation
group by rep
order by recoverable desc;

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
       (select (sum(exhausted) + sum(recoverable) + sum(in_progress)
                + sum(connected_recent) + sum(future_prospect))::text from v_book_health),
       case when (select count(*) from v_book_saturation)
               = (select sum(exhausted) + sum(recoverable) + sum(in_progress)
                         + sum(connected_recent) + sum(future_prospect) from v_book_health)
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
       'v_book_saturation recency test'
union all
select 'assignment history loaded',
       '>0',
       (select count(*)::text from fact_assignment),
       case when (select count(*) from fact_assignment) > 0 then 'PASS' else 'WARN' end,
       'fact_assignment row count';

revoke all on v_pipeline_state_wide from anon, authenticated;
revoke all on v_book_saturation     from anon, authenticated;
revoke all on v_book_health         from anon, authenticated;
revoke all on v_qc_saturation       from anon, authenticated;
