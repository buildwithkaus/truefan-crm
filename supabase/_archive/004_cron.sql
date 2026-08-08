-- =====================================================================================
-- TrueFan CRM - real-time calling activity pipeline
-- 004: scheduling
--
-- pg_cron runs in UTC. This account operates in IST (UTC+5:30), so every schedule below
-- carries its IST equivalent in a comment. Getting this wrong is the single easiest way to
-- build a job that runs at 03:00 in the morning and looks like it is working.
--
-- BEFORE APPLYING: set the two settings at the bottom of this file. The cron jobs call the
-- edge functions over HTTP via pg_net and need the project URL and the service role key.
-- =====================================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- --------------------------------------------------------------------------------------
-- Helper: invoke an edge function. Keeps the key out of every individual job definition,
-- so rotating it is one UPDATE rather than four schedule rewrites.
-- --------------------------------------------------------------------------------------
create or replace function invoke_edge_function(fn_name text, payload jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    base_url text;
    svc_key  text;
    req_id   bigint;
begin
    select value into base_url from app_config where key = 'supabase_url';
    select value into svc_key  from app_config where key = 'service_role_key';

    if base_url is null or svc_key is null then
        raise exception 'invoke_edge_function: supabase_url / service_role_key missing from app_config';
    end if;

    select net.http_post(
        url     := base_url || '/functions/v1/' || fn_name,
        headers := jsonb_build_object(
                       'Content-Type',  'application/json',
                       'Authorization', 'Bearer ' || svc_key
                   ),
        body    := payload,
        timeout_milliseconds := 120000
    ) into req_id;

    return req_id;
end;
$$;

revoke all on function invoke_edge_function(text, jsonb) from anon, authenticated;


-- --------------------------------------------------------------------------------------
-- 1. Queue worker. Every 20 seconds.
--
-- This is what makes the pipeline feel real-time: a webhook lands, and within one tick the
-- lead's trail is fetched and the dashboard moves. The worker is a no-op when the queue is
-- empty, so a 20-second cadence costs nothing on a quiet evening.
--
-- It claims rows with FOR UPDATE SKIP LOCKED, so overlapping ticks cannot double-process.
-- --------------------------------------------------------------------------------------
select cron.schedule(
    'truefan-process-queue',
    '20 seconds',
    $$ select invoke_edge_function('process-queue'); $$
);

-- --------------------------------------------------------------------------------------
-- 2. Hourly reconcile. 03:30-14:30 UTC = 09:00-20:00 IST, business hours.
--
-- The safety net, not the mechanism. It uses the ProspectActivityName_Max optimisation to
-- skip leads whose only new activity is the Callkaro AI dialler (41% of all lead-touch
-- volume), which is what keeps an hourly cadence inside the API budget.
-- --------------------------------------------------------------------------------------
select cron.schedule(
    'truefan-reconcile-hourly',
    '30 3-14 * * *',
    $$ select invoke_edge_function('reconcile', '{"mode":"hourly"}'::jsonb); $$
);

-- --------------------------------------------------------------------------------------
-- 3. End-of-day reconcile. 15:30 UTC = 21:00 IST.
--
-- Deliberately does NOT apply the activity-name optimisation. The hourly pass can miss a
-- rep call that was followed by an AI dialler touch on the same lead within the same hour -
-- the lead's "last activity" then reads as AI and the hourly pass skips it. This pass
-- re-sweeps every lead touched during the day with no name filter, so the end-of-day
-- numbers are complete even when the fast path was not.
--
-- This is also the run whose figures are quoted. The hourly numbers are for steering.
-- --------------------------------------------------------------------------------------
select cron.schedule(
    'truefan-reconcile-eod',
    '30 15 * * *',
    $$ select invoke_edge_function('reconcile', '{"mode":"eod"}'::jsonb); $$
);

-- --------------------------------------------------------------------------------------
-- 4. Retry stuck queue rows. Every 10 minutes.
-- A row claimed but never completed means the worker died mid-flight. Release anything
-- held longer than 5 minutes so it is picked up again rather than sitting invisible.
-- --------------------------------------------------------------------------------------
select cron.schedule(
    'truefan-requeue-stuck',
    '*/10 * * * *',
    $$
    update ingest_queue
       set status = 'pending', claimed_at = null
     where status = 'claimed'
       and claimed_at < now() - interval '5 minutes'
       and attempts < 5;

    update ingest_queue
       set status = 'dead'
     where status in ('pending','claimed','error')
       and attempts >= 5;
    $$
);

-- --------------------------------------------------------------------------------------
-- 5. Retention. 03:00 UTC = 08:30 IST.
-- webhook_log is a debugging aid, not a record of account activity - the facts are the
-- record. Two weeks is enough to diagnose an ingestion problem.
-- --------------------------------------------------------------------------------------
select cron.schedule(
    'truefan-prune-logs',
    '0 3 * * *',
    $$
    delete from webhook_log  where received_at < now() - interval '14 days';
    delete from ingest_queue where processed_at is not null and processed_at < now() - interval '7 days';
    delete from run_log      where started_at < now() - interval '180 days';
    $$
);


-- =====================================================================================
-- REQUIRED SETUP - run these two statements once, with real values, before the jobs work.
-- Kept in app_config rather than as database settings so the service key can be rotated
-- without a migration.
--
--   insert into app_config (key, value) values
--       ('supabase_url',     'https://<project-ref>.supabase.co'),
--       ('service_role_key', '<service-role-key>')
--   on conflict (key) do update set value = excluded.value, updated_at = now();
--
-- app_config already has RLS enabled with no anon policy, so these are not readable from a
-- browser. Confirm with:  select * from app_config;  using the anon key - it must error or
-- return zero rows.
-- =====================================================================================
