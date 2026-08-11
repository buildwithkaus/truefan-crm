-- =====================================================================================
-- TrueFan CRM - 017: two corrections the channel QC caught within an hour of going live
-- (2026-08-10)
--
-- Both were found by the checks themselves rather than by a person noticing a wrong number,
-- which is the whole argument for having them.
--
-- 1. THE QC CHECK WAS WRONG, NOT THE DATA. "phone totals agree between fact_call and
--    v_touch_all" compared fact_call's row count against `channel = 'phone'`. But channel
--    'phone' legitimately includes more than the telephony log: EventCodes 203, 209, 103,
--    104 and 105 are phone-channel records that live in fact_touch. The first real 209
--    "Call Disposition" activity arrived at 13:14 UTC and the check went FAIL, off by
--    exactly one, reporting a defect that did not exist.
--
--    A check that fails on correct data is worse than no check: it trains everyone to
--    ignore the QC tab. The comparison that actually guards against the union losing or
--    duplicating rows is source_table, so that is what it now compares.
--
-- 2. AN EMPTY EventEventName MADE A KNOWN CODE LOOK UNKNOWN. Opportunity webhook payloads
--    (events 29/30) carry ActivityEvent=12000 with NO ActivityEventName and no fields, so
--    the (event_code, event_name) lookup missed and they surfaced as 'unmapped'. The
--    composite key is still right - EventCode 3011 is genuinely two activities - but it
--    needs a code-level fallback for payloads that omit the name.
-- =====================================================================================


-- --------------------------------------------------------------------------------------
-- Code-level default rows. event_name = '' means "any activity with this code whose name
-- we were not told". The lateral join below prefers an exact name match and only falls back
-- to these, so 3011's two meanings are unaffected.
-- --------------------------------------------------------------------------------------
insert into ref_channel (event_code, event_name, channel, direction, actor_kind, is_touch, is_engagement, notes) values
    ('12000', '', 'deal', '', 'rep', false, false,
     'code-level default: opportunity webhook payloads carry no ActivityEventName'),
    ('33',    '', 'deal', '', 'system', false, false,
     'code-level default'),
    ('201',   '', 'whatsapp', 'outbound', 'integration', true, true,
     'code-level default'),
    ('209',   '', 'phone', 'outbound', 'rep', false, true,
     'code-level default')
on conflict (event_code, event_name) do nothing;


-- --------------------------------------------------------------------------------------
-- 3. EventCode 3011 is a MIRROR, not an activity.
--
-- Proven live 2026-08-10 while loading trails: a 3011|WhatsApp Message carries the SAME
-- top-level Id as the 201|WhatsApp Message it shadows, and a 3011|Opportunity the same Id
-- as its 12000. It is a second view of one record under a different code.
--
-- This corrects a number reported earlier the same day. The census counted 201 and 3011
-- separately and put WhatsApp at "1,565 events", which DOUBLE COUNTS. The honest figure is
-- the 201 count alone. Contact coverage (~60% of contacts carry WhatsApp) is unaffected,
-- because that was measured on distinct leads.
--
-- Marked inactive rather than deleted so the mapping stays visible and the next person does
-- not rediscover it. Nothing writes 3011 any more: the loader skips it, and the webhook API
-- refuses to subscribe to 3xxx codes at all.
-- --------------------------------------------------------------------------------------
update ref_channel
   set is_active = false,
       is_touch = false,
       is_engagement = false,
       notes = 'MIRROR of the primary code - shares its activity Id with 201 / 12000. '
               || 'Never store: it double counts and collides on the primary key.'
 where event_code = '3011';


-- --------------------------------------------------------------------------------------
-- v_touch_all - same as 015 except the ref_channel lookup now prefers an exact
-- (code, name) match and falls back to the code-level default row.
-- --------------------------------------------------------------------------------------
create or replace view v_touch_all as
select
    c.activity_id,
    c.prospect_id,
    c.event_code,
    case when c.event_code = '22' then 'Outbound Phone Call Activity'
         else 'Inbound Phone Call Activity' end               as event_name,
    'phone'::text                                             as channel,
    c.direction,
    'rep'::text                                               as actor_kind,
    true                                                      as is_touch,
    true                                                      as is_engagement,
    c.called_at_utc                                           as touched_at_utc,
    c.called_at_ist                                           as touched_at_ist,
    c.call_date_ist                                           as touch_date_ist,
    c.actor_owner_id,
    c.actor_name,
    c.status,
    c.duration_sec,
    c.connected,
    c.call_note                                               as note,
    'fact_call'::text                                         as source_table
