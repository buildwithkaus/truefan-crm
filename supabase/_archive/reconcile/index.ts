/**
 * reconcile - the safety net, and the instrument that tells us whether the webhook works.
 *
 * Two modes:
 *
 *   hourly  09:00-20:00 IST. Narrow and cheap. Skips leads whose only new activity is the
 *           Callkaro AI dialler (41% of all lead-touch volume), which is what keeps an
 *           hourly cadence inside the API budget.
 *
 *   eod     21:00 IST. Wide and complete. NO activity-name filter, because the hourly
 *           optimisation has a known blind spot: a rep call followed by an AI dialler touch
 *           on the same lead in the same hour makes that lead's "last activity" read as AI,
 *           and the hourly pass skips it. This pass re-sweeps the whole day. Its numbers
 *           are the ones to quote; the hourly numbers are for steering during the day.
 *
 * WHY THIS EXISTS AT ALL. Native LSQ automations have been observed NOT firing on API and
 * bulk writes on this account - a live automation failed to react to 17,011 leads moved by
 * a bulk job. EventCode 22 records are written by the telephony integration, not by a rep
 * clicking in the UI, so the webhook may never fire for exactly the events that matter
 * most. That is unknown and cannot be assumed either way.
 *
 * So every call this pass discovers that the webhook never delivered is counted, and
 * webhook_coverage_pct is written to run_log. Without that number, "the automation has not
 * fired yet" and "the automation will never fire" look identical.
 */

import {
  adminClient,
  finishRun,
  getConfig,
  persistRows,
  setConfig,
  startRun,
  updateWatermarks,
  upsertContacts,
  upsertReps,
} from "../_shared/db.ts";
import {
  apiCallCount,
  getLeadActivities,
  lsqConfigFromEnv,
  negativeControlPasses,
  resetApiCallCount,
  searchAllLeads,
  watermark,
} from "../_shared/lsq.ts";
import { emptyRows, normalizeContact, normalizeTrail, type NormalizedRows } from "../_shared/normalize.ts";
import { AI_ACTIVITY_NAME, IST_OFFSET_MINUTES, LEAD_COLUMNS, parseLsqUtc } from "../_shared/schema.ts";

/**
 * Hard ceiling on LSQ calls per run. The account cap is 10,000/day; an hourly pass that
 * somehow matched the whole account would otherwise consume the entire day's budget in one
 * go and leave the pipeline blind until midnight. Hitting this marks the run partial rather
 * than letting it report as complete.
 */
const MAX_API_CALLS = 2500;

