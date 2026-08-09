-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 012: correct the deal-stage taxonomy, and carry the full opportunity record (2026-08-09)
--
-- TWO CORRECTIONS AND ONE EXTENSION.
--
-- CORRECTION 1 - 'Requirement Gathering' is a REAL opportunity stage, not drift.
--
-- 010 treated it as a legacy alias of Prospect that the July restructure had failed to
-- rename, ranked it equal to Prospect, and had v_deal_stage_drift and QC check 10 report
-- all 91 of them as a taxonomy failure. Wrong on every count. Confirmed with Kaustubh:
--
--     Prospect               new pipeline
--     Requirement Gathering  WARM pipeline
--     In Discussion   \
--     Agreement Sent   >     HOT pipeline
--     Invoice Sent    /
--     Payment Received       won
--     Customer               won
--     Closed - Lost          lost
--
-- The confusion came from scripts/lib/schema.ps1's OpportunityStageRenames, which does list
-- Requirement Gathering -> Prospect. That mapping is for the CONTACT stage, where
-- 'Requirement Gathering' IS legacy and should become Prospect. The same string means
-- different things on the two objects, and conflating them turned a healthy warm pipeline
-- into a false data-quality alarm.
--
-- Warm-versus-hot is not decoration - it is the split a pipeline review is actually run on,
-- so it becomes a first-class column rather than something a reader has to reconstruct.
--
-- CORRECTION 2 - QC check 10 stops reporting a real stage as drift.
--
-- EXTENSION - the rest of the opportunity record.
--
-- GetOpportunityDetails (a GET, keyed on opportunityId, which is the same GUID as the
-- activity id already stored) returns all 29 fields WITH display names and data types.
-- GetOpportunitiesOfLead returns only four of them. Columns below mirror the fields the
-- business actually uses.
-- =====================================================================================

-- --------------------------------------------------------------------------------------
-- The rest of the opportunity record.
-- --------------------------------------------------------------------------------------
alter table fact_opportunity add column if not exists actual_deal_value   numeric;      -- mx_Custom_7
alter table fact_opportunity add column if not exists actual_close_date   date;         -- mx_Custom_9
alter table fact_opportunity add column if not exists loss_reason         text;         -- mx_Custom_4
alter table fact_opportunity add column if not exists source              text;         -- mx_Custom_3
alter table fact_opportunity add column if not exists description         text;         -- mx_Custom_5
alter table fact_opportunity add column if not exists product             text;         -- mx_Custom_10
alter table fact_opportunity add column if not exists celebrity_assigned  text;         -- mx_Custom_13
alter table fact_opportunity add column if not exists contract_start_date date;         -- mx_Custom_14
alter table fact_opportunity add column if not exists contract_end_date   date;         -- mx_Custom_15
alter table fact_opportunity add column if not exists agreement_sent_date date;         -- mx_Custom_16
alter table fact_opportunity add column if not exists invoice_sent_date   date;         -- mx_Custom_17
alter table fact_opportunity add column if not exists opportunity_note    text;
alter table fact_opportunity add column if not exists details_loaded_at   timestamptz;

create index if not exists idx_opp_details_loaded on fact_opportunity (details_loaded_at);


-- --------------------------------------------------------------------------------------
-- Canonical deal stages, corrected. 008 already inserted most of these; Requirement
-- Gathering was missing, which is what made it read as drift.
-- --------------------------------------------------------------------------------------
insert into ref_canonical_value (field, value) values
    ('opportunity_stage','Requirement Gathering')
on conflict (field, value) do nothing;


create or replace function opp_stage_rank(s text) returns integer
language sql immutable as $$
    select case s
        when 'Prospect'              then 1
        when 'Requirement Gathering' then 2   -- warm; NOT an alias of Prospect
        when 'In Discussion'         then 3
        when 'Agreement Sent'        then 4
        when 'Invoice Sent'          then 5
        when 'Payment Received'      then 6
        when 'Customer'              then 7
        when 'Closed - Lost'         then 99
        else 0                                -- unknown sorts first, so it gets noticed
    end;
$$;


