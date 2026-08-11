-- =====================================================================================
-- TrueFan CRM - 024: the ICP datasets reach the Sheet (2026-08-11)
--
-- 023 built the ICP views but did not add them to channel_bundle, so nothing could render
-- them. This is that wiring.
--
-- The whole function is restated because PostgreSQL has no "add a key to a function" - a
-- create-or-replace must give the complete body. Every key from 021 and 022 is reproduced
-- below; dropping one here would blank a tab silently, since the writer would simply see
-- undefined and render an empty table rather than fail.
--
-- If a fourth key set is ever needed, split the bundle rather than retyping it a fourth
-- time - the transcription risk is now the largest thing about this function.
-- =====================================================================================

create or replace function channel_bundle(p_from date default '2026-08-01')
returns json
language sql stable as $$
select json_build_object(
    'generated_at',  now(),
    'from_date',     p_from,

    -- 021: ordering, channels, book health, non-owner, QC
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

    -- 022: disqualification
    'disq_by_rep',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_by_rep) t),
    'disq_reasons',  (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_reasons) t),
    'disq_totals',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_totals) t),
    'disq_movement', (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_disqualified_movement_rep
                         where report_date >= p_from) t),

    -- 024: ICP. Capped at 60 rows per cut - City and Source have long tails that are almost
    -- entirely suppressed cells, and shipping 1,500 'n<30' rows to a tab helps nobody.
    'icp_funnel',    (select coalesce(json_agg(t), '[]'::json) from (
                         select * from (
                             select *, row_number() over (partition by dimension
                                                          order by worked desc) as rn
                             from v_icp_funnel) x
                         where rn <= 60) t),
    'icp_scorecard', (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_icp_scorecard limit 60) t),
    'qc_icp',        (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_icp) t)
);
$$;
