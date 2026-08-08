/**
 * ingest-webhook - the LeadSquared receiver.
 *
 * THE DESIGN DECISION THAT MATTERS: this function treats the webhook as a SIGNAL, not as
 * DATA. It records that something happened to a lead and returns. It does not parse call
 * fields out of the payload and it never calls the LeadSquared API inline.
 *
 * That single choice buys everything that makes the pipeline robust:
 *
 *   - The payload shape does not matter. LSQ's Custom Webhook body is not documented for
 *     this account, and anything carrying a lead identifier works. If LSQ later changes
 *     the shape, ingestion keeps working.
 *   - LSQ never waits on us. An inline API call would push the response past LSQ's timeout
 *     and trigger its retry logic, turning one call into a storm.
 *   - Bursts cannot breach the rate limit. 18 reps dialling at once would blow the
 *     account-wide 20-calls/5-sec cap with no central place to throttle; the queue worker
 *     is that place.
 *   - A missed webhook is latency, not data loss. The reconciler picks it up on the next
 *     pass, and the coverage metric records that it had to.
 *
 * Responds in well under 100ms. Always returns 200 for an authenticated request, even for
 * an unrecognised body - a non-2xx makes LSQ retry, and a retry storm against a payload we
 * simply do not understand yet helps nobody. The rejection is recorded instead.
 */

import { adminClient } from "../_shared/db.ts";

/**
 * Constant-time comparison. A plain === leaks the secret one byte at a time through
 * response timing, which is cheap to defend against and awkward to explain later.
 */
