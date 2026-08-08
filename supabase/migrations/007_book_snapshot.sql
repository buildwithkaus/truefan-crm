-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 007: book-of-business snapshot (2026-08-08)
--
-- Everything up to now answers "what did reps DO" - activity. This answers "what do reps
-- HOLD" - state. A rep with 2,000 assigned contacts and 1,900 of them still at Fresh is a
-- completely different problem from one with 200 contacts all at Prospect, and no amount of
-- call-volume reporting distinguishes them.
--
-- Grain: one row per snapshot_date x owner x contact stage.
--
-- WHY A DAILY SNAPSHOT RATHER THAN A LIVE QUERY. LeadSquared has no count endpoint (probed
-- 2026-08-08: Leads.Count, Leads.Get.Count and Leads/Count all 404) and Leads.Get returns no
-- total, so the only way to get these numbers is to page the whole book - about 87 pages.
-- That is cheap in API calls but far too slow for an Apps Script trigger, so a scheduled
-- PowerShell job writes it once a day.
--
-- Snapshotting rather than overwriting also gives the more valuable half for free: how each
-- rep's book MOVES week over week. A pipeline that is not draining looks identical to a
-- healthy one in any single-day view.
-- =====================================================================================

create table if not exists fact_book_snapshot (
    snapshot_date date    not null,
    owner_id      text    not null,
    owner_name    text,
    contact_stage text    not null,
    contacts      integer not null,
    captured_at   timestamptz not null default now(),
    primary key (snapshot_date, owner_id, contact_stage)
);

create index if not exists idx_book_date on fact_book_snapshot (snapshot_date);

alter table fact_book_snapshot enable row level security;
revoke all on fact_book_snapshot from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- v_pipeline_state - the current book, one row per rep per stage, from the latest snapshot.
-- --------------------------------------------------------------------------------------
create or replace view v_pipeline_state as
with latest as (select max(snapshot_date) as d from fact_book_snapshot)
select
    b.snapshot_date,
    coalesce(b.owner_name, b.owner_id) as rep,
    b.contact_stage,
    b.contacts,
    round(100.0 * b.contacts / nullif(sum(b.contacts) over (partition by b.owner_id), 0), 1)
                                       as pct_of_book,
    sum(b.contacts) over (partition by b.owner_id) as book_size
from fact_book_snapshot b
join latest l on b.snapshot_date = l.d
where b.contacts > 0;


-- --------------------------------------------------------------------------------------
-- v_pipeline_state_wide - the same thing pivoted, which is how a human reads a book.
--
-- Stage columns are fixed here rather than generated, because the contact-stage taxonomy is
-- locked at five values (unlike Call Disposition, which fragments and therefore has to be
-- pivoted dynamically). Anything outside the five lands in `other`, which makes taxonomy
-- drift visible instead of silently dropping the rows.
-- --------------------------------------------------------------------------------------
create or replace view v_pipeline_state_wide as
with latest as (select max(snapshot_date) as d from fact_book_snapshot)
select
    coalesce(b.owner_name, b.owner_id)                              as rep,
    sum(b.contacts)                                                 as book_size,
    sum(b.contacts) filter (where b.contact_stage = 'Fresh')        as fresh,
    sum(b.contacts) filter (where b.contact_stage = 'Engaged')      as engaged,
    sum(b.contacts) filter (where b.contact_stage = 'Prospect')     as prospect,
    sum(b.contacts) filter (where b.contact_stage = 'Customer')     as customer,
    sum(b.contacts) filter (where b.contact_stage = 'Disqualified') as disqualified,
    sum(b.contacts) filter (where b.contact_stage not in
        ('Fresh','Engaged','Prospect','Customer','Disqualified'))   as other,
    -- The working pool: what is still actionable. Customers and disqualifications are done.
    sum(b.contacts) filter (where b.contact_stage in ('Fresh','Engaged','Prospect')) as workable,
    round(100.0 * sum(b.contacts) filter (where b.contact_stage = 'Fresh')
          / nullif(sum(b.contacts) filter (where b.contact_stage in ('Fresh','Engaged','Prospect')), 0), 1)
                                                                    as pct_untouched,
    round(100.0 * sum(b.contacts) filter (where b.contact_stage = 'Prospect')
          / nullif(sum(b.contacts) filter (where b.contact_stage in ('Fresh','Engaged','Prospect')), 0), 1)
                                                                    as pct_at_prospect,
    max(b.snapshot_date)                                            as as_of
from fact_book_snapshot b
join latest l on b.snapshot_date = l.d
group by 1;


-- --------------------------------------------------------------------------------------
-- v_book_movement - how the book changed since the previous snapshot.
--
-- This is the number that actually says whether a pipeline is being worked: Fresh should
-- fall, Prospect should rise. A book where nothing moves but call volume is high means reps
-- are dialling without progressing anything.
-- --------------------------------------------------------------------------------------
create or replace view v_book_movement as
with dates as (
    select distinct snapshot_date from fact_book_snapshot order by snapshot_date desc limit 2
),
newest as (select max(snapshot_date) as d from dates),
oldest as (select min(snapshot_date) as d from dates)
select
    coalesce(n.owner_name, n.owner_id)      as rep,
    n.contact_stage,
    n.contacts                              as now_count,
    coalesce(p.contacts, 0)                 as prev_count,
    n.contacts - coalesce(p.contacts, 0)    as delta,
    (select d from oldest)                  as compared_to,
    (select d from newest)                  as as_of
from fact_book_snapshot n
join newest on n.snapshot_date = newest.d
left join fact_book_snapshot p
       on p.owner_id = n.owner_id
      and p.contact_stage = n.contact_stage
      and p.snapshot_date = (select d from oldest)
where (select d from oldest) <> (select d from newest);


-- --------------------------------------------------------------------------------------
-- v_book_coverage - of the workable book, how much has actually been dialled.
--
-- Joins state to activity, which neither side can answer alone: a rep can look busy on call
-- volume while never touching most of their assigned list, because they keep re-dialling the
-- same responsive contacts.
-- --------------------------------------------------------------------------------------
create or replace view v_book_coverage as
with latest as (select max(snapshot_date) as d from fact_book_snapshot),
book as (
    select coalesce(b.owner_name, b.owner_id) as rep,
           sum(b.contacts) filter (where b.contact_stage in ('Fresh','Engaged','Prospect')) as workable
    from fact_book_snapshot b join latest l on b.snapshot_date = l.d
    group by 1
),
called as (
    select coalesce(contact_owner_name, actor_name, '<unknown>') as rep,
           count(distinct prospect_id) as contacts_called_7d
    from v_call_enriched
    where call_date_ist >= current_date - 7
    group by 1
)
select
    book.rep,
    book.workable,
    coalesce(called.contacts_called_7d, 0) as contacts_called_7d,
    round(100.0 * coalesce(called.contacts_called_7d, 0) / nullif(book.workable, 0), 1)
                                           as coverage_7d_pct
from book
left join called on called.rep = book.rep
where book.workable > 0;
