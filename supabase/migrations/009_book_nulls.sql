-- =====================================================================================
-- TrueFan CRM - calling pipeline
-- 009: fix NULL-vs-zero in the book snapshot views (2026-08-08)
--
-- sum(...) filter (where ...) returns NULL, not 0, when no rows match the filter. So a rep
-- holding no Fresh contacts showed a blank Fresh column and a blank Untouched %, which
-- reads as "not measured" when it actually means "none" - the opposite conclusion.
--
-- Every count is coalesced to 0. The percentages keep their NULL only where the DENOMINATOR
-- is genuinely zero (a rep with nothing workable), because 0% would falsely imply a rep with
-- an empty book is fully covered.
-- =====================================================================================

create or replace view v_pipeline_state_wide as
with latest as (select max(snapshot_date) as d from fact_book_snapshot)
select
    coalesce(b.owner_name, b.owner_id)                                        as rep,
    coalesce(sum(b.contacts), 0)                                              as book_size,
    coalesce(sum(b.contacts) filter (where b.contact_stage = 'Fresh'), 0)        as fresh,
    coalesce(sum(b.contacts) filter (where b.contact_stage = 'Engaged'), 0)      as engaged,
    coalesce(sum(b.contacts) filter (where b.contact_stage = 'Prospect'), 0)     as prospect,
    coalesce(sum(b.contacts) filter (where b.contact_stage = 'Customer'), 0)     as customer,
    coalesce(sum(b.contacts) filter (where b.contact_stage = 'Disqualified'), 0) as disqualified,
    -- Anything outside the five canonical contact stages. Deliberately surfaced rather than
    -- folded away: the 2026-07-31 migration left zero legacy values, so a non-zero number
    -- here means the taxonomy has drifted again. On 2026-08-08 it was ~3,050 leads,
    -- including 2,746 at 'Future Prospect' - which is a COMPANY stage, not a contact one.
    coalesce(sum(b.contacts) filter (where b.contact_stage not in
        ('Fresh','Engaged','Prospect','Customer','Disqualified')), 0)         as other,
    coalesce(sum(b.contacts) filter (where b.contact_stage in
        ('Fresh','Engaged','Prospect')), 0)                                   as workable,
    round(100.0 * coalesce(sum(b.contacts) filter (where b.contact_stage = 'Fresh'), 0)
          / nullif(coalesce(sum(b.contacts) filter (where b.contact_stage in ('Fresh','Engaged','Prospect')), 0), 0), 1)
                                                                              as pct_untouched,
    round(100.0 * coalesce(sum(b.contacts) filter (where b.contact_stage = 'Prospect'), 0)
          / nullif(coalesce(sum(b.contacts) filter (where b.contact_stage in ('Fresh','Engaged','Prospect')), 0), 0), 1)
                                                                              as pct_at_prospect,
    max(b.snapshot_date)                                                      as as_of
from fact_book_snapshot b
join latest l on b.snapshot_date = l.d
group by 1;


-- --------------------------------------------------------------------------------------
-- v_stage_drift - contacts sitting on a non-canonical contact stage, by value and owner.
--
-- Exists because the snapshot found ~3,050 of them on 2026-08-08 against a migration that
-- had verified zero. Legacy values are invisible to a rep's UI filter and silently break
-- every stage-based report, so drift needs to be watchable rather than rediscovered.
--
-- Five values are EXPECTED and excluded: integrations still write them, and retiring them
-- was blocked on the integration owner moving them to Source/Segment.
-- --------------------------------------------------------------------------------------
create or replace view v_stage_drift as
with latest as (select max(snapshot_date) as d from fact_book_snapshot)
select
    b.contact_stage                    as non_canonical_stage,
    coalesce(b.owner_name, b.owner_id) as rep,
    b.contacts,
    b.snapshot_date
from fact_book_snapshot b
join latest l on b.snapshot_date = l.d
where b.contact_stage not in ('Fresh','Engaged','Prospect','Customer','Disqualified')
  and b.contact_stage not in ('Retargetedlead','RetargetedleadEMAIL','ReQualified By WhatsApp',
                              'FB Lead - Website','SaaS')
  and b.contacts > 0;
