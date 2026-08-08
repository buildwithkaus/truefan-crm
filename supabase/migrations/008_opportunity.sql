-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 008: opportunities and the full contact journey (2026-08-08)
--
-- Shape confirmed live from an EventCode 12000 activity on the trail:
--   Id                        the opportunity activity id
--   RelatedProspectId         the lead it hangs off
--   ActivityFields.mx_Custom_1  opportunity name, e.g. "Mayuresh  - Opportunity"
--   ActivityFields.mx_Custom_2  DEAL STAGE, e.g. "Prospect"
--   ActivityFields.Status       Open | Won | Lost  (the native field reps see as Deal Stage)
--   ActivityFields.Owner        owner GUID
--
-- IMPORTANT LIMITATION. The trail carries the opportunity's CURRENT state, not a history of
-- its stage changes - ModifiedOn moves on any edit and LSQ emits no per-field opportunity
-- event. So deal-stage history only begins when the Opportunity Stage Update webhook
-- (event 34) is switched on; before that we know where a deal IS, not how it got there.
-- That is the same distinction as disposition history, and it is worth stating on the tab.
--
-- Opportunities attach to a LEAD, not to a Company, and only the primary contact is allowed
-- to own one - which is why a sample of 25 Prospect-stage contacts turned up only 3
-- opportunities. Low counts here are the account fragmentation rule working, not a gap.
-- =====================================================================================

