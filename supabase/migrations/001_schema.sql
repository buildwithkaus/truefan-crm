-- =====================================================================================
-- TrueFan CRM - calling pipeline, tables
-- 001 (rewritten 2026-08-08 for the Apps-Script-ingest design)
--
-- Supabase is used here as nothing more than "Postgres with a REST API". There are no edge
-- functions, no queue and no cron: the LeadSquared webhook payload carries the whole
-- activity, so Apps Script normalises it and upserts straight to PostgREST. The earlier
-- design's queue and worker existed only to survive a callback-per-event that is not needed.
--
-- WHY A DATABASE AT ALL, when the ingest is a Google Sheet away:
--   * Volume. ~420 calls a day measured 2026-08-08. Apps Script rebuilds its reports by
--     reading EVERY row each cycle, so a Sheet-backed store stops finishing inside the
--     6-minute execution limit at roughly 50-100k rows - about two months.
--   * History. Month-over-month comparison needs the whole year, and the LSQ API cannot
--     re-derive it later: there is no bulk activity read, so unrecorded history is gone.
--
-- Grain: one row per LeadSquared ACTIVITY, keyed on the activity's own id. Every ingest
-- path upserts, so a duplicate webhook, a re-run backfill and a reconciler pass all
-- converge on the same row. Exactly-once is a property of the schema, not of the caller.
-- =====================================================================================

-- --------------------------------------------------------------------------------------
-- Canonical dropdown values. DATA, not hardcoded into views, so locking or extending an
-- option list is an INSERT rather than a migration.
--
-- LSQ stores a dropdown value that is not in the dropdown instead of rejecting it. It reads
-- back correctly over the API, so every write-side check passes - but a rep cannot select
-- it and no UI filter offers it. That silently made 61,919 leads unfilterable once.
-- --------------------------------------------------------------------------------------
create table if not exists ref_canonical_value (
    field     text not null,
    value     text not null,
    is_active boolean not null default true,
    primary key (field, value)
);

insert into ref_canonical_value (field, value) values
    ('contact_stage','Fresh'), ('contact_stage','Engaged'), ('contact_stage','Prospect'),
    ('contact_stage','Customer'), ('contact_stage','Disqualified'),

    -- The six live mx_Call_Disposition options, read from the dropdown 2026-07-31.
    ('call_disposition','RNR'),
    ('call_disposition','Did Not Pick'),
    ('call_disposition','Call me Later'),
    ('call_disposition','Switched Off/Not Reachable'),
    ('call_disposition','Wrong Number'),
    ('call_disposition','Follow Up'),

    ('disqualification_reason','Not Interested - No Reason Stated'),
    ('disqualification_reason','Invalid / Not a Business'),
    ('disqualification_reason','Low Budget / Pricing Mismatch'),
    ('disqualification_reason','Invalid Contact Data'),
    ('disqualification_reason','Just Enquiring - No Intent'),
    ('disqualification_reason','No Current Requirement (Timing)'),
    ('disqualification_reason','No Celebrity Requirement'),
    ('disqualification_reason','Does Not Want AI'),
    ('disqualification_reason','Out of ICP - B2B Not Relevant'),
    ('disqualification_reason','Went Dark After First Conversation'),
    ('disqualification_reason','Celebrity Supply Gap'),
    ('disqualification_reason','Legacy - Unclassified'),
    ('disqualification_reason','Conflict')
on conflict (field, value) do nothing;

create table if not exists app_config (
    key text primary key,
    value text not null,
    updated_at timestamptz not null default now()
);
insert into app_config (key, value) values
    ('note_capture_enabled','false'),
    ('backfill_through_date','')
on conflict (key) do nothing;


-- --------------------------------------------------------------------------------------
-- Dimensions
-- --------------------------------------------------------------------------------------

-- Keyed on the LSQ OwnerId GUID, never on a display name. Reference data once attached the
-- name "Piyush Das Pattnaik" to Rishi Saraswat's real GUID and pulled 2,360 of his leads
-- into a migration. Names also differ across systems ("Shubham Kumar Tak" vs "Subham Tak").
create table if not exists dim_rep (
    owner_id        text primary key,
    lsq_name        text not null,
    sheet_name      text,
    team            text,
    team_lead       text,
    call_target     integer,
    prospect_target integer,
    is_active       boolean not null default true,
    last_seen_at    timestamptz not null default now()
);

create table if not exists dim_contact (
    prospect_id             text primary key,
    company_name            text,
    full_name               text,
    phone                   text,
    owner_id                text,
    owner_name              text,
    contact_stage           text,
    call_disposition        text,
    disqualification_reason text,
    segment                 text,
    source                  text,
    last_refreshed_at       timestamptz not null default now()
);
create index if not exists idx_contact_owner on dim_contact (owner_id);


