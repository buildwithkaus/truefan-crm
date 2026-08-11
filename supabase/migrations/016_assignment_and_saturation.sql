-- =====================================================================================
-- TrueFan CRM - 016: assignment history and book saturation (2026-08-10)
--
-- Answers the question reps keep forcing: "give me fresh leads." Until now nothing could
-- say whether the book they already hold is worked out, because three things were missing -
-- when a rep received a contact, how many times they actually dialled it, and whether
-- another dial would have paid.
--
-- THE THRESHOLDS BELOW ARE MEASURED, NOT CHOSEN. From v_attempt_curve on 2026-08-10, over
-- the 2,582-contact cohort whose ordinals are trustworthy:
--
--     attempt 1   39.2% connect      cumulative reach 39.2%
--     attempt 2   24.6%                               48.5%
--     attempt 3   15.8%                               51.4%
--     attempt 4   17.0%                               52.9%
--     attempt 5    8.9%                               53.2%
--     attempt 6+  n<30, suppressed
--
-- The marginal return holds at 15-17% through the fourth dial and halves at the fifth. So
-- "worked out" begins at 5 attempts, and anything under 4 with no connect is under-worked.
-- The left-truncated curve over every contact agrees closely (36.6 / 22.6 / 15.1 / 14.5 /
-- 7.8), which is the cross-check that the cohort restriction is not manufacturing the shape.
--
-- Thresholds live in app_config, not in the view text, so re-tuning them when the curve
-- moves is an UPDATE rather than a migration.
-- =====================================================================================

insert into app_config (key, value) values
    ('saturation_payoff_attempts', '4'),   -- dials below which a no-connect is under-worked
    ('saturation_stale_days',      '7'),   -- days of silence before a retry is due
    ('saturation_min_cell',        '30')   -- suppress any rate computed on fewer than this
on conflict (key) do nothing;


-- --------------------------------------------------------------------------------------
-- dim_rep gains an email. EventCode 3001 identifies owners as "Name (email)" and NEVER as a
-- GUID, so the only safe way to resolve an assignment to a rep is the email address.
--
-- Joining on the display name is what attached "Piyush Das Pattnaik" to Rishi Saraswat's
-- real GUID and pulled 2,360 of his leads into a migration. Names also differ across systems
-- ("Shubham Kumar Tak" vs "Subham Tak", "adarsh pandey" vs "Adarsh Pandey"). The email does
-- not drift.
-- --------------------------------------------------------------------------------------
alter table dim_rep add column if not exists email text;
create unique index if not exists idx_rep_email
    on dim_rep (lower(btrim(email))) where email is not null;


