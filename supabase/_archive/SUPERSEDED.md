# Superseded - do not deploy

This Supabase implementation of the calling pipeline was **replaced on 2026-08-08** by
`appsscript/CallingPipeline.gs`. See `docs/CALLING_PIPELINE.md`.

## Why it was replaced

It was designed around an assumption that turned out to be false: that the LeadSquared
webhook would carry only a lead identifier, requiring a callback to LSQ for every event.
That callback needs throttling (the rate limit is account-wide), throttling needs a queue,
and a queue needs a backend - hence Postgres, edge functions and pg_cron.

The repo's own notes pointed that way: `memory/07` recorded the Webhooks API as "not used in
this project", and `LSQ_AUTOMATION_SPEC.md` said webhooks needed "a hosted endpoint which
this project does not have". Nobody had found LSQ's native Webhooks feature.

Capturing one real payload disproved it. The `Lead Activity Creation` webhook delivers the
entire activity - id, lead, actor, timestamp, status, duration, note blob - so recording a
call costs zero API calls. With no callback there is no queue, and with no queue there is no
reason for a backend. For 18 reps and ~2,000 calls a day, Apps Script and a Sheet are the
right size.

## Why it is kept

- **`migrations/002_views.sql` is the clearest written specification of every metric** in the
  system: stage-at-call-time, the eight hygiene flags, the compliance score. The Apps Script
  implementation follows it. Read it when you need to know exactly what a number means.
- **`functions/_shared/normalize_test.ts` (22 passing tests)** documents the parsing traps -
  duplicate keys in the note blob, EventCode 3002 having no `ActivityFields`, 203 and 22
  colliding on `mx_Custom_2/3`. Those apply to any implementation.
- **`functions/ingest-webhook/index.ts` can read request headers.** Apps Script cannot, so
  the live receiver authenticates with a query-string secret instead. If that ever needs to
  be a real credential, this is the ready-made replacement.
- It is the fallback if Sheets is outgrown.

## Do not

Run `supabase db push` or deploy these functions. Nothing points at them, and the
`004_cron.sql` schedules would start making LSQ API calls on a timer for no reason.
