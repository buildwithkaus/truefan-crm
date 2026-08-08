-- =====================================================================================
-- TrueFan CRM - calling pipeline, analytical views
-- 002 (rewritten 2026-08-08 for the Apps-Script-ingest design)
--
-- All report logic lives here so the Sheet tabs and any future surface cannot disagree.
-- Apps Script reads these over PostgREST and paints them into tabs; it computes nothing.
--
-- Grain ladder:
--   v_call_enriched   one row per CALL, with the stage the lead was in AT THE TIME
--   v_contact_day     one row per CONTACT x DAY - did the CRM record get updated
--   v_rep_day         one row per REP x DAY - the scorecard
--   v_pivot_disposition  rep x stage x disposition - the dashboard pivot, LONG form
--   v_hygiene_exceptions one row per VIOLATION - the worklist
--   v_funnel_movement    stage transitions per day - where deals actually move
-- =====================================================================================


-- =====================================================================================
-- v_call_enriched - one row per call, with TRUE stage-at-call-time
--
-- This is the view that makes the dashboard honest. "Which stage of leads did the rep
-- call" must mean the stage the lead was in WHEN DIALLED, not the stage it is in now: a
-- lead called at 10:00 and disqualified at 16:00 belongs under whatever it was at 10:00,
-- otherwise every disqualification retro-actively rewrites the morning's activity.
--
-- Resolved from fact_stage_change, which the backfill populates from the activity trails
-- (every EventCode 3002 is in there) and the Lead Stage Change webhook maintains going
-- forward. Falls back to the contact's current stage only when no prior transition exists.
-- =====================================================================================
create or replace view v_call_enriched as
select
    c.activity_id,
    c.prospect_id,
    c.call_date_ist,
    c.called_at_ist,
    c.called_at_utc,
    c.direction,
    c.status,
    c.duration_sec,
    c.connected,
    c.call_note,
    c.ingest_source,

    c.actor_owner_id,
    coalesce(actor.lsq_name, c.actor_name, '<unknown>')          as actor_name,
    ct.owner_id                                                  as contact_owner_id,
    coalesce(ct.owner_name, '<unenriched>')                      as contact_owner_name,
    -- Credit only when the dialler is the lead's CURRENT owner. Contacts are reassigned
    -- constantly; without this a rep inherits the previous owner's entire history.
    (c.actor_owner_id is not null and c.actor_owner_id = ct.owner_id) as is_owner_call,

    ct.company_name,
    ct.full_name        as contact_name,
    ct.phone,
    ct.source,
    ct.contact_stage    as stage_now,
    coalesce(nullif(btrim(ct.call_disposition), ''), '<blank>')  as call_disposition,
    ct.disqualification_reason,

    coalesce(prev.current_stage, ct.contact_stage, '<unknown>')  as stage_at_call,
    nxt.current_stage                                            as stage_after_call,
    (nxt.activity_id is not null)                                as stage_updated_after_call

from fact_call c
left join dim_contact ct on ct.prospect_id = c.prospect_id
left join dim_rep actor  on actor.owner_id = c.actor_owner_id

left join lateral (
    select s.current_stage
    from fact_stage_change s
    where s.prospect_id = c.prospect_id
      and s.changed_at_utc <= c.called_at_utc
    order by s.changed_at_utc desc
    limit 1
) prev on true

-- First transition after the call, bounded to 7 days so a change made a month later is
-- not credited to today's dial.
left join lateral (
    select s.activity_id, s.current_stage
    from fact_stage_change s
    where s.prospect_id = c.prospect_id
      and s.changed_at_utc >= c.called_at_utc
      and s.changed_at_utc <  c.called_at_utc + interval '7 days'
    order by s.changed_at_utc asc
    limit 1
) nxt on true;


-- =====================================================================================
-- v_pivot_disposition - THE DASHBOARD PIVOT, in long form.
--
-- Rows: rep x contact stage. Columns: call disposition. Value: calls.
--
-- Deliberately emitted LONG (one row per rep/stage/disposition) rather than pre-pivoted
-- into fixed columns. Disposition values fragment on this account faster than they get
-- used correctly - "Reached Voicemail", "Requirement Gathering (Warm)", and both
-- "Call me Later" and "Call Me Later" have all appeared mid-programme - so a view with
-- hardcoded columns would silently drop every new value. Apps Script pivots this into a
-- grid at render time, so a new disposition appears as a new column automatically and
-- non-canonical ones stay visible instead of vanishing.
-- =====================================================================================
create or replace view v_pivot_disposition as
select
    e.call_date_ist,
    coalesce(e.contact_owner_name, e.actor_name)  as rep,
    e.stage_at_call                               as contact_stage,
    e.call_disposition                            as disposition,
    count(*)                                      as calls,
    count(distinct e.prospect_id)                 as contacts,
    count(*) filter (where e.connected)           as connects,
    round(sum(e.duration_sec) / 60.0, 1)          as talk_min,
    -- Flags a disposition that is stored but not selectable in the dropdown. Those records
    -- are invisible to a rep applying a UI filter, which is how 61,919 leads once became
    -- unfilterable without anyone noticing.
    (e.call_disposition <> '<blank>'
     and not exists (select 1 from ref_canonical_value v
                     where v.field = 'call_disposition' and v.value = e.call_disposition))
                                                  as disposition_not_selectable
