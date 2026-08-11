-- =====================================================================================
-- TrueFan CRM - 026: 'deal' and 'payment' are not channels (2026-08-11)
--
-- The Channels tab listed 'deal' alongside phone and whatsapp. It is not a channel - it is
-- an object. The cause was EventCode 204 "02. Contract" carrying is_touch = true, which is
-- the flag v_channel_day filters on; 12000, 33, 205 and 206 were already false and never
-- appeared.
--
-- Sending a contract IS outreach, so the original reasoning was not silly. But the channel
-- that carried it is unknown - almost certainly email, possibly in person - and inventing a
-- channel called 'deal' to hold it is worse than leaving it out. A channel mix is a claim
-- about HOW a contact was reached, and 'deal' answers a different question.
--
-- The rows are still stored and still classified; they simply stop being counted as channel
-- outreach. If contract-sends ever need to appear in a channel view, the honest fix is to
-- learn the medium, not to relabel the object.
-- =====================================================================================

update ref_channel
   set is_touch = false,
       notes = coalesce(notes || ' | ', '')
               || 'Deal/payment milestone, not a channel: excluded from channel mix 2026-08-11'
 where channel in ('deal', 'payment')
   and is_touch;


-- --------------------------------------------------------------------------------------
-- Guard it. A future ref_channel edit could reintroduce the same confusion, and it would
-- show up only as an odd-looking row on a tab that nobody double-checks.
-- --------------------------------------------------------------------------------------
create or replace view v_qc_channel as
select 'every fact_call row appears exactly once in v_touch_all'::text as check_name,
       (select count(*)::text from fact_call)                          as expected,
       (select count(*)::text from v_touch_all where source_table = 'fact_call') as actual,
       case when (select count(*) from fact_call)
               = (select count(*) from v_touch_all where source_table = 'fact_call')
            then 'PASS' else 'FAIL' end                                as status,
       'fact_call vs v_touch_all union arm'::text                      as compared_against
union all
select 'every fact_touch row appears exactly once in v_touch_all',
       (select count(*)::text from fact_touch),
       (select count(*)::text from v_touch_all where source_table = 'fact_touch'),
       case when (select count(*) from fact_touch)
               = (select count(*) from v_touch_all where source_table = 'fact_touch')
            then 'PASS' else 'FAIL' end,
       'fact_touch vs v_touch_all union arm'
union all
select 'no call rows leaked into fact_touch',
       '0',
       (select count(*)::text from fact_touch where event_code in ('21','22')),
       case when (select count(*) from fact_touch where event_code in ('21','22')) = 0
            then 'PASS' else 'FAIL' end,
       'fact_touch check constraint'
union all
select 'every stored event type is classified',
       '0',
       (select coalesce(sum(touches), 0)::text from v_channel_unmapped),
       case when (select coalesce(sum(touches), 0) from v_channel_unmapped) = 0
            then 'PASS' else 'WARN' end,
       'fact_touch left join ref_channel'
union all
select 'ref_channel is populated',
       '>0',
       (select count(*)::text from ref_channel),
       case when (select count(*) from ref_channel) > 0 then 'PASS' else 'FAIL' end,
       'ref_channel row count'
union all
select 'no non-channel is counted as outreach',
       '0',
       (select count(*)::text from ref_channel
         where channel in ('deal','payment','system') and is_touch),
       case when (select count(*) from ref_channel
                   where channel in ('deal','payment','system') and is_touch) = 0
            then 'PASS' else 'FAIL' end,
       -- A deal, a payment and a lead-assignment are things that HAPPENED to a contact, not
       -- ways we reached one. Counting them inflates the channel mix with events nobody
       -- performed as outreach.
       'ref_channel is_touch vs channel kind';

revoke all on v_qc_channel from anon, authenticated;
