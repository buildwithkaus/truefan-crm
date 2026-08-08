-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 005: fix the rep-name fallback (2026-08-08)
--
-- THE BUG. v_call_enriched did:
--     coalesce(ct.owner_name, '<unenriched>') as contact_owner_name
-- and every downstream view then did:
--     coalesce(e.contact_owner_name, e.actor_name)
--
-- The placeholder defeated its own fallback. coalesce stops at the first NON-NULL value,
-- and '<unenriched>' is not null, so actor_name was never reached - even though the call
-- record itself carries the rep's name in the note blob ("Caller{=}Abhishek Tripathi").
--
-- Result: 980 real calls all collapsed onto a single row labelled '<unenriched>', making
-- the dashboard look completely broken when in fact the data was fine and the rep name was
-- sitting right there in the row.
--
-- Fix: leave contact_owner_name NULL when the contact has not been enriched, so the
-- fallback chain actually falls through. A substituted placeholder is only safe at the
-- LAST position in a coalesce.
--
-- Note the two names mean different things and are deliberately not merged in the base
-- view: owner_name is who the lead belongs to, actor_name is who dialled. Attribution
-- prefers the owner and falls back to the dialler only so a report is legible before
-- enrichment catches up.
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
    ct.owner_name                                                as contact_owner_name,
    (c.actor_owner_id is not null and c.actor_owner_id = ct.owner_id) as is_owner_call,

    ct.company_name,
    ct.full_name        as contact_name,
    ct.phone,
    ct.source,
    ct.contact_stage    as stage_now,
    coalesce(nullif(btrim(ct.call_disposition), ''), '<blank>')  as call_disposition,
    ct.disqualification_reason,

    -- Stage at the moment of the call. '<unenriched>' rather than '<unknown>' when the
    -- contact simply has not been fetched yet: the two are different problems, and a tab
    -- full of '<unenriched>' should point at the enrichment job rather than at the data.
    coalesce(prev.current_stage, ct.contact_stage,
             case when ct.prospect_id is null then '<unenriched>' else '<unknown>' end)
                                                                 as stage_at_call,
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

left join lateral (
    select s.activity_id, s.current_stage
    from fact_stage_change s
    where s.prospect_id = c.prospect_id
      and s.changed_at_utc >= c.called_at_utc
      and s.changed_at_utc <  c.called_at_utc + interval '7 days'
    order by s.changed_at_utc asc
    limit 1
) nxt on true;


-- Downstream views end their coalesce chains with a literal, which is the only safe place
-- for one. Re-created here so the whole chain is consistent in a single migration.
create or replace view v_contact_day as
with day_calls as (
    select
        e.prospect_id,
        e.call_date_ist,
        coalesce(e.contact_owner_name, e.actor_name, '<unknown>') as rep,
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


create or replace view v_daily_totals as
select
    call_date_ist                                as report_date,
    count(*) filter (where direction = 'outbound')                 as dials,
    count(*) filter (where direction = 'outbound' and connected)   as connects,
    count(distinct prospect_id)                                    as contacts,
    count(distinct coalesce(contact_owner_name, actor_name, '<unknown>')) as active_reps,
    round(sum(duration_sec) / 60.0, 0)                             as talk_min,
    round(100.0 * count(*) filter (where direction='outbound' and connected)
          / nullif(count(*) filter (where direction='outbound'),0), 1) as connect_rate_pct
from v_call_enriched
group by 1;


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
        coalesce(e.contact_owner_name, e.actor_name, '<unknown>') as rep,
        e.stage_at_call                                           as contact_stage,
        case
            when e.call_date_ist < (select from_date from cutover) then '<no history>'
            else e.call_disposition
        end                                                       as disposition,
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
    (disposition not in ('<no history>', '<blank>')
     and not exists (select 1 from ref_canonical_value v
                     where v.field = 'call_disposition' and v.value = disposition))
                                        as disposition_not_selectable
from base
group by 1, 2, 3, 4;
