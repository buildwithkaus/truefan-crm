-- =====================================================================================
-- TrueFan CRM - 020: credit the contact owner, flag the non-owner (2026-08-11)
--
-- DECISION (Kaustubh, 2026-08-11): a call is credited to the CONTACT OWNER. Where somebody
-- other than the owner dialled, that is flagged as an exception rather than silently
-- reattributed.
--
-- WHAT WAS WRONG. call_rep() returned the literal '<inherited: not the owner>' for every
-- call where the dialler was not the current owner - 1,315 of 16,087 calls, 8.2%. That
-- placeholder collapsed two genuinely different situations into one unreadable bucket:
--
--   a) a PREVIOUS owner's historical call on a contact since reassigned - correctly not
--      credited to the new owner, and the reason 011 introduced the bucket at all;
--   b) a rep dialling a contact somebody else still owns - which under the ICP programme
--      (contacts parked under Kaustubh until assigned) is most of the 8.2%.
--
-- Under the new rule both resolve the same way - the owner is credited - and (b) becomes a
-- visible exception, because a rep working a contact they do not own is a process fault to
-- correct by assigning it, not a reporting problem to model around.
-- =====================================================================================


-- --------------------------------------------------------------------------------------
-- Team structure. Mohit Dev joins Team Achievers under Mayank Arora.
--
-- rep_name is the JOIN KEY and is matched on lower(btrim(...)) against the LSQ display name,
-- so it must be stored lowercased exactly as LSQ spells it. dim_team is keyed on the name
-- rather than the owner GUID because it is maintained by hand from the org chart - which is
-- the one place a name join is acceptable here, and only because a wrong match shows up as a
-- rep missing from a team rather than as leads moving between people.
-- --------------------------------------------------------------------------------------
insert into dim_team (rep_name, display_name, team, team_lead, is_lead, sort_order) values
    ('mohit dev', 'Mohit Dev', 'Team Achievers', 'Mayank Arora', false, 7)
on conflict (rep_name) do update
    set display_name = excluded.display_name,
        team         = excluded.team,
        team_lead    = excluded.team_lead,
        is_lead      = excluded.is_lead,
        sort_order   = excluded.sort_order;


-- --------------------------------------------------------------------------------------
-- call_rep - now always the contact owner.
--
-- The is_owner parameter is RETAINED although the body no longer reads it. Changing a
-- function's signature in PostgreSQL creates an overload rather than replacing it, so the
-- old three-argument version would survive and every existing view would keep resolving to
-- it - the change would appear to do nothing. Dropping it instead requires dropping every
-- dependent view first. Keeping the signature makes this a genuine one-statement swap that
-- v_contact_day, v_pivot_disposition and v_daily_totals all pick up automatically.
--
-- The placeholder stays LAST in the coalesce (gotcha 18): a non-null placeholder upstream
-- defeats every fallback below it, which is how 980 calls once collapsed onto one row.
-- --------------------------------------------------------------------------------------
create or replace function call_rep(is_owner boolean, owner_name text, actor_name text)
returns text language sql immutable as $$
    select coalesce(
        nullif(btrim(owner_name), ''),   -- the contact owner: who this call is credited to
        nullif(btrim(actor_name), ''),   -- only when the contact is not yet enriched
        '<unknown>'
    );
$$;

comment on function call_rep(boolean, text, text) is
    'Credits a call to the CONTACT OWNER (Kaustubh, 2026-08-11). Non-owner dials are not '
    'reattributed - they are flagged by v_non_owner_calls. The is_owner argument is vestigial '
    'and kept only so the signature, and therefore every dependent view, stays valid.';


-- --------------------------------------------------------------------------------------
-- v_non_owner_calls - the exception list: somebody dialled a contact they do not own.
--
-- Per CALL rather than per contact-day, because the fix is per contact (assign it to the
-- person actually working it) and a day-level roll-up hides which contact to act on.
--
-- Excludes calls on contacts not yet enriched: those have no known owner, so "not the owner"
-- cannot be asserted about them. Counting them here would report an enrichment lag as a
-- process violation - the same category error as reading a missing field as an empty one.
-- --------------------------------------------------------------------------------------
create or replace view v_non_owner_calls as
select
    c.call_date_ist                                   as report_date,
    coalesce(ct.owner_name, '<unassigned>')            as contact_owner,
    coalesce(r.lsq_name, c.actor_name, '<unknown>')    as dialled_by,
    c.prospect_id,
    ct.company_name,
    ct.full_name                                       as contact_name,
    ct.contact_stage,
    ct.source,
    count(*)                                           as calls,
    count(*) filter (where c.connected)                as connects,
    max(c.called_at_utc)                               as last_call_at
from fact_call c
join dim_contact ct on ct.prospect_id = c.prospect_id
left join dim_rep r on r.owner_id = c.actor_owner_id
where c.direction = 'outbound'
  and c.actor_owner_id is not null
  and ct.owner_id is not null
  and c.actor_owner_id <> ct.owner_id
group by 1, 2, 3, 4, 5, 6, 7, 8
order by report_date desc, calls desc;


-- --------------------------------------------------------------------------------------
-- v_non_owner_summary - the same thing rolled up, for a scorecard line.
-- --------------------------------------------------------------------------------------
create or replace view v_non_owner_summary as
select
    dialled_by,
    contact_owner,
    sum(calls)                    as calls,
    sum(connects)                 as connects,
    count(distinct prospect_id)   as contacts,
    max(last_call_at)             as last_call_at
from v_non_owner_calls
group by 1, 2
order by calls desc;


-- --------------------------------------------------------------------------------------
-- v_qc_attribution - REPLACED. The old check asserted the opposite rule.
--
-- It read "Inherited calls are not credited to a rep" and counted rows escaping the
-- '<inherited: not the owner>' bucket. Under the new rule that bucket does not exist, so the
-- check would have passed trivially forever while asserting nothing - worse than deleting
-- it, because it would still look like coverage.
--
-- Dropped rather than replaced in place: the column list changes, and CREATE OR REPLACE VIEW
-- cannot rename or reorder columns (ERROR 42P16, hit in 012 and again in 018).
-- --------------------------------------------------------------------------------------
drop view if exists v_qc_attribution;

create view v_qc_attribution as
select
    'every call is credited to a real rep, not a placeholder'::text as check_name,
    '0'::text                                                       as expected,
    (select count(*)::text from v_contact_day where rep = '<unknown>') as actual,
    case when (select count(*) from v_contact_day where rep = '<unknown>') = 0
         then 'PASS' else 'WARN' end                                as status,
    -- WARN not FAIL: '<unknown>' now means only "contact not yet enriched", which is a
    -- transient lag the enrichment job closes, not a defect in attribution.
    'v_contact_day vs dim_contact enrichment'::text                 as compared_against
union all
select
    'non-owner dialling is flagged, not hidden',
    (select count(distinct prospect_id)::text from v_call_enriched where not is_owner_call),
    (select coalesce(sum(calls), 0)::text from v_non_owner_calls),
    'INFO',
    -- Deliberately INFO. A non-zero count is a real process signal (a rep working a contact
    -- they do not own) and it is meant to be read and acted on, not to fail a build.
    'v_call_enriched vs v_non_owner_calls';

grant select on v_qc_attribution to anon, authenticated;

revoke all on v_non_owner_calls   from anon, authenticated;
revoke all on v_non_owner_summary from anon, authenticated;
