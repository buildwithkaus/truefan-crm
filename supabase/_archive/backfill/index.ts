/**
 * backfill - bulk ingest of RAW activity JSON posted from PowerShell.
 *
 * The historical load runs from scripts/pipeline/backfill.ps1 rather than here, because it
 * reuses this repo's already-tested LSQ client (retry classification, the UTC watermark
 * helper, the nested-page unwrap) and because a multi-hour job spread across several nights
 * does not belong in a request-scoped edge function.
 *
 * But the PowerShell side does NOT normalise. It posts raw activity records to this
 * endpoint, which runs them through exactly the same normalizeTrail() the live webhook path
 * uses. A second normaliser written in PowerShell would drift from this one, and the drift
 * would be invisible - historical rows and live rows would quietly disagree about what a
 * connected call is, and nobody would notice until a number looked wrong months later.
 *
 * Idempotent, like every other path: keyed on the LSQ activity GUID.
 */

import { adminClient, finishRun, persistRows, startRun, updateWatermarks, upsertContacts } from "../_shared/db.ts";
import { emptyRows, normalizeContact, normalizeTrail, type NormalizedRows } from "../_shared/normalize.ts";
import { parseLsqUtc } from "../_shared/schema.ts";

interface BackfillLead {
  /** The lead record as returned by Leads.Get, used for dim_contact and owner attribution. */
  lead: Record<string, unknown>;
  /** That lead's full activity trail, verbatim from ProspectActivity.svc/Retrieve. */
  activities: Record<string, unknown>[];
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  // Service-role auth is enforced by Supabase before this handler runs, so no additional
  // secret is needed here - unlike ingest-webhook, which is called by a third party.
  const db = adminClient();

  let batch: BackfillLead[];
  try {
    const body = await req.json();
    batch = Array.isArray(body?.leads) ? body.leads : [];
  } catch (err) {
    return json({ ok: false, error: `unparseable body: ${err}` }, 400);
  }

  if (batch.length === 0) return json({ ok: true, leads: 0, note: "empty batch" });

  const runId = await startRun(db, "backfill");

  try {
    const all: NormalizedRows = emptyRows();
    const contacts: Record<string, unknown>[] = [];
    const watermarks: {
      prospect_id: string;
      last_activity_date_max: string | null;
      last_activity_name: string | null;
    }[] = [];
    const problems: string[] = [];

    for (const entry of batch) {
      const lead = entry.lead ?? {};
      const pid = String((lead as Record<string, unknown>).ProspectID ?? "").trim();
      if (!pid) {
        problems.push("lead with no ProspectID skipped");
        continue;
      }
      const ownerId = String((lead as Record<string, unknown>).OwnerId ?? "").trim() || null;

      const rows = normalizeTrail(entry.activities ?? [], pid, ownerId, "backfill");
      all.calls.push(...rows.calls);
      all.outcomes.push(...rows.outcomes);
      all.stageChanges.push(...rows.stageChanges);
      all.opportunities.push(...rows.opportunities);

      contacts.push(normalizeContact(lead as Record<string, unknown>));
      watermarks.push({
        prospect_id: pid,
        // ISO-8601 with an explicit zone - a bare LSQ timestamp string would be cast using
        // the session TimeZone rather than UTC.
        last_activity_date_max:
          parseLsqUtc((lead as Record<string, unknown>).ProspectActivityDate_Max)?.toISOString() ?? null,
        last_activity_name: String((lead as Record<string, unknown>).ProspectActivityName_Max ?? "") || null,
      });
    }

    const persisted = await persistRows(db, all);
    if (contacts.length > 0) await upsertContacts(db, contacts);
    await updateWatermarks(db, watermarks);
    await db.rpc("resolve_outcome_call_links");

    await finishRun(db, runId, {
      status: problems.length === 0 ? "ok" : "partial",
      // Backfill is complete only when the driving script says so, never when a single
      // batch succeeds. A partial history quoted as full coverage is exactly the failure
      // this flag exists to prevent.
      is_partial: true,
      leads_pulled: batch.length,
      rows_new: persisted.newCalls,
      api_calls: 0,
      notes: problems.length > 0 ? problems.slice(0, 20).join("; ") : null,
    });

    return json({
      ok: true,
      leads: batch.length,
      calls: persisted.calls,
      newCalls: persisted.newCalls,
      outcomes: persisted.outcomes,
      stageChanges: persisted.stageChanges,
      opportunities: persisted.opportunities,
      problems: problems.length,
    });
  } catch (err) {
    console.error("backfill failed:", err);
    await finishRun(db, runId, { status: "failed", notes: String(err).slice(0, 1000) });
    return json({ ok: false, error: String(err) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
