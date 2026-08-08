-- =====================================================================================
-- TrueFan CRM - calling pipeline, row level security
-- 003 (rewritten 2026-08-08)
--
-- There is exactly ONE client: the Apps Script project, which holds the service role key in
-- Script Properties and never exposes it to a browser. Nothing renders client-side, so no
-- anon access is needed at all.
--
-- Deny by default: RLS is enabled on every table and no permissive policy is created.
-- service_role bypasses RLS in Supabase by design, so the pipeline keeps working while
-- anon and authenticated can read nothing. Stated explicitly so the absence of policies
-- below reads as intent rather than oversight.
-- =====================================================================================

alter table ref_canonical_value enable row level security;
alter table app_config          enable row level security;
alter table dim_rep             enable row level security;
alter table dim_contact         enable row level security;
alter table fact_call           enable row level security;
alter table fact_call_outcome   enable row level security;
alter table fact_stage_change   enable row level security;
alter table run_log             enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- If a rep-facing web dashboard is ever added, grant anon SELECT on the aggregate views
-- ONLY - never on fact_call, which carries phone numbers and recording URLs:
--
--   grant usage on schema public to anon;
--   grant select on v_rep_day, v_pivot_disposition, v_daily_totals to anon;