-- --------------------------------------------------------------------------------------
-- Facts. PK is the LSQ activity id => every ingest path is idempotent.
--
-- Timestamps are stored twice deliberately. LSQ returns UTC; the business runs on IST
-- (UTC+5:30, no daylight saving, so a fixed interval is exact). Every "which day" question
-- uses the IST column: a call at 23:45 IST is 18:15 UTC on the SAME date, but one at
-- 02:00 IST is 20:30 UTC on the PREVIOUS date - reporting on the UTC date misfiles exactly
-- the late-evening calls a daily scorecard is judged on.
-- --------------------------------------------------------------------------------------
create table if not exists fact_call (
    activity_id    text primary key,
    prospect_id    text not null,
    event_code     text not null check (event_code in ('21','22')),
    direction      text not null check (direction in ('inbound','outbound')),

    called_at_utc  timestamptz not null,
    called_at_ist  timestamp generated always as
                       ((called_at_utc at time zone 'UTC') + interval '5 hours 30 minutes') stored,
    call_date_ist  date generated always as
                       (((called_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date) stored,

    actor_owner_id text,          -- who dialled (webhook CreatedBy)
    actor_name     text,          -- Caller from the note blob; survives an unenriched lead
    status         text,          -- Answered | NotAnswered | ...
    duration_sec   integer not null default 0,
    connected      boolean not null default false,   -- duration_sec > 0
    call_note      text,          -- CallNotes from the note blob; empty until capture lands
    recording_url  text,

    ingest_source  text not null default 'webhook'
                       check (ingest_source in ('webhook','backfill','reconcile')),
    ingested_at    timestamptz not null default now()
);
create index if not exists idx_call_date_actor on fact_call (call_date_ist, actor_owner_id);
create index if not exists idx_call_prospect   on fact_call (prospect_id, called_at_utc desc);

-- EventCode 203, "01. Phone Call/ Follow Up" - the rep-facing outcome form and the leading
-- candidate destination for notes. Believed dead until 2026-08-08, when an enumeration
-- found it as the last activity on 806 leads account-wide.
--
-- WARNING: 203 and 22 use mx_Custom_2 / mx_Custom_3 for COMPLETELY different things
-- (203: Connected Outcome / Next Step. 22: Start Time / Call Duration). Branch on event
-- code before reading any custom field.
create table if not exists fact_call_outcome (
    activity_id           text primary key,
    prospect_id           text not null,
    logged_at_utc         timestamptz not null,
    log_date_ist          date generated always as
                              (((logged_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date) stored,
    owner_id              text,
    status                text,   -- Connected | Not Connected
    connected_outcome     text,   -- mx_Custom_2
    not_connected_outcome text,   -- mx_Custom_1
    next_step             text,   -- mx_Custom_3
    note                  text,   -- ActivityEvent_Note
    ingest_source         text not null default 'webhook',
    ingested_at           timestamptz not null default now()
);
create index if not exists idx_outcome_prospect on fact_call_outcome (prospect_id, logged_at_utc desc);

-- EventCode 3002. NO ActivityFields at all - everything is in the Data[] array as
-- PreviousStage / CurrentStage / CreatedBy / Comment, and CreatedBy is a display NAME.
--
-- This table is what makes stage-at-call-time real. It is populated wholesale by the
-- backfill (trails carry every historical 3002) and maintained by the Lead Stage Change
-- webhook thereafter.
--
-- CRITICAL: a 3002 exists on nearly every lead because the 2026-07-30/31 migration
-- bulk-wrote ProspectStage. "Has a stage change" is NOT evidence a rep did anything - only
-- a change at or after that rep's call counts, and views exclude anything before 1 August.
create table if not exists fact_stage_change (
    activity_id     text primary key,
    prospect_id     text not null,
    changed_at_utc  timestamptz not null,
    change_date_ist date generated always as
                        (((changed_at_utc at time zone 'UTC') + interval '5 hours 30 minutes')::date) stored,
    previous_stage  text,
    current_stage   text,
    changed_by_name text,
    ingest_source   text not null default 'backfill',
    ingested_at     timestamptz not null default now()
);
create index if not exists idx_stage_prospect on fact_stage_change (prospect_id, changed_at_utc desc);
create index if not exists idx_stage_date     on fact_stage_change (change_date_ist);

-- One row per backfill or reconcile run. Deliberately minimal - the webhook path does not
-- log runs, because a row per inbound webhook would be noise, not an audit trail.
create table if not exists run_log (
    run_id      bigserial primary key,
    run_type    text not null,
    started_at  timestamptz not null default now(),
    finished_at timestamptz,
    status      text,
    rows_written integer,
    api_calls   integer,
    is_partial  boolean not null default false,
    notes       text
);
