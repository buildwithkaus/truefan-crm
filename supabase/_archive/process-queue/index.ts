/**
 * process-queue - the worker that turns a webhook signal into facts.
 *
 * Runs every 20 seconds via pg_cron. Claims a batch of leads, fetches each one's full
 * activity trail from LeadSquared, normalises it and upserts. That 20-second tick is what
 * makes the system feel real-time: a rep hangs up, LSQ fires the webhook, and the next tick
 * has the call on the dashboard - typically under a minute end to end.
 *
 * A no-op when the queue is empty, so the cadence costs nothing on a quiet evening.
 *
 * Why the trail rather than the webhook payload: see the header of ingest-webhook. One
 * fetch returns the lead's ENTIRE history, so a single call captures the call itself, the
 * stage change the rep made straight afterwards, and any opportunity event - all correctly
 * keyed and idempotent.
 */

import { adminClient, finishRun, persistRows, startRun, updateWatermarks, upsertContacts } from "../_shared/db.ts";
import { apiCallCount, getLeadActivities, getLeadById, lsqConfigFromEnv, resetApiCallCount } from "../_shared/lsq.ts";
import { emptyRows, normalizeContact, normalizeTrail, type NormalizedRows } from "../_shared/normalize.ts";
import { parseLsqUtc } from "../_shared/schema.ts";

/**
 * Batch size. Each lead costs one LSQ call at ~12 calls/5s, so 40 leads is roughly 17
 * seconds of work - comfortably inside the 20-second tick, and if it does overrun, the
 * next tick's SKIP LOCKED claim simply picks up different rows.
 */
const BATCH_SIZE = 40;

Deno.serve(async () => {
  const db = adminClient();
  resetApiCallCount();

  const { data: claimed, error: claimErr } = await db.rpc("claim_queue_batch", {
    batch_size: BATCH_SIZE,
  });
  if (claimErr) {
    console.error("claim_queue_batch failed:", claimErr.message);
    return json({ ok: false, error: claimErr.message }, 500);
  }
  if (!claimed || claimed.length === 0) {
    return json({ ok: true, claimed: 0, note: "queue empty" });
  }

  const runId = await startRun(db, "webhook_batch");
  const cfg = lsqConfigFromEnv();

  const all: NormalizedRows = emptyRows();
  const contacts: Record<string, unknown>[] = [];
  const watermarks: {
    prospect_id: string;
    last_activity_date_max: string | null;
    last_activity_name: string | null;
  }[] = [];

  const doneIds: number[] = [];
  const failed: { id: number; error: string }[] = [];

  // Collapse repeat webhooks for the same lead. Three calls to one contact in a minute
  // produce three queue rows, but a single trail fetch returns all three calls - so fetch
  // once per DISTINCT lead and mark every queue row for that lead done from that one result.
  // The RPC cannot do this itself: Postgres rejects DISTINCT ON together with FOR UPDATE.
  const byLead = new Map<string, number[]>();
  for (const row of claimed as { id: number; prospect_id: string }[]) {
    const ids = byLead.get(row.prospect_id) ?? [];
    ids.push(row.id);
    byLead.set(row.prospect_id, ids);
  }

  for (const [prospectId, queueIds] of byLead) {
    try {
      // The lead record is needed for two reasons: dim_contact's current state, and the
      // CURRENT owner id, without which is_owner_call cannot be decided. A call is credited
      // to a rep only when the dialler is also the present owner - contacts get reassigned
      // constantly, and skipping this test hands a rep the previous owner's whole history.
      const lead = await getLeadById(cfg, prospectId);
      const ownerId = lead ? String(lead.OwnerId ?? "").trim() || null : null;

      const activities = await getLeadActivities(cfg, prospectId);
      const rows = normalizeTrail(activities, prospectId, ownerId, "webhook");

      all.calls.push(...rows.calls);
      all.outcomes.push(...rows.outcomes);
      all.stageChanges.push(...rows.stageChanges);
      all.opportunities.push(...rows.opportunities);
      all.skipped.push(...rows.skipped);

      if (lead) {
        contacts.push(normalizeContact(lead));
        watermarks.push({
          prospect_id: prospectId,
          // Normalised to ISO-8601 with an explicit zone. Handing Postgres a bare
          // "2026-08-08 06:10:00" makes the cast depend on the session TimeZone - exactly
          // how a 5.5-hour skew gets in without anything appearing to fail.
          last_activity_date_max: parseLsqUtc(lead.ProspectActivityDate_Max)?.toISOString() ?? null,
          last_activity_name: String(lead.ProspectActivityName_Max ?? "") || null,
        });
      }
      for (const id of queueIds) doneIds.push(id);
    } catch (err) {
      // One bad lead must not abandon the rest of the batch. attempts was already
      // incremented at claim time, so a lead that keeps failing reaches 'dead' after five
      // tries instead of being retried forever.
      console.error(`lead ${prospectId} failed:`, err);
      for (const id of queueIds) failed.push({ id, error: String(err).slice(0, 500) });
    }
  }

  let persisted;
  try {
    persisted = await persistRows(db, all);
    if (contacts.length > 0) await upsertContacts(db, contacts);
    await updateWatermarks(db, watermarks);
    await db.rpc("resolve_outcome_call_links");
  } catch (err) {
    console.error("persist failed:", err);
    // Leave the claimed rows alone. requeue-stuck releases anything held over 5 minutes,
    // so the batch is retried rather than silently lost.
    await finishRun(db, runId, {
      status: "failed",
      api_calls: apiCallCount,
      notes: String(err).slice(0, 1000),
    });
    return json({ ok: false, error: String(err) }, 500);
  }

  if (doneIds.length > 0) {
    await db
      .from("ingest_queue")
      .update({ status: "done", processed_at: new Date().toISOString() })
      .in("id", doneIds);
  }
  for (const f of failed) {
    await db.from("ingest_queue").update({ status: "error", last_error: f.error }).eq("id", f.id);
  }

  await finishRun(db, runId, {
    status: failed.length === 0 ? "ok" : "partial",
    is_partial: failed.length > 0,
    candidates: claimed.length,
    leads_pulled: doneIds.length,
    api_calls: apiCallCount,
    rows_new: persisted.newCalls,
    notes: failed.length > 0 ? `${failed.length} lead(s) failed` : null,
  });

  return json({
    ok: true,
    claimed: claimed.length,
    processed: doneIds.length,
    failed: failed.length,
    calls: persisted.calls,
    newCalls: persisted.newCalls,
    stageChanges: persisted.stageChanges,
    apiCalls: apiCallCount,
  });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
