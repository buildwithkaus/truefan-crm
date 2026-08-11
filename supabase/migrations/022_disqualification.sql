-- =====================================================================================
-- TrueFan CRM - 022: disqualification analysis (2026-08-11)
--
-- Asked for: per rep, how many contacts sit at Disqualified, how many of those carry a
-- reason, the split across reasons, and how many moved to Disqualified per rep since 1 Aug.
--
-- THE SIZING PROBLEM THAT DECIDES THE DESIGN. dim_contact holds only contacts the pipeline
-- has enriched - 17,811 of 91,047, of which 8,900 are Disqualified. The real figure is
-- 61,375. Building this off dim_contact would have reported a seventh of the problem as if
-- it were all of it, and every per-rep percentage would have been computed on whichever
-- slice of that rep's book happened to have been called recently.
--
-- So the current-state half is fed by the daily book scan, which already pages all 91,047
-- leads and therefore costs NOTHING extra to widen - the same trick that made dim_rep.email
-- free. The movement half comes from v_stage_history, which is exact from 1 August.
--
-- WHOSE NUMBER IS IT. Both halves credit the CONTACT OWNER, matching the 020 decision.
-- For movement that means the owner now, not whoever clicked - a contact disqualified by an
-- admin sweep still belongs to the rep whose book it is.
-- =====================================================================================


-- --------------------------------------------------------------------------------------
-- Grain: one row per snapshot_date x owner x reason. Written by 03-snapshot-book.ps1.
--
-- '<blank>' is stored as a real reason value rather than NULL. A disqualification with no
-- reason is the single gap that destroys information permanently (memory/11 finding 3), so
-- it has to be a countable row on the report, not an absence that sums to nothing.
-- --------------------------------------------------------------------------------------
create table if not exists fact_disqualification_snapshot (
    snapshot_date date    not null,
    owner_id      text    not null,
    owner_name    text,
    reason        text    not null,
    contacts      integer not null,
    captured_at   timestamptz not null default now(),
    primary key (snapshot_date, owner_id, reason)
);

create index if not exists idx_disq_date on fact_disqualification_snapshot (snapshot_date);

alter table fact_disqualification_snapshot enable row level security;
revoke all on fact_disqualification_snapshot from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- v_disqualified_by_rep - the headline table: how much of each rep's disqualified pile is
-- actually explained.
-- --------------------------------------------------------------------------------------
create or replace view v_disqualified_by_rep as
with latest as (select max(snapshot_date) as d from fact_disqualification_snapshot)
select
    coalesce(s.owner_name, s.owner_id)                              as rep,
    sum(s.contacts)                                                 as disqualified,
    sum(s.contacts) filter (where s.reason <> '<blank>')            as with_reason,
    sum(s.contacts) filter (where s.reason = '<blank>')             as no_reason,
    round(100.0 * sum(s.contacts) filter (where s.reason <> '<blank>')
          / nullif(sum(s.contacts), 0), 1)                          as pct_with_reason,
    count(distinct s.reason) filter (where s.reason <> '<blank>')    as distinct_reasons,
    max(s.snapshot_date)                                            as as_of
from fact_disqualification_snapshot s
join latest l on s.snapshot_date = l.d
group by 1
order by no_reason desc;


-- --------------------------------------------------------------------------------------
-- v_disqualified_reasons - rep x reason, long format.
--
-- Long rather than pivoted because the reason list is NOT stable: new values keep appearing
-- (memory/11 finding 4), and a view with a fixed column per reason silently drops any value
-- invented after it was written. The Sheet pivots it at render time instead.
-- --------------------------------------------------------------------------------------
create or replace view v_disqualified_reasons as
with latest as (select max(snapshot_date) as d from fact_disqualification_snapshot)
select
    coalesce(s.owner_name, s.owner_id)  as rep,
    s.reason,
    s.contacts,
    round(100.0 * s.contacts
          / nullif(sum(s.contacts) over (partition by s.owner_id), 0), 1) as pct_of_rep,
    -- Flags a stored value that is not a selectable dropdown option: LSQ accepts those
    -- silently and they are invisible to every rep filter (gotcha 10).
    (r.value is null)                   as non_canonical,
    s.snapshot_date                     as as_of
from fact_disqualification_snapshot s
join latest l on s.snapshot_date = l.d
left join ref_canonical_value r
       on r.field = 'disqualification_reason' and r.value = s.reason
where s.reason <> '<blank>'
order by rep, contacts desc;


