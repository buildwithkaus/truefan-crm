-- =====================================================================================
-- TrueFan CRM - 029: classify two event types the full trail load discovered (2026-08-11)
--
-- The unmapped-channel view did its job. Loading 17,883 contacts' trails turned up two
-- EventCodes that are in NEITHER the ActivityTypes catalogue (58 types) nor any earlier
-- sample:
--
--   2001  EmailSent       1 touch,  first seen 2026-03-19
--   30    Sales Activity  4 touches, first seen 2024-06-23
--
-- CODE 2001 CORRECTS AN EARLIER FINDING OF MINE. The census concluded "there is no Email
-- Sent activity type - only engagement events (opened, clicked, bounced, responses)", based
-- on the ActivityTypes catalogue, which lists 17 email events and none of them a send.
-- EventCode 2001 'EmailSent' does exist in the trails; it is simply not a configurable
-- activity type, so it never appeared in the catalogue.
--
-- The practical conclusion barely moves - ONE send across 17,883 contacts means outbound
-- email is not happening - but the reason changes completely, and so does the fix. It is not
-- "email sends are structurally unmeasurable"; it is "email sends are measurable and nobody
-- is sending". The first needs a product decision, the second needs a rep decision.
--
-- This is the third time in this project that "the catalogue does not list it" has been
-- mistaken for "it does not exist" - after GetOpportunityDetails and the Webhooks feature.
-- The trail is the authority on what exists; the catalogue only says what is configurable.
--
-- Code 30 'Sales Activity' is the native LSQ type, distinct from the custom 205
-- '04. Sales Activity'. Four touches from 2024, i.e. dead - classified so it stops appearing
-- as unmapped rather than because anyone should report on it.
-- =====================================================================================

insert into ref_channel (event_code, event_name, channel, direction, actor_kind, is_touch, is_engagement, notes) values
    -- A real outbound send. is_touch = true: unlike an open or a click, this is outreach WE
    -- performed. It will read as ~0 because that is the truth about email here.
    ('2001', 'EmailSent', 'email', 'outbound', 'rep', true, true,
     'Outbound email send. NOT in the ActivityTypes catalogue - discovered in trails '
     || '2026-08-11, correcting the census finding that no send event exists.'),

    -- Native Sales Activity. A deal milestone, not a channel, so is_touch = false for the
    -- same reason 204/205/206 are (migration 026).
    ('30', 'Sales Activity', 'deal', '', 'system', false, false,
     'Native LSQ Sales Activity, distinct from custom 205. Dead since 2024.')
on conflict (event_code, event_name) do update
    set channel       = excluded.channel,
        direction     = excluded.direction,
        actor_kind    = excluded.actor_kind,
        is_touch      = excluded.is_touch,
        is_engagement = excluded.is_engagement,
        notes         = excluded.notes;
