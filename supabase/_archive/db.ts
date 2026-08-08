/**
 * Supabase persistence helpers shared by every edge function.
 *
 * All writes are upserts keyed on the LeadSquared activity GUID, which is what makes the
 * whole pipeline idempotent. A duplicate webhook, an LSQ retry, the hourly reconciler and
 * the nightly full sweep can all present the same activity and the row count does not move.
 * Exactly-once is a property of the schema, not something a caller has to be careful about.
 */

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import type { NormalizedRows } from "./normalize.ts";

export function adminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
  return createClient(url, key, { auth: { persistSession: false } });
}

/** Supabase caps a single request payload; large reconciles are chunked to stay under it. */
const CHUNK = 500;

async function upsertChunked(
  db: SupabaseClient,
  table: string,
  rows: Record<string, unknown>[],
  conflictKey: string,
): Promise<number> {
  let written = 0;
  for (let i = 0; i < rows.length; i += CHUNK) {
    const slice = rows.slice(i, i + CHUNK);
    const { error } = await db.from(table).upsert(slice, {
      onConflict: conflictKey,
      ignoreDuplicates: false,
    });
    if (error) throw new Error(`upsert ${table}: ${error.message}`);
    written += slice.length;
  }
  return written;
}

export interface PersistResult {
  calls: number;
  outcomes: number;
  stageChanges: number;
  opportunities: number;
  /** Rows that did not already exist. Drives the webhook-coverage metric. */
  newCalls: number;
}

/**
 * Persist a normalised trail.
 *
 * `newCalls` is measured by asking which call ids already existed BEFORE writing. That is
 * the input to webhook_coverage_pct: when the reconciler discovers calls the webhook never
 * delivered, the webhook is not firing for those events. Without measuring this, "the
 * automation has not fired yet" and "the automation will never fire" look identical - and
 * a live automation has already been observed failing to react to 17,011 bulk-updated
 * leads on this account.
 */
export async function persistRows(
  db: SupabaseClient,
  rows: NormalizedRows,
): Promise<PersistResult> {
  let newCalls = 0;

  if (rows.calls.length > 0) {
    const ids = rows.calls.map((r) => r.activity_id as string);
    const existing = new Set<string>();
    for (let i = 0; i < ids.length; i += CHUNK) {
      const { data, error } = await db
        .from("fact_call")
        .select("activity_id")
        .in("activity_id", ids.slice(i, i + CHUNK));
      if (error) throw new Error(`probe fact_call: ${error.message}`);
      for (const r of data ?? []) existing.add(r.activity_id as string);
    }
    newCalls = ids.filter((id) => !existing.has(id)).length;
  }

  const [calls, outcomes, stageChanges, opportunities] = await Promise.all([
    upsertChunked(db, "fact_call", rows.calls, "activity_id"),
    upsertChunked(db, "fact_call_outcome", rows.outcomes, "activity_id"),
    upsertChunked(db, "fact_stage_change", rows.stageChanges, "activity_id"),
    upsertChunked(db, "fact_opportunity_event", rows.opportunities, "activity_id"),
  ]);

  return { calls, outcomes, stageChanges, opportunities, newCalls };
}

export async function upsertContacts(
  db: SupabaseClient,
  contacts: Record<string, unknown>[],
): Promise<number> {
  const valid = contacts.filter((c) => c.prospect_id);
  return await upsertChunked(db, "dim_contact", valid, "prospect_id");
}

/**
 * Refresh the rep roster from live ownership rather than a hardcoded name list, so a newly
 * added rep appears in the report automatically instead of silently going unmeasured.
 * Targets and team structure are preserved - only identity and last-seen are touched.
 */
export async function upsertReps(
  db: SupabaseClient,
  leads: Record<string, any>[],
): Promise<number> {
  const byId = new Map<string, string>();
  for (const l of leads) {
    const id = String(l.OwnerId ?? "").trim();
    const name = String(l.OwnerIdName ?? "").trim();
    if (id && name) byId.set(id, name);
  }
  if (byId.size === 0) return 0;

  const rows = [...byId.entries()].map(([owner_id, lsq_name]) => ({
    owner_id,
    lsq_name,
    last_seen_at: new Date().toISOString(),
  }));
  return await upsertChunked(db, "dim_rep", rows, "owner_id");
}

export async function updateWatermarks(
  db: SupabaseClient,
  entries: { prospect_id: string; last_activity_date_max: string | null; last_activity_name: string | null }[],
): Promise<void> {
  if (entries.length === 0) return;
  const rows = entries.map((e) => ({ ...e, last_pulled_at: new Date().toISOString() }));
  await upsertChunked(db, "lead_watermark", rows, "prospect_id");
}

// ---------------------------------------------------------------------------------------
// app_config
// ---------------------------------------------------------------------------------------

export async function getConfig(db: SupabaseClient, key: string): Promise<string | null> {
  const { data, error } = await db.from("app_config").select("value").eq("key", key).maybeSingle();
  if (error) throw new Error(`getConfig ${key}: ${error.message}`);
  return data?.value ?? null;
}

export async function setConfig(db: SupabaseClient, key: string, value: string): Promise<void> {
  const { error } = await db
    .from("app_config")
    .upsert({ key, value, updated_at: new Date().toISOString() }, { onConflict: "key" });
  if (error) throw new Error(`setConfig ${key}: ${error.message}`);
}

// ---------------------------------------------------------------------------------------
// run_log
// ---------------------------------------------------------------------------------------

export async function startRun(db: SupabaseClient, runType: string): Promise<number> {
  const { data, error } = await db
    .from("run_log")
    .insert({ run_type: runType })
    .select("run_id")
    .single();
  if (error) throw new Error(`startRun: ${error.message}`);
  return data.run_id as number;
}

export async function finishRun(
  db: SupabaseClient,
  runId: number,
  patch: Record<string, unknown>,
): Promise<void> {
  const { error } = await db
    .from("run_log")
    .update({ finished_at: new Date().toISOString(), ...patch })
    .eq("run_id", runId);
  // A failed run_log update must not mask the real outcome of the run itself.
  if (error) console.error(`finishRun ${runId}: ${error.message}`);
}
