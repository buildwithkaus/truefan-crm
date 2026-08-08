-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 006: field-change history (2026-08-08)
--
-- The Lead Field Value Change webhook payload turned out to be far richer than expected.
-- Captured live:
--
--   {"Before":{"ProspectID":"...","ProspectStage":"Fresh","mx_Call_Disposition":null,
--              "OwnerId":"...","ModifiedBy":"...","ModifiedOn":"2026-08-08 09:02:18", ...},
--    "After": {"ProspectID":"...","ProspectStage":"Engaged", ... }}
--
-- Two complete lead snapshots. That means we get the exact old and new value, the moment it
-- changed, and who changed it - for stage, call disposition and disqualification reason
-- alike. This is the thing the backfill provably cannot reconstruct, because LeadSquared
-- keeps no history of a lead field's previous values.
--
-- One table covers all three fields: the webhook is configured per field, but the payload
-- carries everything, so Apps Script diffs Before vs After and emits a row per field that
-- actually moved. Multi-field edits therefore produce multiple rows, which is correct.
-- =====================================================================================

create table if not exists fact_field_change (
    -- No id in the payload, so the key is composed. prospect + field + timestamp is unique
    -- in practice and makes re-delivery idempotent, which matters because LeadSquared
    -- retries a webhook up to three times.
    change_key      text primary key,
    prospect_id     text not null,
    field_name      text not null,
    old_value       text,
    new_value       text,
    changed_at_utc  timestamptz not null,
    change_date_ist date generated always as
                        (((changed_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date) stored,
    changed_by_id   text,
    owner_id        text,
    ingest_source   text not null default 'webhook',
    ingested_at     timestamptz not null default now()
);

create index if not exists idx_fieldchange_lookup on fact_field_change (prospect_id, field_name, changed_at_utc desc);
create index if not exists idx_fieldchange_date   on fact_field_change (change_date_ist, field_name);

alter table fact_field_change enable row level security;
revoke all on fact_field_change from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- Stage changes recorded through the field-change webhook are equivalent to EventCode 3002
-- from the trails, so v_call_enriched should see both as one history. This view unions
-- them; the backfill supplies the past, the webhook supplies the present.
-- --------------------------------------------------------------------------------------
create or replace view v_stage_history as
select prospect_id, changed_at_utc, previous_stage, current_stage, changed_by_name, 'trail'::text as src
from fact_stage_change
union all
select prospect_id, changed_at_utc, old_value, new_value,
       coalesce(r.lsq_name, f.changed_by_id), 'webhook'::text
from fact_field_change f
left join dim_rep r on r.owner_id = f.changed_by_id
where f.field_name = 'ProspectStage';


-- --------------------------------------------------------------------------------------
-- Disposition as it stood AT THE TIME OF A CALL.
--
-- Before the field-change webhook went live there is genuinely nothing to reconstruct from,
-- so those calls resolve to null and the pivot shows '<no history>'. From the cutover
-- onward this is exact rather than approximate.
-- --------------------------------------------------------------------------------------
create or replace view v_call_disposition_at_time as
select
    c.activity_id,
    c.prospect_id,
    c.called_at_utc,
    (
        select f.new_value
        from fact_field_change f
        where f.prospect_id = c.prospect_id
          and f.field_name = 'mx_Call_Disposition'
          and f.changed_at_utc >= c.called_at_utc
          -- The first disposition set AFTER the call is the one describing that call.
          -- Bounded to 12 hours so a value typed days later is not credited to it.
          and f.changed_at_utc < c.called_at_utc + interval '12 hours'
        order by f.changed_at_utc asc
        limit 1
    ) as disposition_at_call
from fact_call c;


-- --------------------------------------------------------------------------------------
-- Who is actually recording outcomes, per rep per day. The counterpart to call volume:
-- this measures whether the CRM is being maintained, independent of dialling effort.
-- --------------------------------------------------------------------------------------
create or replace view v_field_change_daily as
select
    f.change_date_ist                              as report_date,
    coalesce(r.lsq_name, f.changed_by_id, '<system>') as rep,
    f.field_name,
    count(*)                                       as changes,
    count(distinct f.prospect_id)                  as contacts
from fact_field_change f
left join dim_rep r on r.owner_id = f.changed_by_id
group by 1, 2, 3;