Deno.serve(async (req: Request) => {
  const db = adminClient();
  resetApiCallCount();

  let mode = "hourly";
  try {
    const body = await req.json();
    if (body?.mode === "eod") mode = "eod";
  } catch {
    // No body is fine - default to hourly.
  }

  const runId = await startRun(db, `reconcile_${mode}`);
  const cfg = lsqConfigFromEnv();

  try {
    // -------------------------------------------------------------------------------
    // Negative control, before trusting the filter.
    //
    // A filter returning ZERO rows must be distrusted exactly as much as one returning a
    // suspicious non-zero count. Believing two zero results without a control is what
    // silently skipped 20,076 leads - 23% of the database - during an earlier migration,
    // and it was only caught because a separate full enumeration failed to reconcile.
    // -------------------------------------------------------------------------------
    if (!(await negativeControlPasses(cfg, "ProspectActivityDate_Max"))) {
      throw new Error(
        "NEGATIVE CONTROL FAILED on ProspectActivityDate_Max - the filter is being ignored and results cannot be trusted",
      );
    }

    // -------------------------------------------------------------------------------
    // Watermark. Always UTC.
    //
    // LSQ stores timestamps in UTC while this account operates in IST. A watermark built
    // from a local clock is 5.5 hours in the FUTURE and matches zero rows forever - the job
    // looks healthy and does nothing at all. Proven live: 352 rows vs 0.
    // -------------------------------------------------------------------------------
    let sinceUtc: Date;
    if (mode === "eod") {
      // Midnight IST today, expressed in UTC.
      const nowIst = new Date(Date.now() + IST_OFFSET_MINUTES * 60_000);
      const istMidnight = Date.UTC(
        nowIst.getUTCFullYear(),
        nowIst.getUTCMonth(),
        nowIst.getUTCDate(),
      );
      sinceUtc = new Date(istMidnight - IST_OFFSET_MINUTES * 60_000);
    } else {
      const stored = await getConfig(db, "reconcile_watermark_utc");
      const parsed = stored ? parseLsqUtc(stored) : null;
      const ninetyMinAgo = new Date(Date.now() - 90 * 60_000);
      // Overlap the previous run by design: a lead whose activity landed mid-scan would
      // otherwise fall between two windows and never be pulled. Upserts make the overlap free.
      sinceUtc = parsed && parsed > ninetyMinAgo ? new Date(parsed.getTime() - 10 * 60_000) : ninetyMinAgo;
    }
    const runStartedAt = new Date();

    // -------------------------------------------------------------------------------
    // Candidate scan. Cheap - one call per 1,000 leads.
    // -------------------------------------------------------------------------------
    const candidates = await searchAllLeads(
      cfg,
      {
        LookupName: "ProspectActivityDate_Max",
        LookupValue: watermark(sinceUtc),
        SqlOperator: ">",
      },
      { columns: LEAD_COLUMNS },
    );

    // Roster refresh from live ownership, so a newly added rep is measured automatically
    // rather than silently missing from every report until someone notices.
    await upsertReps(db, candidates);

    // -------------------------------------------------------------------------------
    // Narrow to leads worth fetching a trail for.
    //
    // Both tests happen inside leads_needing_pull, not here, because both need the stored
    // watermark: "has the activity clock advanced" and "is this only an AI-dialler touch
    // on a lead we already know". Filtering on the activity name in this function - before
    // that join - would silently drop leads being seen for the first time whose most recent
    // activity happens to be the AI dialler, losing their entire history.
    // -------------------------------------------------------------------------------
    // Timestamps are normalised to ISO-8601 with an explicit zone before crossing into SQL.
    // Handing Postgres a bare "2026-08-08 06:10:00" makes the timestamptz cast depend on the
    // session TimeZone - which is exactly how a silent 5.5-hour skew gets in.
    const payload = candidates.map((l) => ({
      prospect_id: String(l.ProspectID ?? ""),
      activity_date_max: parseLsqUtc(l.ProspectActivityDate_Max)?.toISOString() ?? null,
      activity_name: String(l.ProspectActivityName_Max ?? "") || null,
    }));

    const { data: needed, error: needErr } = await db.rpc("leads_needing_pull", {
      candidates: payload,
      // The end-of-day pass deliberately applies no name filter - see this file's header.
      skip_activity_name: mode === "hourly" ? AI_ACTIVITY_NAME : null,
    });
    if (needErr) throw new Error(`leads_needing_pull: ${needErr.message}`);

    const needIds = new Set((needed ?? []).map((r: { prospect_id: string }) => r.prospect_id));
    const toPull = candidates.filter((l) => needIds.has(String(l.ProspectID ?? "")));

    const aiSkipped = mode === "hourly"
      ? candidates.filter((l) =>
        String(l.ProspectActivityName_Max ?? "").trim() === AI_ACTIVITY_NAME &&
        !needIds.has(String(l.ProspectID ?? ""))
      ).length
      : 0;

    // -------------------------------------------------------------------------------
    // Pull trails.
    // -------------------------------------------------------------------------------
    const all: NormalizedRows = emptyRows();
    const contacts: Record<string, unknown>[] = [];
    const watermarks: {
      prospect_id: string;
      last_activity_date_max: string | null;
      last_activity_name: string | null;
    }[] = [];

    let pulled = 0;
    let failedPulls = 0;
    let budgetExhausted = false;

    for (const lead of toPull) {
      if (apiCallCount >= MAX_API_CALLS) {
        budgetExhausted = true;
        break;
      }
      const pid = String(lead.ProspectID ?? "");
      if (!pid) continue;

      try {
        const activities = await getLeadActivities(cfg, pid);
        const ownerId = String(lead.OwnerId ?? "").trim() || null;
        const rows = normalizeTrail(activities, pid, ownerId, "reconcile");

        all.calls.push(...rows.calls);
        all.outcomes.push(...rows.outcomes);
        all.stageChanges.push(...rows.stageChanges);
        all.opportunities.push(...rows.opportunities);

        contacts.push(normalizeContact(lead));
        watermarks.push({
          prospect_id: pid,
          last_activity_date_max: parseLsqUtc(lead.ProspectActivityDate_Max)?.toISOString() ?? null,
          last_activity_name: String(lead.ProspectActivityName_Max ?? "") || null,
        });
        pulled++;
      } catch (err) {
        console.error(`reconcile: lead ${pid} failed:`, err);
        failedPulls++;
      }
    }

    const persisted = await persistRows(db, all);
    if (contacts.length > 0) await upsertContacts(db, contacts);
    await updateWatermarks(db, watermarks);
    await db.rpc("resolve_outcome_call_links");

    // -------------------------------------------------------------------------------
    // The coverage metric. This is the load-bearing output of this function.
    //
    // Every call row that was NEW here is a call the webhook never delivered. If coverage
    // sits near 100%, the webhook is doing its job and this pass is genuinely just a net.
    // If it collapses, the webhook is not firing on telephony-created activities and the
    // reconciler is quietly carrying the entire system - which would otherwise be invisible
    // because the reports would still look completely normal.
    // -------------------------------------------------------------------------------
    const totalCalls = all.calls.length;
    const missed = persisted.newCalls;
    const coverage = totalCalls > 0
      ? Math.round((100 * (totalCalls - missed) / totalCalls) * 100) / 100
      : null;

    // Only advance the watermark on a clean run. Advancing past a partial scan would make
    // the skipped leads permanently invisible - the gap would never be revisited.
    const clean = !budgetExhausted && failedPulls === 0;
    if (clean && mode === "hourly") {
      await setConfig(db, "reconcile_watermark_utc", watermark(runStartedAt));
    }

    await finishRun(db, runId, {
      status: clean ? "ok" : "partial",
      is_partial: !clean,
      candidates: candidates.length,
      leads_pulled: pulled,
      api_calls: apiCallCount,
      rows_new: missed,
      rows_missed_by_webhook: missed,
      webhook_coverage_pct: coverage,
      notes: [
        `mode=${mode}`,
        `since=${watermark(sinceUtc)}`,
        `ai_skipped=${aiSkipped}`,
        `needed_pull=${toPull.length}`,
        failedPulls > 0 ? `failed_pulls=${failedPulls}` : null,
        budgetExhausted ? `API BUDGET CEILING HIT at ${MAX_API_CALLS} - run is INCOMPLETE` : null,
      ].filter(Boolean).join(" "),
    });

    return json({
      ok: true,
      mode,
      candidates: candidates.length,
      aiSkipped,
      neededPull: toPull.length,
      pulled,
      failedPulls,
      callsSeen: totalCalls,
      callsMissedByWebhook: missed,
      webhookCoveragePct: coverage,
      apiCalls: apiCallCount,
      isPartial: !clean,
    });
  } catch (err) {
    console.error("reconcile failed:", err);
    await finishRun(db, runId, {
      status: "failed",
      api_calls: apiCallCount,
      notes: String(err).slice(0, 1000),
    });
    return json({ ok: false, error: String(err) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