-- --------------------------------------------------------------------------------------
-- Pipeline temperature. The split a deal review is run on: how much is warm, how much is
-- hot, and how much has not been qualified past the first conversation.
-- --------------------------------------------------------------------------------------
create or replace function opp_temperature(s text, st text) returns text
language sql immutable as $$
    select case
        when st = 'Won'  then 'Won'
        when st = 'Lost' then 'Lost'
        when s = 'Prospect'              then 'New'
        when s = 'Requirement Gathering' then 'Warm'
        when s in ('In Discussion','Agreement Sent','Invoice Sent') then 'Hot'
        when s in ('Payment Received','Customer') then 'Won'
        when s = 'Closed - Lost' then 'Lost'
        else 'Unclassified'
    end;
$$;

create or replace function opp_temp_rank(t text) returns integer
language sql immutable as $$
    select case t when 'Hot' then 1 when 'Warm' then 2 when 'New' then 3
                  when 'Won' then 4 when 'Lost' then 5 else 9 end;
$$;


-- --------------------------------------------------------------------------------------
-- v_deal_stage_drift - now excludes the full canonical list, so a healthy warm pipeline
-- stops being reported as a failure. Anything still appearing here is genuinely invented.
-- --------------------------------------------------------------------------------------
create or replace view v_deal_stage_drift as
select
    coalesce(o.stage, '<blank>')                                    as non_canonical_stage,
    coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
    count(*)                                                        as opportunities
from fact_opportunity o
left join dim_contact ct on ct.prospect_id = o.prospect_id
left join dim_rep r      on r.owner_id     = o.owner_id
where coalesce(o.stage, '') not in (
    select value from ref_canonical_value where field = 'opportunity_stage'
)
group by 1, 2;


-- --------------------------------------------------------------------------------------
-- v_opportunity_primary - re-created so it carries the new columns and the temperature.
-- Column list changes, so it must be dropped rather than replaced, and everything reading
-- it goes with it.
-- --------------------------------------------------------------------------------------
drop view if exists v_funnel_conversion;
drop view if exists v_funnel_rep;
drop view if exists v_journey;
drop view if exists v_forecast_quality;
drop view if exists v_forecast;
drop view if exists v_deal_board;
drop view if exists v_deal_stage_detail;
drop view if exists v_opportunity_primary;

create view v_opportunity_primary as
select distinct on (prospect_id)
    prospect_id, activity_id, opportunity_id, opportunity_name, stage, status,
    opp_temperature(stage, status)          as temperature,
    opp_temp_rank(opp_temperature(stage, status)) as temp_rank,
    owner_id, deal_value, currency, expected_close_date,
    actual_deal_value, actual_close_date, loss_reason, product, celebrity_assigned,
    agreement_sent_date, invoice_sent_date, contract_start_date, contract_end_date,
    opportunity_note, details_loaded_at,
    created_at_utc, created_date_ist, modified_at_utc, closed_at_utc
from fact_opportunity
order by prospect_id,
         (status = 'Won') desc,
         opp_stage_rank(stage) desc,
         coalesce(modified_at_utc, created_at_utc) desc;


create view v_deal_stage_detail as
select
    coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
    coalesce(o.status, '<blank>')                                   as status,
    coalesce(o.stage, '<blank>')                                    as stage,
    o.temperature,
    opp_stage_rank(o.stage)                                         as stage_rank,
    count(*)                                                        as opportunities,
    count(*) filter (where opp_value_known(o.deal_value))           as with_value,
    coalesce(sum(o.deal_value) filter (where opp_value_known(o.deal_value)), 0) as known_value
from v_opportunity_primary o
left join dim_contact ct on ct.prospect_id = o.prospect_id
left join dim_rep r      on r.owner_id = o.owner_id
group by 1, 2, 3, 4, 5;