from fact_call c

union all

select
    t.activity_id,
    t.prospect_id,
    t.event_code,
    t.event_name,
    coalesce(rc.channel, 'unmapped')                          as channel,
    lower(coalesce(nullif(btrim(t.direction_raw), ''), rc.direction, ''))
                                                              as direction,
    coalesce(rc.actor_kind, 'unknown')                        as actor_kind,
    coalesce(rc.is_touch, false)                              as is_touch,
    coalesce(rc.is_engagement, false)                         as is_engagement,
    t.touched_at_utc,
    t.touched_at_ist,
    t.touch_date_ist,
    t.actor_owner_id,
    t.actor_name,
    t.status,
    t.duration_sec,
    null::boolean                                             as connected,
    t.note,
    'fact_touch'::text                                        as source_table
from fact_touch t
left join lateral (
    -- Exact name match wins; a code-level default (event_name = '') is the fallback. The
    -- ORDER BY is what encodes that preference - without it the choice between the two rows
    -- would be arbitrary and could change between runs.
    select rc2.channel, rc2.direction, rc2.actor_kind, rc2.is_touch, rc2.is_engagement
    from ref_channel rc2
    where rc2.event_code = t.event_code
      and (rc2.event_name = t.event_name or rc2.event_name = '')
    order by (rc2.event_name = t.event_name) desc
    limit 1
) rc on true;


-- --------------------------------------------------------------------------------------
-- v_channel_unmapped - same fallback, so a code with a default no longer reports as unmapped.
-- --------------------------------------------------------------------------------------
create or replace view v_channel_unmapped as
select
    t.event_code,
    t.event_name,
    count(*)                      as touches,
    count(distinct t.prospect_id) as contacts,
    min(t.touched_at_utc)         as first_seen,
    max(t.touched_at_utc)         as last_seen
from fact_touch t
where not exists (
    select 1 from ref_channel rc
    where rc.event_code = t.event_code
      and (rc.event_name = t.event_name or rc.event_name = '')
)
group by 1, 2
order by touches desc;


-- --------------------------------------------------------------------------------------
-- v_qc_channel - check 1 now compares source_table, which is the thing that can actually
-- go wrong (the union dropping or duplicating rows). Checks 2-4 are unchanged.
-- --------------------------------------------------------------------------------------
create or replace view v_qc_channel as
select 'every fact_call row appears exactly once in v_touch_all'::text as check_name,
       (select count(*)::text from fact_call)                          as expected,
       (select count(*)::text from v_touch_all where source_table = 'fact_call') as actual,
       case when (select count(*) from fact_call)
               = (select count(*) from v_touch_all where source_table = 'fact_call')
            then 'PASS' else 'FAIL' end                                as status,
       'fact_call vs v_touch_all union arm'::text                      as compared_against
union all
select 'every fact_touch row appears exactly once in v_touch_all',
       (select count(*)::text from fact_touch),
       (select count(*)::text from v_touch_all where source_table = 'fact_touch'),
       case when (select count(*) from fact_touch)
               = (select count(*) from v_touch_all where source_table = 'fact_touch')
            then 'PASS' else 'FAIL' end,
       -- Guards the lateral join: if it ever returned more than one ref_channel row per
       -- touch, this fans out and the count rises. limit 1 is what prevents that.
       'fact_touch vs v_touch_all union arm'
union all
select 'no call rows leaked into fact_touch',
       '0',
       (select count(*)::text from fact_touch where event_code in ('21','22')),
       case when (select count(*) from fact_touch where event_code in ('21','22')) = 0
            then 'PASS' else 'FAIL' end,
       'fact_touch check constraint'
union all
select 'every stored event type is classified',
       '0',
       (select coalesce(sum(touches), 0)::text from v_channel_unmapped),
       case when (select coalesce(sum(touches), 0) from v_channel_unmapped) = 0
            then 'PASS' else 'WARN' end,
       'fact_touch left join ref_channel'
union all
select 'ref_channel is populated',
       '>0',
       (select count(*)::text from ref_channel),
       case when (select count(*) from ref_channel) > 0 then 'PASS' else 'FAIL' end,
       'ref_channel row count';

revoke all on v_touch_all        from anon, authenticated;
revoke all on v_channel_unmapped from anon, authenticated;
revoke all on v_qc_channel       from anon, authenticated;