from v_call_enriched e
where e.direction = 'outbound'
group by 1, 2, 3, 4;


-- =====================================================================================
-- v_contact_day / v_rep_day / hygiene
-- =====================================================================================
create or replace view v_contact_all_time as
select
    prospect_id,
    count(*) filter (where direction = 'outbound' and connected)     as owner_connects,
    count(*) filter (where direction = 'outbound' and not connected) as owner_no_connects
from fact_call
group by prospect_id;

create or replace view v_contact_day as
with day_calls as (
    select
        e.prospect_id,
        e.call_date_ist,
        coalesce(e.contact_owner_name, e.actor_name) as rep,
        e.contact_owner_id,
        max(e.company_name)         as company_name,
        max(e.contact_name)         as contact_name,
        max(e.phone)                as phone,
        max(e.stage_now)            as contact_stage,
        max(e.stage_at_call)        as stage_at_call,
        max(nullif(e.call_disposition, '<blank>')) as call_disposition,
        max(e.disqualification_reason)             as disqualification_reason,
        count(*) filter (where e.direction = 'outbound')                 as dials,
        count(*) filter (where e.direction = 'inbound')                  as inbound_calls,
        count(*) filter (where e.direction = 'outbound' and e.connected) as connects,
        sum(e.duration_sec)                                              as talk_time_sec,
        max(e.called_at_utc)                                             as last_call_utc,
        bool_or(e.call_note is not null and btrim(e.call_note) <> '')    as has_note,
        bool_or(e.stage_updated_after_call)                              as updated_after_call
    from v_call_enriched e
    group by e.prospect_id, e.call_date_ist, 3, e.contact_owner_id
)
select
    d.*,
    (d.contact_stage = 'Fresh')                                          as flag_called_still_fresh,
    (not d.updated_after_call)                                           as flag_no_stage_update,
    (d.connects > 0 and d.call_disposition is null)                      as flag_connected_no_disposition,
    (d.contact_stage = 'Disqualified'
        and (d.disqualification_reason is null
             or btrim(d.disqualification_reason) = ''))                  as flag_disqualified_no_reason,
    (d.call_disposition in ('Did Not Pick','RNR','Switched Off/Not Reachable')
        and coalesce(cat.owner_connects,0) > 0
        and coalesce(cat.owner_no_connects,0) = 0)                       as flag_disposition_contradicts,
    (d.call_disposition is not null
        and not exists (select 1 from ref_canonical_value v
                        where v.field = 'call_disposition' and v.value = d.call_disposition))
                                                                         as flag_non_canonical_value,
    (d.connects > 0 and not d.has_note)                                  as flag_connected_no_note
from day_calls d
left join v_contact_all_time cat on cat.prospect_id = d.prospect_id;

create or replace view v_rep_day as
select
    call_date_ist                                            as report_date,
    rep,
    sum(dials)                                               as dials,
    count(*)                                                 as contacts,
    sum(connects)                                            as connects,
    sum(inbound_calls)                                       as inbound_calls,
    round(100.0 * sum(connects) / nullif(sum(dials),0), 1)   as connect_rate_pct,
    round(sum(talk_time_sec) / 60.0, 1)                      as talk_min,
    count(*) filter (where stage_at_call = 'Fresh')          as called_fresh,
    count(*) filter (where stage_at_call = 'Engaged')        as called_engaged,
    count(*) filter (where stage_at_call = 'Prospect')       as called_prospect,
    count(*) filter (where stage_at_call = 'Customer')       as called_customer,
    count(*) filter (where stage_at_call = 'Disqualified')   as called_disqualified,
    count(*) filter (where updated_after_call)               as contacts_updated,
    round(100.0 * count(*) filter (where updated_after_call) / nullif(count(*),0), 1)
                                                             as discipline_pct,
    count(*) filter (where flag_called_still_fresh)          as gap_still_fresh,
    count(*) filter (where flag_connected_no_disposition)    as gap_no_disposition,
    count(*) filter (where flag_disqualified_no_reason)      as gap_no_reason,
    count(*) filter (where flag_disposition_contradicts)     as gap_contradicts,
    count(*) filter (where flag_non_canonical_value)         as gap_bad_value,
    round(100.0 * count(*) filter (
        where not flag_called_still_fresh
          and not flag_connected_no_disposition
          and not flag_disqualified_no_reason
          and not flag_disposition_contradicts
          and not flag_non_canonical_value
    ) / nullif(count(*),0), 1)                               as clean_pct
