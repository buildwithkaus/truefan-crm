-- =====================================================================================
-- TrueFan CRM - 021: rep ordering, and one bundled read for the new tabs (2026-08-11)
--
-- Two things the Sheet needs and cannot currently get:
--
--   1. A rep -> team ordering, so Prospects Daily can lay its columns out by team instead
--      of by descending volume (which is why the rep order looks arbitrary today).
--   2. The channel, book-health and non-owner datasets, for the tabs that do not exist yet.
--
-- WHY A SECOND RPC RATHER THAN EXTENDING report_bundle. Adding keys to report_bundle means
-- rewriting a 60-line function in full, and a transcription slip there breaks every existing
-- tab at once. This is additive: one more UrlFetch per refresh cycle - 48 calls a day against
-- a 20,000 quota that gotcha 27 says to guard, which is noise. If the two are ever merged,
-- merge them deliberately rather than as a side effect of adding a tab.
-- =====================================================================================


-- --------------------------------------------------------------------------------------
-- v_rep_order - the canonical left-to-right order for any rep-columned grid.
--
-- Team lead first within each team (is_lead desc), then the org-chart sort_order, then the
-- name. Reps absent from dim_team sort last under 'Unassigned' rather than vanishing: a
-- missing org-chart row must not silently drop a rep's column off a tab.
-- --------------------------------------------------------------------------------------
create or replace view v_rep_order as
select
    coalesce(t.display_name, r.lsq_name)                      as rep,
    coalesce(t.team, 'Unassigned')                            as team,
    case when t.team is null then 99
         when t.team = 'Team #ONE' then 1
         when t.team = 'Team Achievers' then 2
         else 50 end                                          as team_sort,
    coalesce(t.sort_order, 999)                               as rep_sort,
    coalesce(t.is_lead, false)                                as is_lead
from dim_rep r
left join dim_team t on lower(btrim(t.rep_name)) = lower(btrim(r.lsq_name))
where r.is_active
union
-- Org-chart rows with no matching dim_rep row yet (a new joiner who holds no contacts).
-- Included so the column order is stable from the day someone is added to the team, not
-- from the day they first get a lead.
select t.display_name, t.team,
       case when t.team = 'Team #ONE' then 1
            when t.team = 'Team Achievers' then 2
            else 50 end,
       t.sort_order, t.is_lead
from dim_team t
where not exists (
    select 1 from dim_rep r2
    where lower(btrim(r2.lsq_name)) = lower(btrim(t.rep_name))
);


-- --------------------------------------------------------------------------------------
-- channel_bundle - every new dataset in ONE response.
--
-- Same shape and reasoning as report_bundle: the tabs are small, and fourteen separate
-- PostgREST reads per refresh is what exhausted the UrlFetch quota by mid-afternoon and
-- killed the dashboard for a day.
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

    -- The two QC families for the new layers, so the QC tab can show them beside the
    -- existing checks rather than needing its own fetch.
    'qc_channel',    (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_channel) t),

    'qc_saturation', (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_saturation) t),

    'qc_movement',   (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_qc_movement) t),

    -- Unmapped channels: should be empty. Carried so a new activity type appearing in the
    -- account shows up on a tab rather than waiting for someone to run a query.
    'unmapped',      (select coalesce(json_agg(t), '[]'::json) from (
                         select * from v_channel_unmapped) t)
);
$$;

revoke all on v_rep_order from anon, authenticated;
