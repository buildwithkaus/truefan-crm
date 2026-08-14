-- =====================================================================================
-- TrueFan CRM - 031: cut the dead weight out of channel_bundle (2026-08-12)
--
-- THE SYMPTOM. The ICP and Disqualified tabs stopped populating. Neither has anything
-- wrong with it: icp_bundle answers in 2.0s with every key full (icp_funnel 172 rows,
-- disq_by_rep 23, disq_reasons 230). They went blank because channel_bundle was returning
-- HTTP 500 "canceling statement due to statement timeout" (57014) and the Apps Script
-- fetched the ICP bundle from INSIDE the channel bundle's try block, so the throw skipped
-- the ICP fetch entirely. That half is fixed in CallingPipeline.gs; this file fixes the
-- timeout that started it.
--
-- THE CAUSE. Measured per view, exactly as the bundle selects them:
--
--     v_rep_order          0.55s   rendered on Channels / ordering
--     v_channel_day        1.71s   rendered on Channels
--     v_channel_mix_rep    0.82s   rendered on Channels
--     v_book_health        0.69s   rendered on Book Health
--     v_non_owner_summary  0.64s   RENDERED BY NOTHING
--     v_qc_channel         0.52s   RENDERED BY NOTHING
--     v_qc_saturation      2.50s   RENDERED BY NOTHING
--     v_qc_movement        0.92s   RENDERED BY NOTHING
--     v_channel_unmapped   0.27s   RENDERED BY NOTHING
--                          -----
--                          8.62s   against an 8s statement timeout
--
-- Five of the nine key sets - 4.85s, more than half the bundle - are serialised into JSON
-- on every refresh and read by no tab. Enumerated, not assumed: every `B.<key>` in
-- CallingPipeline.gs was listed, and qc_channel, qc_saturation, qc_movement, unmapped and
-- non_owner appear in none of them. The QC tab reads `qc`, `boundaries` and `hygiene`,
-- which come from report_bundle. The v_qc_* views are still queried DIRECTLY by the
-- logging in qcToday-style helpers (sbSelect_), which this file does not touch - the views
-- all stay exactly as they are.
--
-- WHY NOT SPLIT AGAIN. 027 materialised the ICP base, 028 split the bundle in two, and it
-- was back over the timeout within a day. A third split would buy the same few seconds and
-- add a third round trip. Deleting work that feeds nothing is the only change here that
-- makes the bundle smaller instead of rearranging it: 8.62s -> 3.77s, better than 2x
-- headroom rather than the ~10% a split along the next seam would have bought.
--
-- WHAT THIS DOES NOT FIX. report_bundle answered in 8.47s on the same run - passing, but
-- on the same edge, and it has no dead weight to cut (all 17 of its key sets render). It
-- is the next thing to break and it will take most of the dashboard with it. Sizing that
-- one properly means materialising v_pivot / v_movement, not another split.
-- =====================================================================================

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
                         select * from v_book_health order by recoverable desc) t)
);
$$;

-- =====================================================================================
-- VERIFY. Both must return under the 8s timeout, and the key counts must be non-zero.
--
--   select channel_bundle('2026-08-01') -> json_array_length(x -> 'channel_day')
--   select icp_bundle('2026-08-01')     -> json_array_length(x -> 'icp_funnel')
--
-- From the repo, which also times them:
--   powershell.exe -File scripts\pipeline\00-probe-capabilities.ps1
-- or the direct check used to diagnose this:
--   POST {SUPABASE_URL}/rest/v1/rpc/channel_bundle  {"p_from":"2026-08-01"}
--
-- If a future tab needs the non-owner or QC-family datasets, add the key back to this
-- function AND render it in the same change - do not re-add it speculatively, which is how
-- it got here.
-- =====================================================================================