from v_contact_day
group by 1, 2;

create or replace view v_hygiene_exceptions as
select
    cd.call_date_ist as report_date, cd.rep, f.flag, f.severity, f.detail,
    cd.company_name, cd.contact_name, cd.phone, cd.contact_stage,
    cd.call_disposition, cd.disqualification_reason, cd.dials, cd.connects, cd.prospect_id
from v_contact_day cd
cross join lateral (values
    ('CALLED_STILL_FRESH',               1, 'Called but still at Fresh',                        cd.flag_called_still_fresh),
    ('DISQUALIFIED_NO_REASON',           1, 'Disqualified with no reason - unrecoverable',      cd.flag_disqualified_no_reason),
    ('DISPOSITION_CONTRADICTS_TELEPHONY',1, 'Says no contact, but every call connected',        cd.flag_disposition_contradicts),
    ('CONNECTED_NO_DISPOSITION',         2, 'Connected but disposition blank',                  cd.flag_connected_no_disposition),
    ('NO_STAGE_UPDATE_AFTER_CALL',       2, 'No stage change at or after the last call',        cd.flag_no_stage_update),
    ('NON_CANONICAL_VALUE',              2, 'Stored value is not a selectable dropdown option', cd.flag_non_canonical_value)
) as f(flag, severity, detail, is_set)
where f.is_set;


-- =====================================================================================
-- v_funnel_movement - where contacts actually moved, per day.
--
-- The counterpart to the activity view: calls measure effort, this measures progress.
-- Migration-era rows are excluded outright - the 2026-07-30/31 bulk write left a stage
-- change on nearly every lead in the account, so anything before 1 August is noise.
-- =====================================================================================
create or replace view v_funnel_movement as
select
    s.change_date_ist                       as report_date,
    coalesce(r.lsq_name, s.changed_by_name) as rep,
    coalesce(s.previous_stage, '<none>')    as from_stage,
    s.current_stage                         as to_stage,
    count(distinct s.prospect_id)           as contacts
from fact_stage_change s
left join dim_rep r on lower(r.lsq_name) = lower(s.changed_by_name)
where s.change_date_ist >= date '2026-08-01'
  and s.current_stage is not null
  and coalesce(s.previous_stage,'') is distinct from s.current_stage
group by 1, 2, 3, 4;


-- =====================================================================================
-- v_daily_totals - the KPI strip and the month view
-- =====================================================================================
create or replace view v_daily_totals as
select
    call_date_ist                                as report_date,
    count(*) filter (where direction = 'outbound')                 as dials,
    count(*) filter (where direction = 'outbound' and connected)   as connects,
    count(distinct prospect_id)                                    as contacts,
    count(distinct coalesce(contact_owner_name, actor_name))       as active_reps,
    round(sum(duration_sec) / 60.0, 0)                             as talk_min,
    round(100.0 * count(*) filter (where direction='outbound' and connected)
          / nullif(count(*) filter (where direction='outbound'),0), 1) as connect_rate_pct
from v_call_enriched
group by 1;


-- =====================================================================================
-- v_pipeline_health - what the Meta tab reads. A stale report must announce itself.
-- =====================================================================================
create or replace view v_pipeline_health as
select
    (select max(ingested_at)  from fact_call)                          as last_ingest_utc,
    (select max(called_at_utc) from fact_call)                         as newest_call_utc,
    (select count(*) from fact_call)                                   as calls_stored,
    (select count(*) from fact_call
      where call_date_ist = ((now() at time zone 'UTC') + interval '5 hours 30 minutes')::date)
                                                                       as calls_today,
    (select count(*) from dim_contact)                                 as contacts_cached,
    (select count(*) from fact_call c
       left join dim_contact d on d.prospect_id = c.prospect_id
      where d.prospect_id is null)                                     as calls_awaiting_enrichment,
    (select count(*) from fact_stage_change)                           as stage_changes_stored,
    (extract(epoch from (now() - coalesce((select max(ingested_at) from fact_call), now())))/60)::int
                                                                       as minutes_since_last_ingest;
