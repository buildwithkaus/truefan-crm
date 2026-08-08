-- =====================================================================================
-- TrueFan CRM - real-time calling activity pipeline
-- 005: RPCs the edge functions need that PostgREST cannot express
-- =====================================================================================

-- --------------------------------------------------------------------------------------
-- claim_queue_batch - atomically hand a worker a batch of leads to process.
--
-- FOR UPDATE SKIP LOCKED is the whole point. The queue worker runs every 20 seconds, and a
-- slow tick will still be running when the next one starts. Without SKIP LOCKED, two
-- overlapping workers would claim the same rows and fetch the same trails twice - harmless
-- for correctness (every write is an idempotent upsert) but a straight waste of an API
-- budget that is capped at 10,000 calls a day.
--
-- NOTE: deduplication of repeat webhooks for the same lead happens in the CALLER, not here.
-- Postgres rejects SELECT DISTINCT ON ... FOR UPDATE ("FOR UPDATE is not allowed with
-- DISTINCT clause"), so this claims every pending row and returns them all; process-queue
-- groups them by prospect_id, fetches each lead's trail once, and then marks every claimed
-- id done. That ordering matters - marking only the deduplicated ids would strand the
-- duplicates in 'claimed' until the stuck-row sweeper released them, in a loop.
-- --------------------------------------------------------------------------------------
create or replace function claim_queue_batch(batch_size integer default 50)
returns table (id bigint, prospect_id text)
language plpgsql
security definer
set search_path = public
as $$
begin
    return query
    with candidate as (
        select q.id
        from ingest_queue q
        where q.status = 'pending'
        order by q.received_at asc
        limit batch_size
        for update skip locked
    )
    update ingest_queue u
       set status     = 'claimed',
           claimed_at = now(),
           attempts   = u.attempts + 1
      from candidate c
     where u.id = c.id
    returning u.id, u.prospect_id;
end;
$$;

revoke all on function claim_queue_batch(integer) from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- resolve_outcome_call_links - tie each EventCode 203 outcome form to the call it describes
--
-- The form is logged separately from the telephony record, so the two are joined by
-- proximity: the nearest preceding call to the same lead within four hours. Four hours is
-- deliberately generous - reps frequently log a batch of forms at the end of a session
-- rather than after each call, and a tight window would leave most notes orphaned from the
-- call they belong to.
--
-- Only unlinked rows are considered, so this is cheap to run after every ingest.
-- --------------------------------------------------------------------------------------
create or replace function resolve_outcome_call_links()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    touched integer;
begin
    with pairs as (
        select o.activity_id as outcome_id,
               (select c.activity_id
                  from fact_call c
                 where c.prospect_id = o.prospect_id
                   and c.called_at_utc <= o.logged_at_utc
                   and c.called_at_utc > o.logged_at_utc - interval '4 hours'
                 order by c.called_at_utc desc
                 limit 1) as call_id
          from fact_call_outcome o
         where o.matched_call_activity_id is null
    )
    update fact_call_outcome o
       set matched_call_activity_id = p.call_id
      from pairs p
     where o.activity_id = p.outcome_id
       and p.call_id is not null;

    get diagnostics touched = row_count;
    return touched;
end;
$$;

revoke all on function resolve_outcome_call_links() from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- leads_needing_pull - which of these leads actually has new activity?
--
-- The reconciler hands over every lead the candidate scan returned, along with the live
-- ProspectActivityDate_Max for each. This returns only those whose timestamp has genuinely
-- advanced past what is already stored, plus any lead never seen before.
--
-- This is what makes an hourly cadence affordable. Cost becomes "leads with new activity
-- since the last run" rather than "leads touched today", and on a quiet hour that is close
-- to zero. Without it, every hourly pass would re-pull the whole day's working set.
--
-- skip_activity_name is the Callkaro optimisation, and it lives HERE rather than in the
-- caller for a specific reason: the decision needs the watermark, which only this query
-- has. A lead is skipped only when its last activity is the AI dialler AND we have seen it
-- before. A lead we have never seen is ALWAYS pulled, whatever its last activity, so first
-- contact never loses history. Filtering on the name in the edge function - before this
-- join - would have silently dropped brand-new leads.
--
-- The end-of-day pass passes null here and applies no name filter at all, because a rep
-- call followed by an AI touch on the same lead makes "last activity" read as AI.
-- --------------------------------------------------------------------------------------
create or replace function leads_needing_pull(
    candidates jsonb,
    skip_activity_name text default null
)
returns table (prospect_id text)
language sql
security definer
set search_path = public
as $$
    select c.prospect_id
    from jsonb_to_recordset(candidates)
         as c(prospect_id text, activity_date_max timestamptz, activity_name text)
    left join lead_watermark w on w.prospect_id = c.prospect_id
    where
        -- Never seen before: always pull, regardless of activity name.
        w.prospect_id is null
        or (
            -- Seen before: pull only if the activity clock actually advanced ...
            (
                w.last_activity_date_max is null
                or c.activity_date_max is null
                or c.activity_date_max > w.last_activity_date_max
            )
            -- ... and the new activity is not just the AI dialler.
            and (
                skip_activity_name is null
                or c.activity_name is null
                or c.activity_name <> skip_activity_name
            )
        );
$$;

revoke all on function leads_needing_pull(jsonb, text) from anon, authenticated;
