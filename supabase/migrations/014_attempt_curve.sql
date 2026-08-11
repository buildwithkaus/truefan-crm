-- =====================================================================================
-- TrueFan CRM - 014: the attempt-depth curve (2026-08-10)
--
-- WHAT THIS ANSWERS. Reps ask for fresh leads. Nothing in this system has ever been able
-- to say whether the leads they already hold are worked out. This migration answers that
-- from data already in fact_call - no new ingest, no new API call, no new field.
--
-- The load-bearing question is not "how many calls did a rep make" but:
--
--     Given a contact we have already dialled N times without reaching anyone,
--     is the N+1th dial worth making?
--
-- That is a hazard rate, not an average, and it is computable today. If the 4th dial still
-- reaches a human at a useful rate while reps stop at 1.8 dials, the recoverable pool is a
-- number of contacts rather than an opinion - which is exactly the shape of the standing
-- "Did Not Pick on contacts that demonstrably connected" problem in memory/11.
--
-- TWO BIASES ARE HANDLED EXPLICITLY, because both would otherwise flatter the numbers:
--
-- 1. LEFT TRUNCATION. fact_call starts around 2026-08-01. A contact dialled five times in
--    July and twice in August looks like a 2-attempt contact, so every ordinal is wrong and
--    the curve reads far too optimistic at high N. Handled by restricting the headline curve
--    to contacts whose stage immediately BEFORE their first observed call was 'Fresh' -
--    which since the 2026-07-31 redefinition means "nobody had dialled this yet", so
--    attempt 1 genuinely is attempt 1. v_attempt_curve_all keeps the unrestricted version
--    beside it, labelled.
--
-- 2. SURVIVOR SELECTION. Contacts that connect early stop being dialled, so high ordinals
--    are dominated by hard-to-reach numbers. That is not a defect to correct - it is the
--    thing being measured - but it does mean the denominator must be "contacts still
--    unreached entering attempt N", never "all contacts". That is what at_risk_contacts is.
--
-- Every rate is suppressed below n=30 rather than printed. A 12% connect rate on 8 contacts
-- is not a finding, and this repo has enough history of confident numbers built on thin
-- cells (memory/12: "78% of prospects have no opportunity" was one step from being reported).
-- =====================================================================================


-- --------------------------------------------------------------------------------------
-- Which dispositions ASSERT that nobody was reached. Kept as a function rather than a
-- literal in each view so the three cannot drift apart - the same reason call_rep() exists.
-- Mirrors NO_CONTACT_DISPOSITIONS in supabase/functions/_shared/schema.ts.
-- --------------------------------------------------------------------------------------
create or replace function disposition_asserts_no_contact(d text)
returns boolean language sql immutable as $$
    select coalesce(btrim(d), '') in
        ('Did Not Pick', 'RNR', 'Switched Off/Not Reachable', 'Reached Voicemail');
$$;


-- --------------------------------------------------------------------------------------
-- v_call_attempt - the base grain: every outbound dial with its attempt ordinal for that
-- contact, plus whether that ordinal can be trusted.
--
-- Tie-break on activity_id: two calls can share a timestamp, and row_number() without a
-- deterministic tie-break would reshuffle them between runs, making the curve unstable.
-- --------------------------------------------------------------------------------------
create or replace view v_call_attempt as
with ordered as (
    select
        c.activity_id,
        c.prospect_id,
        c.called_at_utc,
        c.called_at_ist,
        c.call_date_ist,
        c.actor_owner_id,
        c.status,
        c.duration_sec,
        c.connected,
        row_number() over (partition by c.prospect_id
                           order by c.called_at_utc, c.activity_id) as attempt_no
    from fact_call c
    where c.direction = 'outbound'
),
first_call as (
    select prospect_id, min(called_at_utc) as first_call_at
    from ordered
    group by 1
),
-- The stage the contact held immediately before its FIRST observed dial. 'Fresh' means
-- nobody had dialled it, so the ordinals below are not left-truncated. Anything else (or
-- no stage history at all) means we cannot know how many dials preceded our window.
opening as (
    select f.prospect_id, s.current_stage as stage_before_first_call
    from first_call f
    left join lateral (
        select sc.current_stage
        from fact_stage_change sc
        where sc.prospect_id = f.prospect_id
          and sc.changed_at_utc <= f.first_call_at
        order by sc.changed_at_utc desc
        limit 1
    ) s on true
),
first_connect as (
    select prospect_id, min(attempt_no) as first_connect_no
    from ordered
    where connected
    group by 1
)
select
    o.activity_id,
    o.prospect_id,
    o.called_at_utc,
    o.called_at_ist,
    o.call_date_ist,
    o.actor_owner_id,
    o.status,
    o.duration_sec,
    o.connected,
    o.attempt_no,
    op.stage_before_first_call,
    (op.stage_before_first_call = 'Fresh')      as ordinals_are_true,
    fc.first_connect_no