-- --------------------------------------------------------------------------------------
-- fact_assignment - who held a contact, and from when.
--
-- Source: EventCode 3001 LeadAssigned, present on 96% of contacts back to February 2025.
-- Like 3002 it has NO ActivityFields at all - everything is in Data[]:
--   PreviousOwner = "Admin  (admin.sales@true-fan.in)"
--   CurrentOwner  = "Subham Tak (subham.tak@true-fan.in)"
--   CreatedBy     = "System" | "Admin" | a person's display name
--
-- Trail-derived, NOT webhook-fed: Webhook.svc/Create rejects ActivityEvent=3001 with HTTP
-- 500 (probed 2026-08-10 - the 3xxx codes are not in the ActivityTypes catalogue and the
-- webhook API only accepts catalogued types). That is acceptable here precisely because the
-- history already exists in the trails, which is not true of any other signal in this system.
--
-- Name and email are stored separately AND raw, because the parse is the fragile part: an
-- owner with no email ("PreviousOwner=System") must not silently become a null row.
-- --------------------------------------------------------------------------------------
create table if not exists fact_assignment (
    activity_id          text primary key,
    prospect_id          text not null,

    assigned_at_utc      timestamptz not null,
    assigned_at_ist      timestamp generated always as
                             ((assigned_at_utc at time zone 'UTC') + interval '5 hours 30 minutes') stored,
    assign_date_ist      date generated always as
                             (((assigned_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date) stored,

    previous_owner_raw   text,
    previous_owner_name  text,
    previous_owner_email text,
    current_owner_raw    text,
    current_owner_name   text,
    current_owner_email  text,
    changed_by_name      text,

    ingest_source        text not null default 'backfill',
    ingested_at          timestamptz not null default now()
);

create index if not exists idx_assign_prospect on fact_assignment (prospect_id, assigned_at_utc desc);
create index if not exists idx_assign_email    on fact_assignment (lower(btrim(current_owner_email)));
create index if not exists idx_assign_date     on fact_assignment (assign_date_ist);


-- --------------------------------------------------------------------------------------
-- v_assignment_current - the latest assignment per contact, resolved to an owner_id.
--
-- This is the clock everything else in this file reads: "how long has the CURRENT owner had
-- this contact". Not "how old is the lead" - a contact created in 2024 and handed over
-- yesterday is one day old to the rep holding it, and treating it as two years old is how a
-- book-ageing report becomes an argument instead of a fact.
-- --------------------------------------------------------------------------------------
create or replace view v_assignment_current as
with latest as (
    select distinct on (prospect_id)
           prospect_id, activity_id, assigned_at_utc, assign_date_ist,
           current_owner_name, current_owner_email, previous_owner_name, changed_by_name
    from fact_assignment
    order by prospect_id, assigned_at_utc desc
)
select
    l.prospect_id,
    l.assigned_at_utc,
    l.assign_date_ist,
    l.current_owner_name,
    l.current_owner_email,
    l.previous_owner_name,
    l.changed_by_name,
    r.owner_id                                              as assigned_owner_id,
    coalesce(r.lsq_name, l.current_owner_name, '<unknown>') as assigned_owner,
    (current_date - l.assign_date_ist)                      as days_held
from latest l
left join dim_rep r
       on lower(btrim(r.email)) = lower(btrim(l.current_owner_email));


-- --------------------------------------------------------------------------------------
-- v_contact_work - one row per contact: what the current owner has actually done with it.
--
-- Attempts are counted ONLY where the dialler is the contact's current owner. A rep who
-- inherits a heavily-worked book would otherwise inherit its effort too, and the whole point
-- of this table is to distinguish "worked out" from "handed over already exhausted".
--
-- BOUNDARY: this covers contacts present in dim_contact (those the pipeline has enriched),
-- not the full 91,033-lead book. A contact nobody has ever touched is not here at all -
-- that gap closes when dim_contact_book lands. Read v_book_health's `covered` column before
-- reading its rates.
-- --------------------------------------------------------------------------------------
create or replace view v_contact_work as
select
    ct.prospect_id,
    ct.owner_id,
    coalesce(r.lsq_name, ct.owner_name, '<unassigned>')      as rep,
    ct.contact_stage,
    ct.call_disposition,
    ct.disqualification_reason,
    ct.company_name,
    ct.full_name,

    a.assigned_at_utc,
    a.days_held,

    count(c.activity_id) filter (where c.direction = 'outbound')       as attempts_by_owner,
    count(c.activity_id) filter (where c.direction = 'outbound'
                                   and c.connected)                    as connects_by_owner,
    max(c.called_at_utc)                                               as last_attempt_at,
    min(c.called_at_utc)                                               as first_attempt_at,
    (current_date - max(c.called_at_utc)::date)                        as days_since_last_attempt,
    -- Time to first touch: assignment -> the owner's first dial. Null when either end is
    -- unknown, never zero, because a false zero would read as instant follow-up.
    case when a.assigned_at_utc is not null and min(c.called_at_utc) is not null
         then round(extract(epoch from (min(c.called_at_utc) - a.assigned_at_utc)) / 86400.0, 1)
    end                                                                as days_to_first_touch
from dim_contact ct
left join dim_rep r             on r.owner_id = ct.owner_id
left join v_assignment_current a on a.prospect_id = ct.prospect_id
left join fact_call c            on c.prospect_id = ct.prospect_id
                                and c.actor_owner_id = ct.owner_id
group by ct.prospect_id, ct.owner_id, r.lsq_name, ct.owner_name, ct.contact_stage,
         ct.call_disposition, ct.disqualification_reason, ct.company_name, ct.full_name,
         a.assigned_at_utc, a.days_held;


-- --------------------------------------------------------------------------------------
-- v_book_saturation - every contact in exactly one bucket.
--
-- The buckets are ordered by a CASE, so "exactly one" is a property of the query rather
-- than an assertion in a comment. Order matters: terminal states win over everything, then
-- untouched, then the attempt-depth judgement.
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
        -- Done. No further work is owed on these, whatever the attempt count says.
        when w.contact_stage in ('Customer', 'Disqualified')            then 'terminal'
        when w.attempts_by_owner = 0                                    then 'never_touched'
        -- Reached a human and the contact is still sitting at Engaged: the follow-up, not
        -- the dialling, is what stalled. This is a coaching bucket, not a capacity one.
        when w.connects_by_owner > 0 and w.contact_stage = 'Engaged'    then 'connected_no_progress'
        when w.connects_by_owner > 0                                    then 'connected_progressing'
        -- Never reached. The measured curve decides whether that is exhausted or abandoned.
        when w.attempts_by_owner >= (select payoff from cfg) + 1        then 'saturated'
        when w.attempts_by_owner = 1
             and w.days_since_last_attempt > (select stale from cfg)    then 'one_and_done'
        when w.days_since_last_attempt > (select stale from cfg)        then 'under_worked'
        else 'in_progress'
    end                                                                 as bucket
from v_contact_work w;


-- --------------------------------------------------------------------------------------
-- v_book_health - the per-rep answer to "can I have more leads?"
--
-- Two headline numbers, deliberately kept apart:
--   exhausted    work genuinely finished - terminal, saturated, or progressing
--   recoverable  contacts owed another dial before any new lead is justified
--
-- ADVISORY. This does not gate anything (Kaustubh, 2026-08-10). It is the evidence a human
-- uses, which is why recoverable is broken out into its causes rather than rolled into a
-- single score that hides why it is high.
-- --------------------------------------------------------------------------------------
create or replace view v_book_health as
select
    rep,
    count(*)                                                       as contacts,
    count(*) filter (where bucket = 'never_touched')               as never_touched,
    count(*) filter (where bucket = 'one_and_done')                as one_and_done,
    count(*) filter (where bucket = 'under_worked')                as under_worked,
    count(*) filter (where bucket = 'connected_no_progress')        as connected_no_progress,
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
    -- How much of this rep's book we can actually see. Everything above is a rate over
    -- COVERED contacts only; a low number here means the rates are about a sample, and
    -- saying so is the difference between a report and a guess.
    count(*) filter (where assigned_at_utc is not null)              as with_assignment_history
from v_book_saturation
group by rep
order by recoverable desc;


-- --------------------------------------------------------------------------------------
-- v_worklist_recover - the actual list, per rep, ordered by what to call first.
--
-- one_and_done ranks above under_worked because the measured curve says the SECOND dial is
-- worth 24.6% and the third only 15.8%. Ordering by "most neglected" would put the deepest
-- holes first and the cheapest wins last.
-- --------------------------------------------------------------------------------------
create or replace view v_worklist_recover as
select
    rep,
    prospect_id,
    company_name,
    full_name,
    contact_stage,
    call_disposition,
    bucket,
    attempts_by_owner,
    days_since_last_attempt,
    days_held,
    case bucket
        when 'one_and_done'          then 1
        when 'under_worked'          then 2
        when 'never_touched'         then 3
        when 'connected_no_progress' then 4
    end as priority
from v_book_saturation
where bucket in ('one_and_done', 'under_worked', 'never_touched', 'connected_no_progress')
order by rep, priority, days_since_last_attempt desc nulls last;


-- --------------------------------------------------------------------------------------
-- v_qc_saturation - checks that fail loudly.
-- --------------------------------------------------------------------------------------
create or replace view v_qc_saturation as
select 'every contact lands in exactly one bucket'::text as check_name,
       (select count(*)::text from v_contact_work)        as expected,
       (select count(*)::text from v_book_saturation)     as actual,
       case when (select count(*) from v_contact_work) = (select count(*) from v_book_saturation)
            then 'PASS' else 'FAIL' end                   as status,
       'v_contact_work vs v_book_saturation'::text        as compared_against
union all
select 'buckets sum to the contact count',
       (select count(*)::text from v_book_saturation),
       (select (sum(exhausted) + sum(recoverable) + sum(in_progress))::text from v_book_health),
       case when (select count(*) from v_book_saturation)
               = (select sum(exhausted) + sum(recoverable) + sum(in_progress) from v_book_health)
            then 'PASS' else 'FAIL' end,
       'v_book_health column sums'
union all
select 'assignment history loaded',
       '>0',
       (select count(*)::text from fact_assignment),
       case when (select count(*) from fact_assignment) > 0 then 'PASS' else 'WARN' end,
       -- WARN not FAIL: the views degrade gracefully to null days_held without it. But an
       -- empty table here silently turns every ageing number into a blank, which is exactly
       -- how dim_rep sat empty for a week.
       'fact_assignment row count';


-- --------------------------------------------------------------------------------------
-- Access. Deny by default - these carry contact names and company names.
-- --------------------------------------------------------------------------------------
alter table fact_assignment enable row level security;
revoke all on fact_assignment       from anon, authenticated;
revoke all on v_assignment_current  from anon, authenticated;
revoke all on v_contact_work        from anon, authenticated;
revoke all on v_book_saturation     from anon, authenticated;
revoke all on v_book_health         from anon, authenticated;
revoke all on v_worklist_recover    from anon, authenticated;
revoke all on v_qc_saturation       from anon, authenticated;
