-- =====================================================================================
-- TrueFan CRM - 015: all channels, one touch grain (2026-08-10)
--
-- The calling pipeline reads six EventCodes and the live webhook path stores three. The
-- account has 58 configured activity types. A 450-lead sample found 1,565 WhatsApp events
-- (codes 201 + 3011) against 2,059 outbound calls - WhatsApp is the second-largest touch
-- channel here and is invisible to every report built so far.
--
-- THREE DESIGN DECISIONS, each one load-bearing:
--
-- 1. fact_call IS NOT TOUCHED. It is live, bound to Excel and Sheets, and reconciles
--    exactly against an independent recount. fact_touch holds every NON-call channel and
--    v_touch_all unions the two. Nothing that works today can break because of this file.
--
-- 2. CLASSIFICATION IS A JOIN, NOT A COLUMN. fact_touch stores only what the activity
--    record actually said (event_code, event_name, timestamps, actor, status). Which
--    channel that represents comes from ref_channel at query time. Re-classifying a channel
--    is then an UPDATE to one reference row rather than a re-ingest - and re-ingest is not
--    cheap here, because there is no bulk activity read and every row costs an API call.
--
-- 3. AN UNKNOWN CODE BECOMES A VISIBLE ROW, NEVER A DROPPED ONE. The join is a LEFT JOIN
--    coalescing to 'unmapped', and QC counts it. Every expensive failure in this repo has
--    been silence read as zero: 20,076 leads skipped on a guessed string, 1,089 ghost deal
--    rows, dim_rep empty for a week. A channel nobody has classified yet must show up as
--    work to do, not as an absence.
--
-- The (event_code, event_name) composite key is not defensive over-engineering: EventCode
-- 3011 appears in live trails as BOTH "WhatsApp Message" and "Opportunity".
-- =====================================================================================


-- --------------------------------------------------------------------------------------
-- ref_channel - the map, as DATA. Same pattern as ref_canonical_value: extending the
-- taxonomy is an INSERT, not a migration.
--
--   channel       phone | whatsapp | email | chat | meeting | web | form | system |
--                 deal | payment | ai_call | unmapped
--   actor_kind    rep | system | integration | ai | unknown
--   is_touch      does this count as outreach WE performed? A stage change does not. Nor
--                 does an email open - that is the prospect reacting, which is is_engagement.
--   is_engagement does this evidence a two-way interaction?
--
-- NOTE on 203 and 209: both are marked is_touch = false on purpose. They ANNOTATE a call
-- (outcome, disposition, notes); the telephony log already carries the dial. Counting them
-- as touches would double-count exactly the reps who bother to fill the form in, making
-- discipline look like volume.
-- --------------------------------------------------------------------------------------
create table if not exists ref_channel (
    event_code    text    not null,
    event_name    text    not null,
    channel       text    not null,
    direction     text    not null default '',
    actor_kind    text    not null default 'unknown',
    is_touch      boolean not null default false,
    is_engagement boolean not null default false,
    is_active     boolean not null default true,
    notes         text,
    primary key (event_code, event_name)
);

comment on table ref_channel is
    'EventCode+EventName -> channel taxonomy. Seeded from a live census, not from docs. '
    'EventCode 3011 is deliberately two rows: it is both WhatsApp Message and Opportunity.';