-- --------------------------------------------------------------------------------------
-- v_disqualified_totals - the same reason split for the whole account, not per rep.
-- --------------------------------------------------------------------------------------
create or replace view v_disqualified_totals as
with latest as (select max(snapshot_date) as d from fact_disqualification_snapshot)
select
    s.reason,
    sum(s.contacts)                                                  as contacts,
    round(100.0 * sum(s.contacts) / nullif(sum(sum(s.contacts)) over (), 0), 1) as pct,
    (r.value is null and s.reason <> '<blank>')                      as non_canonical,
    max(s.snapshot_date)                                             as as_of
from fact_disqualification_snapshot s
join latest l on s.snapshot_date = l.d
left join ref_canonical_value r
       on r.field = 'disqualification_reason' and r.value = s.reason
group by s.reason, r.value
order by contacts desc;


-- --------------------------------------------------------------------------------------
-- v_disqualified_movement - contacts moved INTO Disqualified, per rep per day, from 1 Aug.
--
-- Reads v_stage_history, which unions the trail backfill with the live field-change webhook
-- and is therefore current (019 fixed the movement tab for exactly this reason).
--
-- Credited to the contact OWNER where known, falling back to whoever made the change. The
-- fallback matters: bulk and admin sweeps are made by one account across many reps' books,
-- and attributing those to the clicker would put thousands of disqualifications against
-- Admin while emptying the books they actually came from.
-- --------------------------------------------------------------------------------------
create or replace view v_disqualified_movement as
select
    ((h.changed_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date as report_date,
    coalesce(ct.owner_name, h.changed_by_name, '<unknown>')  as rep,
    coalesce(h.previous_stage, '<none>')                     as from_stage,
    h.changed_by_name                                        as moved_by,
    count(distinct h.prospect_id)                            as contacts
from v_stage_history h
left join dim_contact ct on ct.prospect_id = h.prospect_id
where h.current_stage = 'Disqualified'
  and coalesce(h.previous_stage, '') is distinct from 'Disqualified'
  and ((h.changed_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date >= date '2026-08-01'
group by 1, 2, 3, 4;


-- --------------------------------------------------------------------------------------
-- v_disqualified_movement_rep - the same, rolled to rep x day, which is what the tab shows.
-- --------------------------------------------------------------------------------------
create or replace view v_disqualified_movement_rep as
select
    report_date,
    rep,
    sum(contacts)                                          as disqualified,
    sum(contacts) filter (where from_stage = 'Fresh')      as from_fresh,
    sum(contacts) filter (where from_stage = 'Engaged')    as from_engaged,
    sum(contacts) filter (where from_stage = 'Prospect')   as from_prospect
from v_disqualified_movement
group by 1, 2
order by report_date desc, disqualified desc;


-- --------------------------------------------------------------------------------------
-- channel_bundle gains the four disqualification datasets.
--
-- Retyped in full rather than patched: PostgreSQL has no "add a key to a function" and a
-- create-or-replace must restate the whole body. Every key from 021 is preserved below -
-- dropping one here would blank a tab silently, since the writer would just see undefined.
-- --------------------------------------------------------------------------------------
create or replace function channel_bundle(p_from date default '2026-08-01')
returns json
language sql stable as $$
select json_build_object(
    'generated_at',  now(),
    'from_date',     p_from,
    'rep_order',     (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_rep_order
                         order by team_sort, is_lead desc, rep_sort, rep) t),
    'channel_day',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_channel_day
                         where report_date >= p_from
                         order by report_date desc, touches desc) t),
    'channel_mix',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_channel_mix_rep order by rep, touches desc) t),
    'book_health',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_book_health order by recoverable desc) t),
    'non_owner',     (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_non_owner_summary limit 200) t),
    'qc_channel',    (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_channel) t),
    'qc_saturation', (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_saturation) t),
    'qc_movement',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_movement) t),
    'unmapped',      (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_channel_unmapped) t),

    -- 022 additions
    'disq_by_rep',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_by_rep) t),
    'disq_reasons',  (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_reasons) t),
    'disq_totals',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_totals) t),
    'disq_movement', (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_movement_rep
                         where report_date >= p_from) t)
);
$$;

revoke all on v_disqualified_by_rep         from anon, authenticated;
revoke all on v_disqualified_reasons        from anon, authenticated;
revoke all on v_disqualified_totals         from anon, authenticated;
revoke all on v_disqualified_movement       from anon, authenticated;
revoke all on v_disqualified_movement_rep   from anon, authenticated;