function secretMatches(provided: string, expected: string): boolean {
  if (provided.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < provided.length; i++) {
    diff |= provided.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Find a lead identifier anywhere in the payload.
 *
 * LSQ's Custom Webhook action lets the body be composed field by field in the UI, so the
 * key name depends on how the automation was configured. Rather than mandating one shape
 * and silently dropping everything else, this checks the plausible names at the top level
 * and then walks one level deep. Every rejection is logged with the full body, so a shape
 * that is not handled shows up as a row in webhook_log rather than as silence.
 */
const ID_KEYS = [
  "ProspectID", "ProspectId", "prospectId", "prospect_id",
  "LeadId", "leadId", "lead_id", "LeadID",
  "RelatedProspectId", "Id", "id",
];

const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function firstGuid(candidates: (string | null | undefined)[]): string | null {
  for (const c of candidates) {
    if (c && GUID_RE.test(c.trim())) return c.trim();
  }
  return null;
}

function extractProspectId(body: unknown): string | null {
  if (!body || typeof body !== "object") return null;

  // Activity webhooks are BATCHED: LSQ groups everything that happened in one minute and
  // posts them together, so the body can be an array. Take the first lead id found - the
  // worker fetches whole trails anyway, and a second lead in the same batch arrives as its
  // own queue row via its own entityId.
  if (Array.isArray(body)) {
    for (const item of body) {
      const found = extractProspectId(item);
      if (found) return found;
    }
    return null;
  }

  const obj = body as Record<string, unknown>;
  for (const k of ID_KEYS) {
    const v = obj[k];
    if (typeof v === "string" && GUID_RE.test(v.trim())) return v.trim();
  }
  for (const value of Object.values(obj)) {
    if (value && typeof value === "object") {
      const nested = extractProspectId(value);
      if (nested) return nested;
    }
  }
  return null;
}

/**
 * ALWAYS 200, in LeadSquared's recommended {"Status","StatusReason"} shape.
 *
 * This is LSQ's documented contract, and all three parts of it are load bearing:
 *   - "Your webhook code should always respond with 200 OK... Even if errors were
 *     encountered, 4xx or 5xx statuses should not be returned. Instead, you should return
 *     200 OK with the details of the error in the StatusReason node."
 *   - TEN CONSECUTIVE FAILURES DISABLE THE WEBHOOK, and re-enabling is manual. Returning
 *     401 to an attacker would therefore let anyone switch our ingestion off by posting
 *     garbage eleven times.
 *   - Verification is performed WITHOUT a payload, so a handler that requires a body never
 *     gets verified and the webhook never activates at all.
 *
 * The rejection is still recorded in webhook_log and surfaced in StatusReason, which shows
 * up in LSQ's own webhook history - so a misconfigured secret is diagnosable from their UI
 * rather than invisible.
 */
function ok(reason: string, extra: Record<string, unknown> = {}): Response {
  return new Response(
    JSON.stringify({ Status: reason ? "Error" : "Success", StatusReason: reason, ...extra }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

Deno.serve(async (req: Request) => {
  const startedAt = Date.now();
  const url = new URL(req.url);

  // HEAD is the handshake LSQ's best-practice guide asks endpoints to support.
  if (req.method === "HEAD") return new Response(null, { status: 200 });
  if (req.method === "GET") return ok("", { note: "endpoint alive" });
  if (req.method !== "POST") return ok(`unsupported method ${req.method}`);

  const expected = Deno.env.get("WEBHOOK_SECRET");
  if (!expected) {
    console.error("WEBHOOK_SECRET is not configured");
    return ok("endpoint not configured: WEBHOOK_SECRET missing");
  }

  const rawBody = await req.text();

  // Verification ping: LSQ checks the URL with no payload before activating the webhook.
  // Must answer 200 or the webhook never goes live.
  if (!rawBody && url.searchParams.size === 0) {
    return ok("", { note: "verification ping" });
  }

  // Header first; query string is the fallback in case custom headers are unavailable.
  const provided = req.headers.get("x-truefan-signature") ?? url.searchParams.get("secret") ?? "";
  if (!secretMatches(provided, expected)) {
    console.warn("ingest-webhook: bad or missing secret");
    return ok("unauthorized: bad or missing x-truefan-signature");
  }

  // NOTE: rawBody was already read above. A Request body is a one-shot stream - calling
  // req.text() a second time throws "Body already consumed".
  let body: unknown = null;
  let parseNote: string | null = null;
  try {
    body = rawBody ? JSON.parse(rawBody) : null;
  } catch (err) {
    parseNote = `unparseable body: ${String(err)}`;
  }

  // LeadSquared appends entityType, entityId and eventType to the webhook URL as QUERY
  // PARAMETERS - the lead identifier may never appear in the body at all. Checking only the
  // body would log every single webhook as "no lead identifier found" while returning 200,
  // which is the quietest possible way for this to fail.
  const prospectId = extractProspectId(body) ??
    firstGuid([
      url.searchParams.get("entityId"),
      url.searchParams.get("ProspectID"),
      url.searchParams.get("leadId"),
    ]);

  const db = adminClient();

  // Log every authenticated receipt verbatim, valid or not. While the payload shape is
  // still being learned this is the only evidence available, and a shape we fail to
  // recognise must be visible as a row rather than as an absence.
  const headers: Record<string, string> = {};
  for (const [k, v] of req.headers.entries()) {
    // Never persist the credential we just validated.
    if (k.toLowerCase() === "x-truefan-signature" || k.toLowerCase() === "authorization") continue;
    headers[k] = v;
  }

  try {
    await db.from("webhook_log").insert({
      headers,
      body: body as Record<string, unknown> | null,
      prospect_id: prospectId,
      valid: !!prospectId,
      reject_note: prospectId ? null : (parseNote ?? "no lead identifier found in payload"),
    });

    if (prospectId) {
      // Collapse repeats at the door: if this lead is already waiting, a second webhook
      // adds nothing - the worker fetches the full trail either way.
      const { data: pending } = await db
        .from("ingest_queue")
        .select("id")
        .eq("prospect_id", prospectId)
        .eq("status", "pending")
        .limit(1);

      if (!pending || pending.length === 0) {
        await db.from("ingest_queue").insert({ prospect_id: prospectId });
      }
    }
  } catch (err) {
    // Still 200. LSQ retrying because our database blipped would multiply the problem, and
    // the reconciler catches anything lost here within the hour.
    console.error("ingest-webhook persist failed:", err);
    return ok(`persist failed: ${String(err).slice(0, 200)}`);
  }

  return ok(prospectId ? "" : "no lead identifier in payload or query string", {
    queued: !!prospectId,
    ms: Date.now() - startedAt,
  });
});
