-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 011: apply the owner-attribution rule to the per-rep views (2026-08-09)
--
-- THE DEFECT. CLAUDE.md states the rule as non-negotiable:
--
--   "Attribute a call to a rep only when ActivityFields.CreatedBy equals the lead's current
--    OwnerId. Calls by a previous owner are inherited activity, not their work."
--
-- v_call_enriched computes exactly that, as is_owner_call. Nothing downstream used it.
-- v_contact_day and v_pivot_disposition both grouped on
-- coalesce(contact_owner_name, actor_name), which buckets a call by WHO OWNS THE CONTACT
-- regardless of who dialled - so every call a previous owner made on a lead that has since
-- been reassigned was credited to the rep who inherited it.
--
-- Measured on 2026-08-09: 1,266 of 12,837 outbound calls (9.9%) were being attributed to
-- someone who did not make them, concentrated in the reassignment window - 493 on 2026-08-01
-- alone, falling to 1-3/day by the 7th. That decay is why the oracle only caught it as
-- "Mayank Arora, PIPELINE HIGH by 1" on 2026-08-07. Had it been checked against 1 August the
-- disagreement would have been 493.
--
-- THE FIX, AND WHY IT IS A BUCKET RATHER THAN A FILTER. Dropping these calls would make
-- v_rep_day disagree with fact_call, and QC check 5 - pivot total equals raw dials - would
-- start failing for a reason that is not a bug. Instead they are attributed to an explicit
-- '<inherited: not the owner>' bucket. Totals still reconcile, no rep is credited with work
-- they did not do, and the volume is visible on the tab rather than silently deleted.
--
-- Every column name, type and position is preserved, so create-or-replace is safe and
-- nothing downstream needs changing.
-- =====================================================================================

-- --------------------------------------------------------------------------------------
-- One definition of "which rep does this call belong to", used by every per-rep view, so
-- the three cannot drift apart again. That drift is what produced this bug.
--
-- The coalesce order matters and the placeholder is LAST (gotcha 18): a non-null placeholder
-- upstream would defeat every fallback below it, which is how 980 calls once collapsed onto
-- a single row.
-- --------------------------------------------------------------------------------------
create or replace function call_rep(is_owner boolean, owner_name text, actor_name text)
returns text language sql immutable as $$
    select case
        when coalesce(is_owner, false) then coalesce(owner_name, actor_name, '<unknown>')
        else '<inherited: not the owner>'
    end;
$$;


create or replace view v_contact_day as
with day_calls as (
    select
        e.prospect_id,
        e.call_date_ist,
        call_rep(e.is_owner_call, e.contact_owner_name, e.actor_name) as rep,
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
        call_rep(e.is_owner_call, e.contact_owner_name, e.actor_name) as rep,
        e.stage_at_call                                               as contact_stage,
        case
            when e.call_date_ist < (select from_date from cutover) then '<no history>'
            else e.call_disposition
        end                                                           as disposition,
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


-- --------------------------------------------------------------------------------------
-- v_daily_totals - team volume, so it deliberately counts EVERY call including inherited
-- ones. The two new columns at the end make the split visible; active_reps now counts only
-- reps credited with their own work, so the inherited bucket cannot inflate headcount.
--
-- New columns are appended, never inserted, because create-or-replace cannot reorder a
-- view's column list.
-- --------------------------------------------------------------------------------------
create or replace view v_daily_totals as
select
    call_date_ist                                as report_date,
    count(*) filter (where direction = 'outbound')                 as dials,
    count(*) filter (where direction = 'outbound' and connected)   as connects,
    count(distinct prospect_id)                                    as contacts,
    count(distinct coalesce(contact_owner_name, actor_name, '<unknown>'))
        filter (where is_owner_call)                               as active_reps,
    round(sum(duration_sec) / 60.0, 0)                             as talk_min,
    round(100.0 * count(*) filter (where direction='outbound' and connected)
          / nullif(count(*) filter (where direction='outbound'),0), 1) as connect_rate_pct,
    count(*) filter (where direction = 'outbound' and is_owner_call)       as owner_dials,
    count(*) filter (where direction = 'outbound' and not is_owner_call)   as inherited_dials
from v_call_enriched
group by 1;


-- --------------------------------------------------------------------------------------
-- QC check 14 - inherited calls are bucketed, never credited to a rep.
--
-- A regression here is invisible in the totals (they still reconcile either way) and only
-- shows up as a rep's dial count being quietly too high, which is precisely the kind of
-- error nobody catches by looking.
-- --------------------------------------------------------------------------------------
create or replace view v_qc_attribution as
select
    'Inherited calls are not credited to a rep' as check_name,
    '0'::text                                   as expected,
    (select count(*)::text
       from v_contact_day
      where rep <> '<inherited: not the owner>'
        and prospect_id in (
            select prospect_id from v_call_enriched
            where not is_owner_call
              and prospect_id not in (select prospect_id from v_call_enriched where is_owner_call)
        ))                                      as actual,
    (select coalesce(sum(inherited_dials), 0)::text from v_daily_totals) as inherited_dials_total,
    (select coalesce(sum(dials), 0)::text from v_daily_totals)           as all_dials_total;

grant select on v_qc_attribution to anon, authenticated;