-- --------------------------------------------------------------------------------------
-- Seed. NOT hand-written: generated from scripts/pipeline/09-activity-census.ps1 run over
-- all 91,033 leads plus two 300-lead trail samples on 2026-08-10. Every event_name below is
-- the string the live activity trail actually returns.
--
-- This table is seeded IN THE MIGRATION rather than by a later job on purpose. dim_rep was
-- created empty in migration 001 and stayed empty for a week because the filling was left
-- to "later"; the only symptom was a raw GUID appearing where a rep name belonged. Anything
-- created empty needs its filling wired into something that already runs - or, as here,
-- into the create itself.
--
-- Note the trail name and the catalogue name are NOT always identical: the ActivityTypes
-- catalogue calls 97 "Dynamic Form - Submission" while the trail returns "Dynamic Form
-- Submission". The trail spelling wins, because that is what fact_touch stores. If the
-- webhook payload's ActivityEventName turns out to use the other spelling, those rows land
-- in v_channel_unmapped - visibly - rather than being dropped.
-- --------------------------------------------------------------------------------------
insert into ref_channel (event_code, event_name, channel, direction, actor_kind, is_touch, is_engagement) values
    -- Observed live, in descending order of volume.
    ('21', 'Inbound Phone Call Activity', 'phone', 'inbound', 'rep', true, true),
    ('22', 'Outbound Phone Call Activity', 'phone', 'outbound', 'rep', true, true),
    ('23', 'Lead Capture', 'system', '', 'system', false, false),
    ('33', 'Opportunity Captured', 'deal', '', 'system', false, false),
    ('97', 'Dynamic Form Submission', 'form', 'inbound', 'integration', false, true),
    -- WhatsApp: 60% of contacts carry one, and it has exactly ONE actor across 600 sampled
    -- leads. It is a broadcast/integration channel, not per-rep outreach - which is why
    -- actor_kind is 'integration' and why no rep scorecard should credit it as their work.
    ('201', 'WhatsApp Message', 'whatsapp', 'outbound', 'integration', true, true),
    ('202', 'Facebook Lead Ads Submissions', 'form', 'inbound', 'integration', false, true),
    ('203', '01. Phone Call/ Follow Up', 'phone', 'outbound', 'rep', false, true),
    ('205', '04. Sales Activity', 'payment', '', 'rep', false, false),
    ('208', 'AI Phone Call / Follow Up', 'ai_call', 'outbound', 'ai', false, false),
    ('3001', 'LeadAssigned', 'system', '', 'system', false, false),
    ('3002', 'StageChange', 'system', '', 'system', false, false),
    ('3004', 'SourceChange', 'system', '', 'system', false, false),
    ('3006', 'LeadAssociated', 'system', '', 'system', false, false),
    -- The one collision in the account. Same code, two meanings, opposite handling.
    ('3011', 'Opportunity', 'deal', '', 'system', false, false),
    ('3011', 'WhatsApp Message', 'whatsapp', 'outbound', 'integration', true, true),
    ('12000', 'Opportunity', 'deal', '', 'rep', false, false),

    -- Configured on the account but carrying no traffic yet. Classified in advance so that
    -- the day one of them fires, it is already a channel rather than an unmapped row.
    -- 209 especially: created 2026-08-06, zero use so far, and it is the only place in this
    -- CRM that can hold per-call disposition history AND a rep note.
    ('209', 'Call Disposition', 'phone', 'outbound', 'rep', false, true),
    ('207', 'Converse Chat', 'chat', 'inbound', 'integration', true, true),
    ('200', 'Zoom Meeting', 'meeting', 'outbound', 'rep', true, true),
    ('102', 'Meeting', 'meeting', 'outbound', 'rep', true, true),
    ('103', 'Had a Phone Conversation', 'phone', 'outbound', 'rep', true, true),
    ('104', 'Left a Voice Mail', 'phone', 'outbound', 'rep', true, false),
    ('105', 'Spoke with Gatekeeper', 'phone', 'outbound', 'rep', true, false),
    ('204', '02. Contract', 'deal', 'outbound', 'rep', true, true),
    ('206', '03. Payment', 'payment', '', 'rep', false, false)
on conflict (event_code, event_name) do nothing;


