-- =====================================================================================
-- TrueFan CRM - 028: split the bundle (2026-08-11)
--
-- 027 materialised the ICP base and every view is now individually fast, measured
-- unbounded exactly as the bundle calls them:
--
--     v_channel_day 1.5s   v_icp_funnel 0.9s   v_book_health 1.0s   v_icp_scorecard 0.4s
--     v_channel_mix_rep 0.4s   v_disqualified_* 0.8s   v_non_owner_summary 0.2s
--
-- They still add up to more than the statement timeout when run as ONE statement, and
-- channel_bundle kept returning HTTP 500 at ~8.7s. Nothing here is slow; the bundle is
-- simply too big to be a single query.
--
-- 024 already carried the warning: "if a fourth key set is ever needed, split the bundle
-- rather than retyping it a fourth time". This is that split, one key set too late.
--
-- Two functions, each about half the work:
--   channel_bundle  channels, book health, non-owner, ordering, QC   - the operational tabs
--   icp_bundle      ICP funnel, scorecard, disqualification          - the analysis tabs
--
-- The cost is one extra UrlFetch per refresh: 48 a day against a 20,000 quota.
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
                         select * from v_channel_unmapped) t)
);
$$;


create or replace function icp_bundle(p_from date default '2026-08-01')
returns json
language sql stable as $$
select json_build_object(
    'generated_at',  now(),
    'from_date',     p_from,

    -- 60 rows per cut. City and Source have long tails that are almost entirely suppressed
    -- cells, and shipping 1,500 'n<30' rows to a tab helps nobody - it was also the largest
    -- single payload in the old bundle at 213 KB.
    'icp_funnel',    (select coalesce(json_agg(t), '[]'::json) from (
                         select * from (
                             select *, row_number() over (partition by dimension
                                                          order by worked desc) as rn
                             from v_icp_funnel) x
                         where rn <= 60) t),
    'icp_scorecard', (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_icp_scorecard limit 60) t),
    'qc_icp',        (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_icp) t),

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