-- --------------------------------------------------------------------------------------
-- v_deal_board - now carries the warm/hot split, which is the number a pipeline review
-- opens with. "Hot" is the near-term forecast; "New" is a stage nobody has qualified past.
-- --------------------------------------------------------------------------------------
create view v_deal_board as
with base as (
    select
        coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
        o.status, o.temperature, o.deal_value, o.actual_deal_value,
        o.expected_close_date, o.created_at_utc
    from v_opportunity_primary o
    left join dim_contact ct on ct.prospect_id = o.prospect_id
    left join dim_rep r      on r.owner_id = o.owner_id
)
select
    rep,
    count(*)                                                as total_opps,
    count(*) filter (where status = 'Open')                 as open_opps,
    count(*) filter (where temperature = 'Hot')             as hot,
    count(*) filter (where temperature = 'Warm')            as warm,
    count(*) filter (where temperature = 'New')             as new_unqualified,
    count(*) filter (where status = 'Won')                  as won,
    count(*) filter (where status = 'Lost')                 as lost,
    round(100.0 * count(*) filter (where status = 'Won')
          / nullif(count(*) filter (where status in ('Won','Lost')), 0), 1) as win_rate_pct,
    coalesce(sum(deal_value) filter (where temperature = 'Hot'  and opp_value_known(deal_value)), 0)
                                                            as hot_known_value,
    coalesce(sum(deal_value) filter (where status = 'Open' and opp_value_known(deal_value)), 0)
                                                            as open_known_value,
    coalesce(sum(actual_deal_value) filter (where status = 'Won'), 0)
                                                            as won_actual_value,
    count(*) filter (where status = 'Open' and not opp_value_known(deal_value)) as open_unvalued,
    count(*) filter (where status = 'Open' and expected_close_date is null)     as open_no_close_date,
    min(created_at_utc)                                     as oldest_opp_created
from base
group by rep;


create view v_forecast as
with lastcall as (
    select prospect_id, max(called_at_utc) as last_call_utc,
           count(*) as calls, count(*) filter (where connected) as connects
    from fact_call group by prospect_id
),
prospect_since as (
    select prospect_id, min(changed_at_utc) as became_prospect_utc
    from v_stage_history where current_stage = 'Prospect' group by prospect_id
)
select
    coalesce(r.lsq_name, ct.owner_name, o.owner_id, '<unassigned>') as rep,
    ct.company_name,
    ct.full_name                        as contact_name,
    o.prospect_id,
    o.opportunity_name,
    coalesce(o.stage, '<blank>')        as stage,
    o.temperature,
    o.temp_rank,
    o.status,
    o.deal_value,
    o.currency,
    o.expected_close_date,
    o.celebrity_assigned,
    o.product,
    o.agreement_sent_date,
    o.invoice_sent_date,
    ps.became_prospect_utc,
    lc.last_call_utc,
    coalesce(lc.calls, 0)               as calls,
    coalesce(lc.connects, 0)            as connects,
    (current_date - o.created_at_utc::date)                       as days_open,
    (o.expected_close_date - current_date)                        as days_to_close,
    (current_date - lc.last_call_utc::date)                       as days_since_last_call,
    not opp_value_known(o.deal_value)                             as missing_value,
    (o.expected_close_date is null)                               as missing_close_date,
    (o.expected_close_date is not null and o.expected_close_date < current_date) as overdue,
    (lc.last_call_utc is null or lc.last_call_utc < now() - interval '14 days') as stale,
    opp_stage_rank(o.stage)                                       as stage_rank
from v_opportunity_primary o
left join dim_contact  ct on ct.prospect_id = o.prospect_id
left join dim_rep      r  on r.owner_id     = o.owner_id
left join lastcall     lc on lc.prospect_id = o.prospect_id
left join prospect_since ps on ps.prospect_id = o.prospect_id
where coalesce(o.status, 'Open') = 'Open';


create view v_forecast_quality as
with per_rep as (
    select
        rep,
        count(*)                                                       as open_opps,
        count(*) filter (where temperature = 'Hot')                    as hot_opps,
        count(*) filter (where not missing_value)                      as with_value,
        count(*) filter (where not missing_close_date)                 as with_close_date,
        count(*) filter (where not missing_value and not missing_close_date) as forecastable,
        coalesce(sum(deal_value) filter (where not missing_value), 0)  as known_value,
        coalesce(sum(deal_value) filter (where not missing_value and temperature = 'Hot'), 0)
                                                                       as hot_known_value,
        avg(deal_value) filter (where not missing_value)               as avg_known_value,
        count(*) filter (where missing_value)                          as unvalued_opps,
        count(*) filter (where overdue)                                as overdue_opps,
        count(*) filter (where stale)                                  as stale_opps
    from v_forecast
    group by rep
)
select
    rep, open_opps, hot_opps, with_value, with_close_date, forecastable,
    round(100.0 * forecastable / nullif(open_opps, 0), 1) as forecastable_pct,
    round(100.0 * with_value   / nullif(open_opps, 0), 1) as valued_pct,
    known_value, hot_known_value,
    round(avg_known_value, 0)                             as avg_known_value,
    unvalued_opps,
    round(avg_known_value * unvalued_opps, 0)             as est_blind_value,
    overdue_opps, stale_opps