create table if not exists fact_opportunity (
    activity_id      text primary key,
    prospect_id      text not null,
    opportunity_name text,
    stage            text,          -- mx_Custom_2: Prospect / In Discussion / Agreement Sent / ...
    status           text,          -- Open | Won | Lost
    owner_id         text,
    created_at_utc   timestamptz not null,
    created_date_ist date generated always as
                         (((created_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date) stored,
    modified_at_utc  timestamptz,
    ingest_source    text not null default 'backfill',
    ingested_at      timestamptz not null default now()
);

create index if not exists idx_opp_prospect on fact_opportunity (prospect_id);
create index if not exists idx_opp_stage    on fact_opportunity (stage);

alter table fact_opportunity enable row level security;
revoke all on fact_opportunity from anon, authenticated;

-- Canonical deal stages, in forward order. Rank lets a view sort a funnel correctly rather
-- than alphabetically, and makes "furthest stage reached" expressible.
insert into ref_canonical_value (field, value) values
    ('opportunity_stage','Prospect'),
    ('opportunity_stage','In Discussion'),
    ('opportunity_stage','Agreement Sent'),
    ('opportunity_stage','Invoice Sent'),
    ('opportunity_stage','Payment Received'),
    ('opportunity_stage','Customer'),
    ('opportunity_stage','Closed - Lost')
on conflict (field, value) do nothing;

create or replace function opp_stage_rank(s text) returns integer
language sql immutable as $$
    select case s
        when 'Prospect'         then 1
        when 'In Discussion'    then 2
        when 'Agreement Sent'   then 3
        when 'Invoice Sent'     then 4
        when 'Payment Received' then 5
        when 'Customer'         then 6
        when 'Closed - Lost'    then 99
        else 0
    end;
$$;


-- --------------------------------------------------------------------------------------
-- v_opportunity_state - the deal board. Where every live opportunity sits, by rep.
-- --------------------------------------------------------------------------------------
create or replace view v_opportunity_state as
select
    coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unknown>') as rep,
    coalesce(o.stage, '<blank>')                                 as stage,
    opp_stage_rank(o.stage)                                      as stage_rank,
    o.status,
    count(*)                                                     as opportunities,
    count(distinct o.prospect_id)                                as contacts
from fact_opportunity o
left join dim_contact ct on ct.prospect_id = o.prospect_id
left join dim_rep r      on r.owner_id = o.owner_id
group by 1, 2, 3, 4;


-- --------------------------------------------------------------------------------------
-- v_journey - one row per contact that has reached at least Engaged, with the milestone
-- timestamps and the gaps between them.
--
-- This is the Fresh -> Engaged -> Prospect -> deal -> closed picture end to end. Days
-- between milestones are the part worth reading: a healthy funnel moves, and a rep whose
-- contacts sit 20 days between Engaged and Prospect has a qualification problem rather than
-- an activity problem.
--
-- Milestones come from v_stage_history (backfilled 3002 plus live field-change webhooks),
-- so they are exact as far back as the backfill reaches.
-- --------------------------------------------------------------------------------------
create or replace view v_journey as
with ms as (
    select
        prospect_id,
        min(changed_at_utc) filter (where current_stage = 'Engaged')      as engaged_at,
        min(changed_at_utc) filter (where current_stage = 'Prospect')     as prospect_at,
        min(changed_at_utc) filter (where current_stage = 'Customer')     as customer_at,
        min(changed_at_utc) filter (where current_stage = 'Disqualified') as disqualified_at
    from v_stage_history
    where changed_at_utc >= timestamptz '2026-08-01'
    group by prospect_id
),
firstcall as (
    select prospect_id, min(called_at_utc) as first_call_utc, count(*) as total_calls,
           count(*) filter (where connected) as total_connects
    from fact_call
    group by prospect_id
)
select
    ct.prospect_id,
    coalesce(ct.owner_name, '<unenriched>')  as rep,
    ct.company_name,
    ct.full_name                             as contact_name,
    ct.contact_stage                         as stage_now,
    fc.first_call_utc,
    ms.engaged_at,
    ms.prospect_at,
    coalesce(ms.customer_at, ms.disqualified_at) as closed_at,
    case when ms.customer_at is not null then 'Customer'
         when ms.disqualified_at is not null then 'Disqualified'
         else 'Open' end                     as outcome,
    coalesce(fc.total_calls, 0)              as calls,
    coalesce(fc.total_connects, 0)           as connects,
    o.stage                                  as deal_stage,
    o.status                                 as deal_status,
    -- Elapsed days between milestones. NULL where the milestone has not happened, which is
    -- correct: a zero would read as "instant" rather than "not yet".
    round(extract(epoch from (ms.engaged_at  - fc.first_call_utc)) / 86400.0, 1) as days_call_to_engaged,
    round(extract(epoch from (ms.prospect_at - ms.engaged_at))     / 86400.0, 1) as days_engaged_to_prospect,
    round(extract(epoch from (coalesce(ms.customer_at, ms.disqualified_at) - ms.prospect_at)) / 86400.0, 1)
                                                                                 as days_prospect_to_close
from dim_contact ct
left join ms       on ms.prospect_id = ct.prospect_id
left join firstcall fc on fc.prospect_id = ct.prospect_id
left join fact_opportunity o on o.prospect_id = ct.prospect_id
where ms.engaged_at is not null or ct.contact_stage in ('Prospect','Customer');


-- --------------------------------------------------------------------------------------
-- v_funnel_conversion - the whole-team funnel, per rep. What actually converts.
-- --------------------------------------------------------------------------------------
create or replace view v_funnel_conversion as
select
    rep,
    count(*)                                              as contacts_engaged,
    count(*) filter (where prospect_at is not null)       as reached_prospect,
    count(*) filter (where deal_stage is not null)        as has_opportunity,
    count(*) filter (where outcome = 'Customer')          as won,
    count(*) filter (where outcome = 'Disqualified')      as lost,
    round(100.0 * count(*) filter (where prospect_at is not null) / nullif(count(*), 0), 1)
                                                          as engaged_to_prospect_pct,
    round(100.0 * count(*) filter (where outcome = 'Customer')
          / nullif(count(*) filter (where prospect_at is not null), 0), 1)
                                                          as prospect_to_customer_pct,
    round(avg(days_engaged_to_prospect), 1)               as avg_days_to_prospect
from v_journey
group by rep;