from ordered o
join opening op       on op.prospect_id = o.prospect_id
left join first_connect fc on fc.prospect_id = o.prospect_id;


-- --------------------------------------------------------------------------------------
-- v_attempt_curve - THE headline. Marginal value of the Nth dial.
--
--   at_risk_contacts   contacts that made attempt N having NOT connected on 1..N-1
--   first_connects     of those, how many connected on exactly attempt N
--   marginal_connect_pct  the hazard rate: "I have missed N-1 times; is dial N worth it?"
--
-- Restricted to contacts whose ordinals are trustworthy. Read v_attempt_curve_all beside
-- it: if the two disagree sharply at high N, the difference IS the left-truncation.
-- --------------------------------------------------------------------------------------
create or replace view v_attempt_curve as
with base as (
    select * from v_call_attempt where ordinals_are_true
),
agg as (
    select
        attempt_no,
        count(*) filter (where first_connect_no is null
                            or first_connect_no >= attempt_no) as at_risk_contacts,
        count(*) filter (where first_connect_no = attempt_no)   as first_connects,
        count(*)                                                as contacts_reaching
    from base
    group by attempt_no
)
select
    attempt_no,
    contacts_reaching,
    at_risk_contacts,
    first_connects,
    case when at_risk_contacts >= 30
         then round(100.0 * first_connects / nullif(at_risk_contacts, 0), 1)
    end                                                          as marginal_connect_pct,
    case when at_risk_contacts < 30 then 'n<30' end               as suppressed,
    -- Cumulative share of the cohort reached by attempt N. The "how much more reach does
    -- one more dial buy" number a manager actually acts on.
    round(100.0 * sum(first_connects) over (order by attempt_no)
          / nullif((select count(distinct prospect_id) from base), 0), 1)
                                                                 as cum_reach_pct
from agg
order by attempt_no;


-- --------------------------------------------------------------------------------------
-- v_attempt_curve_all - the same curve over EVERY contact, including those whose history
-- predates fact_call. Left-truncated on purpose and labelled so, because excluding them
-- entirely would hide the reps who work older books.
-- --------------------------------------------------------------------------------------
create or replace view v_attempt_curve_all as
with agg as (
    select
        attempt_no,
        count(*) filter (where first_connect_no is null
                            or first_connect_no >= attempt_no) as at_risk_contacts,
        count(*) filter (where first_connect_no = attempt_no)   as first_connects
    from v_call_attempt
    group by attempt_no
)
select
    attempt_no,
    at_risk_contacts,
    first_connects,
    case when at_risk_contacts >= 30
         then round(100.0 * first_connects / nullif(at_risk_contacts, 0), 1)
    end                                            as marginal_connect_pct,
    case when at_risk_contacts < 30 then 'n<30' end as suppressed,
    'left-truncated at the start of fact_call'::text as caveat
from agg
order by attempt_no;


-- --------------------------------------------------------------------------------------
-- v_attempt_depth_rep - how deep does each rep actually dial their OWN book?
--
-- Scoped to owner calls (actor = current owner). A rep who inherits a heavily-worked book
-- would otherwise show deep attempt counts they did not produce - the same inherited-work
-- distortion is_owner_call exists to stop everywhere else in this warehouse.
-- --------------------------------------------------------------------------------------
create or replace view v_attempt_depth_rep as
with owner_calls as (
    select
        coalesce(r.lsq_name, ct.owner_name, c.actor_name, '<unknown>') as rep,
        c.prospect_id,
        c.connected
    from fact_call c
    join dim_contact ct on ct.prospect_id = c.prospect_id
                       and ct.owner_id    = c.actor_owner_id
    left join dim_rep r on r.owner_id = c.actor_owner_id
    where c.direction = 'outbound'
),
per_contact as (
    select rep, prospect_id,
           count(*)                        as attempts,
           bool_or(connected)               as ever_connected
    from owner_calls
    group by 1, 2
)
select
    rep,
    count(*)                                                    as contacts_dialled,
    sum(attempts)                                               as total_attempts,
    round(avg(attempts), 2)                                     as mean_attempts,
    -- percentile_cont takes double precision; count(*) is bigint. The implicit cast exists
    -- but is spelled out so a future column-type change fails loudly instead of silently
    -- picking a different overload.
    percentile_cont(0.5) within group (order by attempts::double precision) as median_attempts,
    percentile_cont(0.9) within group (order by attempts::double precision) as p90_attempts,
    count(*) filter (where ever_connected)                      as contacts_connected,
    round(100.0 * count(*) filter (where ever_connected)
          / nullif(count(*), 0), 1)                             as reach_pct,
    -- The single most actionable number here: contacts dialled exactly once, never reached,
    -- and never tried again. Every one of these is a lead the rep asked for and abandoned.
    count(*) filter (where attempts = 1 and not ever_connected)  as one_and_done,
    round(100.0 * count(*) filter (where attempts = 1 and not ever_connected)
          / nullif(count(*), 0), 1)                             as one_and_done_pct