from per_rep;


create view v_journey as
with ms as (
    select prospect_id,
        min(changed_at_utc) filter (where current_stage = 'Engaged')      as engaged_at,
        min(changed_at_utc) filter (where current_stage = 'Prospect')     as prospect_at,
        min(changed_at_utc) filter (where current_stage = 'Customer')     as customer_at,
        min(changed_at_utc) filter (where current_stage = 'Disqualified') as disqualified_at
    from v_stage_history group by prospect_id
),
firstcall as (
    select prospect_id, min(called_at_utc) as first_call_utc, max(called_at_utc) as last_call_utc,
           count(*) as total_calls, count(*) filter (where connected) as total_connects
    from fact_call group by prospect_id
)
select
    ct.prospect_id,
    coalesce(ct.owner_name, '<unassigned>')  as rep,
    ct.company_name,
    ct.full_name                             as contact_name,
    ct.contact_stage                         as stage_now,
    fc.first_call_utc, fc.last_call_utc,
    ms.engaged_at, ms.prospect_at,
    coalesce(ms.customer_at, ms.disqualified_at) as closed_at,
    case when ms.customer_at is not null then 'Customer'
         when ms.disqualified_at is not null then 'Disqualified'
         else 'Open' end                     as outcome,
    coalesce(fc.total_calls, 0)              as calls,
    coalesce(fc.total_connects, 0)           as connects,
    o.stage                                  as deal_stage,
    o.status                                 as deal_status,
    o.temperature                            as deal_temperature,
    o.deal_value, o.expected_close_date, o.actual_deal_value,
    round(extract(epoch from (ms.engaged_at  - fc.first_call_utc)) / 86400.0, 1) as days_call_to_engaged,
    round(extract(epoch from (ms.prospect_at - ms.engaged_at))     / 86400.0, 1) as days_engaged_to_prospect,
    round(extract(epoch from (coalesce(ms.customer_at, ms.disqualified_at) - ms.prospect_at)) / 86400.0, 1)
                                                                                 as days_prospect_to_close
from dim_contact ct
left join ms                    on ms.prospect_id = ct.prospect_id
left join firstcall fc          on fc.prospect_id = ct.prospect_id
left join v_opportunity_primary o on o.prospect_id = ct.prospect_id
where ms.engaged_at is not null
   or ct.contact_stage in ('Prospect','Customer')
   or o.prospect_id is not null;


create view v_funnel_rep as
with book as (
    select coalesce(owner_name, owner_id) as rep,
           sum(contacts)                                                    as book_size,
           sum(contacts) filter (where contact_stage in ('Fresh','Engaged','Prospect')) as workable,
           sum(contacts) filter (where contact_stage = 'Fresh')             as fresh
    from fact_book_snapshot
    where snapshot_date = (select max(snapshot_date) from fact_book_snapshot)
    group by 1
),
moved as (
    select rep,
           count(*)                                              as touched,
           count(*) filter (where engaged_at   is not null)      as engaged,
           count(*) filter (where prospect_at  is not null)      as prospect,
           count(*) filter (where deal_stage   is not null)      as with_opportunity,
           count(*) filter (where deal_temperature = 'Hot')      as hot,
           count(*) filter (where deal_status = 'Won')           as won,
           count(*) filter (where deal_status = 'Lost')          as lost,
           count(*) filter (where outcome = 'Disqualified')      as disqualified
    from v_journey group by rep
)
select
    coalesce(b.rep, m.rep)                        as rep,
    coalesce(b.book_size, 0)                      as book_size,
    coalesce(b.workable, 0)                       as workable,
    coalesce(b.fresh, 0)                          as untouched_fresh,
    coalesce(m.touched, 0)                        as in_journey,
    coalesce(m.engaged, 0)                        as engaged,
    coalesce(m.prospect, 0)                       as prospect,
    coalesce(m.with_opportunity, 0)               as opportunities,
    coalesce(m.hot, 0)                            as hot_deals,
    coalesce(m.won, 0)                            as won,
    coalesce(m.lost, 0)                           as lost,
    coalesce(m.disqualified, 0)                   as disqualified,
    round(100.0 * coalesce(m.engaged, 0)  / nullif(b.workable, 0), 1)  as book_to_engaged_pct,
    round(100.0 * coalesce(m.prospect, 0) / nullif(m.engaged, 0), 1)   as engaged_to_prospect_pct,
    round(100.0 * coalesce(m.with_opportunity, 0) / nullif(m.prospect, 0), 1) as prospect_to_opp_pct,
    round(100.0 * coalesce(m.hot, 0) / nullif(m.with_opportunity, 0), 1) as opp_to_hot_pct,
    round(100.0 * coalesce(m.won, 0) / nullif(m.won + m.lost, 0), 1)   as win_rate_pct