-- --------------------------------------------------------------------------------------
-- fact_touch - one row per NON-call activity, any channel.
--
-- Grain and PK identical to fact_call: the LSQ activity id, so every ingest path (webhook,
-- backfill, reconcile) converges on the same row and exactly-once is a property of the
-- schema rather than of the caller.
--
-- direction_raw exists because some channels carry their own direction per record - a 201
-- WhatsApp Message holds Inbound|Outbound in mx_Custom_2 - and that beats any default the
-- reference table could supply. Stored raw (not normalised) so the CASE that interprets it
-- lives in one view instead of being burned into the data.
--
-- attrs holds the per-channel extras that do not deserve a column each: WhatsApp delivery
-- status, Converse Chat response times, contract/payment amounts. jsonb rather than more
-- columns because the channel set will keep growing and an ALTER per channel would make
-- adding one a migration instead of an INSERT.
-- --------------------------------------------------------------------------------------
create table if not exists fact_touch (
    activity_id     text primary key,
    prospect_id     text not null,
    event_code      text not null,
    event_name      text not null,

    touched_at_utc  timestamptz not null,
    touched_at_ist  timestamp generated always as
                        ((touched_at_utc at time zone 'UTC') + interval '5 hours 30 minutes') stored,
    touch_date_ist  date generated always as
                        (((touched_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date) stored,

    actor_owner_id  text,
    actor_name      text,
    status          text,
    direction_raw   text,
    duration_sec    integer,
    note            text,
    attrs           jsonb not null default '{}'::jsonb,

    ingest_source   text not null default 'webhook'
                        check (ingest_source in ('webhook','backfill','reconcile')),
    ingested_at     timestamptz not null default now(),

    -- Calls belong in fact_call. Enforced rather than documented, because the failure mode
    -- is silent double counting in every cross-channel total.
    constraint fact_touch_not_a_call check (event_code not in ('21','22'))
);

create index if not exists idx_touch_date_actor on fact_touch (touch_date_ist, actor_owner_id);
create index if not exists idx_touch_prospect   on fact_touch (prospect_id, touched_at_utc desc);
create index if not exists idx_touch_code       on fact_touch (event_code, event_name);


-- --------------------------------------------------------------------------------------
-- v_touch_all - THE cross-channel grain. fact_call projected into the channel shape, union
-- fact_touch classified through ref_channel.
--
-- The two halves are unioned rather than fact_call being migrated into fact_touch, because
-- fact_call is live and reconciling and there is no reason to put that at risk. The
-- fact_touch_not_a_call constraint above is what makes the union safe.
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
    -- 208 (Callkaro) never enters fact_call, so everything here is a human dial.
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
    -- A per-record direction beats the reference default: WhatsApp carries its own.
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
    -- "Connected" has no meaning off the phone; null keeps it out of averages instead of
    -- contributing a false zero.
    null::boolean                                             as connected,
    t.note,
    'fact_touch'::text                                        as source_table
from fact_touch t
left join ref_channel rc
       on rc.event_code = t.event_code
      and rc.event_name = t.event_name;


-- --------------------------------------------------------------------------------------
-- v_channel_day - the headline channel report: what happened, on which channel, by whom.
--
-- Counts only is_touch rows. System events (LeadAssigned, StageChange) and prospect-side
-- reactions (email opens) are real and stored, but they are not outreach and would swamp
-- the numbers - 3001 alone was 968 events in a 450-lead sample.
-- --------------------------------------------------------------------------------------
create or replace view v_channel_day as
select
    t.touch_date_ist                              as report_date,
    t.channel,
    coalesce(r.lsq_name, ct.owner_name, t.actor_name, '<unknown>') as rep,
    t.actor_kind,
    count(*)                                      as touches,
    count(*) filter (where t.direction = 'outbound') as outbound,
    count(*) filter (where t.direction = 'inbound')  as inbound,
    count(distinct t.prospect_id)                 as contacts,
    count(*) filter (where t.connected)            as connects,
    sum(coalesce(t.duration_sec, 0))              as total_seconds
from v_touch_all t
left join dim_contact ct on ct.prospect_id = t.prospect_id
left join dim_rep r      on r.owner_id     = t.actor_owner_id
where t.is_touch
group by 1, 2, 3, 4;


-- --------------------------------------------------------------------------------------
-- v_channel_mix_rep - which channels each rep actually uses.
--
-- The point of the whole exercise: reps were told they have channel flexibility. This says
-- whether any of them took it, or whether outreach is still 100% phone.
-- --------------------------------------------------------------------------------------
create or replace view v_channel_mix_rep as
with per_rep as (
    select rep, channel, sum(touches) as touches, sum(contacts) as contacts
    from v_channel_day
    group by 1, 2
)
select
    rep,
    channel,
    touches,
    contacts,
    round(100.0 * touches / nullif(sum(touches) over (partition by rep), 0), 1) as pct_of_rep_touches,
    sum(touches) over (partition by rep)                                        as rep_total_touches
from per_rep
order by rep, touches desc;


-- --------------------------------------------------------------------------------------
-- v_contact_touch_pattern - per contact, the whole multi-channel history in one row.
--
-- This is what makes "which combination of channels converts" answerable at all: a funnel
-- cut by channel needs to know a contact was worked on two channels, not that two separate
-- events happened.
-- --------------------------------------------------------------------------------------
create or replace view v_contact_touch_pattern as
select
    t.prospect_id,
    count(*)                                                  as touches,
    count(distinct t.channel)                                 as channels_used,
    string_agg(distinct t.channel, ',' order by t.channel)    as channel_set,
    min(t.touched_at_utc)                                     as first_touch_at,
    max(t.touched_at_utc)                                     as last_touch_at,
    count(*) filter (where t.channel = 'phone')               as phone_touches,
    count(*) filter (where t.channel = 'whatsapp')            as whatsapp_touches,
    count(*) filter (where t.channel = 'email')               as email_touches,
    count(*) filter (where t.channel = 'meeting')             as meeting_touches,
    count(*) filter (where t.direction = 'inbound')           as inbound_touches,
    -- A reply of any kind on any channel. The cheapest single proxy for "this account is
    -- actually engaging", and the thing a phone-only view cannot see at all.
    (count(*) filter (where t.direction = 'inbound') > 0)     as ever_replied
from v_touch_all t
where t.is_touch
group by 1;


-- --------------------------------------------------------------------------------------
-- v_channel_unmapped - QC. Activity types arriving that nobody has classified.
--
-- Deliberately its own view rather than a line on a dashboard: this is a worklist, and it
-- should be empty. A non-empty result means a channel is being recorded and silently
-- excluded from every channel number in the workbook.
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
left join ref_channel rc
       on rc.event_code = t.event_code
      and rc.event_name = t.event_name
where rc.event_code is null
group by 1, 2
order by touches desc;


-- --------------------------------------------------------------------------------------
-- v_qc_channel - checks that FAIL loudly, each measured against something that does not
-- share its arithmetic (the same rule the existing QC tab follows).
-- --------------------------------------------------------------------------------------
create or replace view v_qc_channel as
select 'phone totals agree between fact_call and v_touch_all'::text as check_name,
       (select count(*)::text from fact_call)                        as expected,
       (select count(*)::text from v_touch_all where channel = 'phone') as actual,
       case when (select count(*) from fact_call)
               = (select count(*) from v_touch_all where channel = 'phone')
            then 'PASS' else 'FAIL' end                              as status,
       'fact_call vs v_touch_all'::text                              as compared_against
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
       -- dim_rep was created empty in migration 001 and stayed empty for a week because
       -- nothing ever checked. This is that check, for this table.
       'ref_channel row count';


-- --------------------------------------------------------------------------------------
-- Access. Deny by default, service_role only - fact_touch carries note text and, for chat,
-- lead phone numbers in attrs.
-- --------------------------------------------------------------------------------------
alter table fact_touch  enable row level security;
alter table ref_channel enable row level security;
revoke all on fact_touch  from anon, authenticated;
revoke all on ref_channel from anon, authenticated;
revoke all on v_touch_all             from anon, authenticated;
revoke all on v_channel_day           from anon, authenticated;
revoke all on v_channel_mix_rep       from anon, authenticated;
revoke all on v_contact_touch_pattern from anon, authenticated;
revoke all on v_channel_unmapped      from anon, authenticated;
revoke all on v_qc_channel            from anon, authenticated;