from per_contact
group by rep
order by contacts_dialled desc;


-- --------------------------------------------------------------------------------------
-- v_disposition_durability - does a negative disposition mean the contact is finished?
--
-- Answers the question directly: of the contacts sitting on "Did Not Pick" / "RNR" /
-- "Switched Off", how many were only ever dialled once, and how many of the ones we DID
-- keep dialling eventually answered. A high reached_later_pct against a high one_attempt_pct
-- is a recoverable pool, not a dead one.
--
-- Deliberately covers EVERY disposition, not just the negative ones, so the negative values
-- have something to be compared against.
-- --------------------------------------------------------------------------------------
create or replace view v_disposition_durability as
with per_contact as (
    select
        coalesce(nullif(btrim(ct.call_disposition), ''), '<blank>') as call_disposition,
        c.prospect_id,
        count(*)          as attempts,
        bool_or(c.connected) as ever_connected,
        max(c.called_at_utc) as last_attempt_at
    from fact_call c
    join dim_contact ct on ct.prospect_id = c.prospect_id
    where c.direction = 'outbound'
    group by 1, 2
)
select
    call_disposition,
    disposition_asserts_no_contact(call_disposition)          as asserts_no_contact,
    count(*)                                                  as contacts,
    round(avg(attempts), 2)                                   as mean_attempts,
    count(*) filter (where attempts = 1)                      as one_attempt_only,
    round(100.0 * count(*) filter (where attempts = 1)
          / nullif(count(*), 0), 1)                           as one_attempt_pct,
    count(*) filter (where ever_connected)                     as ever_connected,
    case when count(*) >= 30
         then round(100.0 * count(*) filter (where ever_connected)
                    / nullif(count(*), 0), 1)
    end                                                        as ever_connected_pct,
    case when count(*) < 30 then 'n<30' end                    as suppressed,
    -- The contradiction flag, at population level rather than per contact: a disposition
    -- that asserts nobody was reached, sitting on contacts where somebody was.
    count(*) filter (where disposition_asserts_no_contact(call_disposition)
                       and ever_connected)                     as contradicts_telephony,
    -- extract(epoch ...) is double precision and there is no round(double precision, int)
    -- in PostgreSQL, so the cast to numeric is required, not cosmetic.
    round(avg(extract(epoch from (now() - last_attempt_at)) / 86400.0)::numeric, 1)
                                                               as mean_days_since_last_attempt
from per_contact
group by 1
order by contacts desc;


-- --------------------------------------------------------------------------------------
-- v_connect_by_hour - when does dialling actually work?
--
-- Free from called_at_ist. Suppressed below 30 attempts per cell so a single lucky hour
-- cannot become a coaching instruction.
-- --------------------------------------------------------------------------------------
create or replace view v_connect_by_hour as
select
    extract(hour from called_at_ist)::int          as hour_ist,
    to_char(called_at_ist, 'Dy')                   as weekday,
    extract(isodow from called_at_ist)::int        as weekday_no,
    count(*)                                       as attempts,
    count(*) filter (where connected)              as connects,
    case when count(*) >= 30
         then round(100.0 * count(*) filter (where connected) / nullif(count(*), 0), 1)
    end                                            as connect_pct,
    case when count(*) < 30 then 'n<30' end        as suppressed,
    round(avg(duration_sec) filter (where connected), 0) as mean_talk_sec
from fact_call
where direction = 'outbound'
group by 1, 2, 3
order by weekday_no, hour_ist;


-- --------------------------------------------------------------------------------------
-- v_connect_by_hour_rollup - the same thing collapsed to hour only, which is what a
-- scorecard shows. Kept separate rather than derived in the sheet so the suppression rule
-- is applied to the cell that is actually displayed.
-- --------------------------------------------------------------------------------------
create or replace view v_connect_by_hour_rollup as
select
    extract(hour from called_at_ist)::int as hour_ist,
    count(*)                              as attempts,
    count(*) filter (where connected)     as connects,
    case when count(*) >= 30
         then round(100.0 * count(*) filter (where connected) / nullif(count(*), 0), 1)
    end                                   as connect_pct,
    case when count(*) < 30 then 'n<30' end as suppressed
from fact_call
where direction = 'outbound'
group by 1
order by 1;


-- --------------------------------------------------------------------------------------
-- Access. Same posture as everything else: deny by default, service_role only. These views
-- read fact_call, which carries phone numbers and recording URLs, so nothing is granted to
-- anon here even though the views themselves are aggregate.
-- --------------------------------------------------------------------------------------
revoke all on v_call_attempt            from anon, authenticated;
revoke all on v_attempt_curve           from anon, authenticated;
revoke all on v_attempt_curve_all       from anon, authenticated;
revoke all on v_attempt_depth_rep       from anon, authenticated;
revoke all on v_disposition_durability  from anon, authenticated;
revoke all on v_connect_by_hour         from anon, authenticated;
revoke all on v_connect_by_hour_rollup  from anon, authenticated;