from book b
full outer join moved m on m.rep = b.rep;


create view v_funnel_conversion as
select rep, engaged as contacts_engaged, prospect as reached_prospect,
       opportunities as has_opportunity, won, lost,
       engaged_to_prospect_pct, win_rate_pct as prospect_to_customer_pct
from v_funnel_rep;


-- --------------------------------------------------------------------------------------
-- The hygiene worklist. Four problems, each with its own fix, each countable.
--
-- Sourced here rather than in a script so the Sheet, Excel and any ad-hoc query all read
-- the same definition - these numbers will be used to assign remediation work.
-- --------------------------------------------------------------------------------------
create or replace view v_opportunity_hygiene as
-- A deal still open on a contact that has been disqualified. Kaustubh's rule: disqualifying
-- the contact should have closed the deal, so every one of these is a deal to close as Lost.
select
    'OPEN_DEAL_ON_DISQUALIFIED'     as issue,
    1                               as severity,
    o.prospect_id,
    o.activity_id                   as opportunity_id,
    coalesce(r.lsq_name, ct.owner_name, '<unassigned>') as rep,
    ct.company_name,
    o.opportunity_name,
    o.stage,
    o.status,
    ct.contact_stage,
    'Close the deal as Lost - the contact was disqualified' as fix
from fact_opportunity o
join dim_contact ct on ct.prospect_id = o.prospect_id
left join dim_rep r on r.owner_id = o.owner_id
where o.status = 'Open' and ct.contact_stage = 'Disqualified'

union all
-- A contact at Prospect with no deal behind it. These are the migration's leftovers: the
-- contact was promoted from a legacy stage (Follow Up, Requirement Gathering, Conversation
-- In Progress) and the opportunity was never created alongside it.
select
    'PROSPECT_WITHOUT_DEAL', 2,
    ct.prospect_id, null,
    coalesce(ct.owner_name, '<unassigned>'),
    ct.company_name, null, null, null, ct.contact_stage,
    'Create the opportunity - every Prospect should have one'
from dim_contact ct
where ct.contact_stage = 'Prospect'
  and not exists (select 1 from fact_opportunity o where o.prospect_id = ct.prospect_id)

union all
-- Two deals on one contact. Only the primary contact may own an opportunity, so a second
-- one fragments the account. Being fixed by hand, but it still needs to be countable.
select
    'DUPLICATE_DEAL', 2,
    o.prospect_id, o.activity_id,
    coalesce(r.lsq_name, ct.owner_name, '<unassigned>'),
    ct.company_name, o.opportunity_name, o.stage, o.status, ct.contact_stage,
    'Two deals on one contact - keep the furthest advanced'
from fact_opportunity o
left join dim_contact ct on ct.prospect_id = o.prospect_id
left join dim_rep r      on r.owner_id = o.owner_id
where o.prospect_id in (
    select prospect_id from fact_opportunity group by prospect_id having count(*) > 1
)

union all
-- A contact still sitting on the legacy CONTACT stage 'Requirement Gathering'. On the
-- Contact object this value is legacy and maps to Prospect; on the Opportunity object the
-- same string is a real warm stage. Different objects, same word.
select
    'CONTACT_ON_LEGACY_STAGE', 2,
    ct.prospect_id, null,
    coalesce(ct.owner_name, '<unassigned>'),
    ct.company_name, null, null, null, ct.contact_stage,
    'Move the contact to Prospect - this is a legacy contact stage'
from dim_contact ct
where ct.contact_stage in ('Requirement Gathering','Requirement Gathering (Warm)',
                           'Conversation In Progress (Hot)','Conversation In Progress',
                           'Follow Up','Fresh Lead','Future Prospect');


grant select on v_opportunity_primary, v_deal_stage_detail, v_deal_board, v_forecast,
                v_forecast_quality, v_journey, v_funnel_rep, v_funnel_conversion,
                v_deal_stage_drift, v_opportunity_hygiene
          to anon, authenticated;
