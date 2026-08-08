/**
 * LeadSquared API client for the edge functions.
 *
 * Every quirk encoded here was discovered the expensive way in this repo. The comments say
 * which, because each one is a silent-failure mode rather than an error you would notice.
 */

import { LEAD_COLUMNS, parseLsqUtc, toLsqTimestamp } from "./schema.ts";

export interface LsqConfig {
  host: string;
  accessKey: string;
  secretKey: string;
}

export function lsqConfigFromEnv(): LsqConfig {
  const host = Deno.env.get("LSQ_API_HOST");
  const accessKey = Deno.env.get("LSQ_ACCESS_KEY");
  const secretKey = Deno.env.get("LSQ_SECRET_KEY");
  if (!host || !accessKey || !secretKey) {
    throw new Error(
      "Missing LSQ_API_HOST / LSQ_ACCESS_KEY / LSQ_SECRET_KEY in edge function secrets",
    );
  }
  return { host: host.replace(/\/+$/, ""), accessKey, secretKey };
}

function url(cfg: LsqConfig, path: string, extra = ""): string {
  return `${cfg.host}/${path}?accessKey=${cfg.accessKey}&secretKey=${cfg.secretKey}${extra}`;
}

/**
 * Account-wide rate limiter.
 *
 * The LeadSquared limit is per ACCOUNT, not per script or per endpoint. Running two jobs
 * concurrently has already caused 23 silent write failures on this account. Documented as
 * 10 calls/5s on Pro; 20/5s has been observed. A conservative 12/5s leaves headroom for a
 * rep's UI traffic and any other job that happens to be running.
 */
class RateLimiter {
  private timestamps: number[] = [];
  constructor(private readonly maxCalls = 12, private readonly windowMs = 5_000) {}

  async take(): Promise<void> {
    for (;;) {
      const now = Date.now();
      this.timestamps = this.timestamps.filter((t) => now - t < this.windowMs);
      if (this.timestamps.length < this.maxCalls) {
        this.timestamps.push(now);
        return;
      }
      const waitMs = this.windowMs - (now - this.timestamps[0]) + 25;
      await new Promise((r) => setTimeout(r, waitMs));
    }
  }
}

export const limiter = new RateLimiter();

/** Calls made in this invocation. Written to run_log so budget use is visible per run. */
export let apiCallCount = 0;
export function resetApiCallCount(): void {
  apiCallCount = 0;
}

/**
 * Retry only genuinely transient conditions, classified by status rather than by message
 * text. Matching on wording is unreliable - an earlier version looked for "connection was
 * closed" and missed "An existing connection was FORCIBLY closed by the remote host".
 *
 * A real 4xx must fail fast: retrying a bad body shape or an invalid value into looking
 * like a flake is how a systematic bug gets absorbed instead of surfaced. Note LSQ returns
 * 500 for some malformed input, so 500 is retried but the ceiling is kept low.
 */
async function requestWithRetry(
  target: string,
  init: RequestInit,
  what: string,
  maxAttempts = 4,
): Promise<Response> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    await limiter.take();
    apiCallCount++;
    try {
      const res = await fetch(target, init);
      if (res.ok) return res;
      if (res.status === 429 || res.status >= 500) {
        lastErr = new Error(`${what}: HTTP ${res.status} ${await res.text().catch(() => "")}`);
      } else {
        throw new Error(`${what}: HTTP ${res.status} ${await res.text().catch(() => "")}`);
      }
    } catch (err) {
      // A thrown fetch is a transport failure (DNS, reset, timeout). api-in21 is an Akamai
      // edge host whose IP rotates, and resolution briefly fails outright during rotation.
      lastErr = err;
      if (String(err).includes("HTTP 4")) throw err;
    }
    if (attempt < maxAttempts) {
      await new Promise((r) => setTimeout(r, Math.min(8000, 2 ** attempt * 1000)));
    }
  }
  throw lastErr ?? new Error(`${what}: exhausted retries`);
}

/**
 * Fetch one lead's full activity trail. One API call per lead.
 *
 * There is no bulk Activity read endpoint on this account - eight names were probed on
 * 2026-07-28 and all returned 404 while a control call returned 200. Every activity-driven
 * job is therefore O(leads), which is why callers must narrow by watermark first and never
 * sweep the account.
 */
export async function getLeadActivities(
  cfg: LsqConfig,
  prospectId: string,
): Promise<Record<string, unknown>[]> {
  const res = await requestWithRetry(
    url(cfg, "ProspectActivity.svc/Retrieve", `&leadId=${encodeURIComponent(prospectId)}`),
    { method: "POST", headers: { "Content-Type": "application/json" } },
    `activity ${prospectId}`,
  );
  const body = await res.json();
  const acts = body?.ProspectActivities;
  return Array.isArray(acts) ? acts : [];
}

/**
 * Fetch one lead by id.
 *
 * Uses the dedicated Leads.GetById endpoint rather than a Leads.Get filter on a guessed
 * LookupName. That distinction matters here more than usual: Leads.Get silently IGNORES a
 * filter it does not understand and returns UNFILTERED rows, so a wrong lookup name would
 * hand back an arbitrary lead instead of erroring - and the pipeline would cheerfully
 * attribute one rep's calls to another lead's owner.
 */
export async function getLeadById(
  cfg: LsqConfig,
  prospectId: string,
): Promise<Record<string, unknown> | null> {
  const res = await requestWithRetry(
    url(cfg, "LeadManagement.svc/Leads.GetById", `&id=${encodeURIComponent(prospectId)}`),
    { method: "GET" },
    `Leads.GetById ${prospectId}`,
  );
  const rows = expandRows(await res.json());
  return rows.length > 0 ? rows[0] : null;
}

export interface LeadFilter {
  LookupName: string;
  LookupValue: string;
  SqlOperator: string;
}

/**
 * One page of Leads.Get.
 *
 * CRITICAL: Leads.Get silently IGNORES a `Query` wrapper - it returns UNFILTERED results
 * with no error, which once caused an entire "active in the last 2 months" analysis to run
 * against the whole historical database. The correct shape is a singular `Parameter`
 * object. (Company.Get is the opposite and does use `Query` - two different underlying
 * APIs, do not carry a pattern from one to the other.)
 */
export async function searchLeads(
  cfg: LsqConfig,
  filter: LeadFilter,
  pageIndex = 1,
  pageSize = 1000,
  columns: string = LEAD_COLUMNS,
): Promise<Record<string, unknown>[]> {
  const res = await requestWithRetry(
    url(cfg, "LeadManagement.svc/Leads.Get"),
    {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8" },
      body: JSON.stringify({
        Parameter: filter,
        Columns: { Include_CSV: columns },
        // Sorted by the IMMUTABLE CreatedOn. Paging over a column that changes while you
        // page (ProspectActivityDate_Max moves constantly) reshuffles rows between pages
        // and silently drops some.
        Sorting: { ColumnName: "CreatedOn", Direction: "1" },
        Paging: { PageIndex: pageIndex, PageSize: pageSize },
      }),
    },
    `Leads.Get page ${pageIndex}`,
  );
  const body = await res.json();
  return expandRows(body);
}

/**
 * Normalise a Leads.Get page.
 *
 * Invoke-RestMethod on the PowerShell side has been observed returning a page nested one
 * level deeper (Object[1] wrapping the real Object[1000]) for byte-identical requests,
 * decided per-process. Reading .length on that shape gives 1, so a paginating loop reads
 * "fewer than PageSize, stop" and reports a complete scan of the account after one page.
 * JSON.parse in Deno should not reproduce it, but the same defensive unwrap is applied
 * here because the failure mode is a silent undercount rather than an error.
 */
export function expandRows(body: unknown): Record<string, unknown>[] {
  if (!body) return [];
  const arr = Array.isArray(body) ? body : [body];
  const out: Record<string, unknown>[] = [];
  for (const item of arr) {
    if (!item) continue;
    if (Array.isArray(item)) {
      for (const sub of item) if (sub) out.push(sub as Record<string, unknown>);
    } else {
      out.push(item as Record<string, unknown>);
    }
  }
  return out;
}

/**
 * Page through every lead matching a filter.
 *
 * `expectZero` runs the negative control this repo requires before any new filter is
 * trusted. A filter that returns zero rows must be distrusted exactly as much as one
 * returning a suspicious non-zero count: believing two zero results without a control is
 * what silently skipped 20,076 leads (~23% of the database) during the Phase 5 backfill.
 */
export async function searchAllLeads(
  cfg: LsqConfig,
  filter: LeadFilter,
  opts: { maxPages?: number; columns?: string } = {},
): Promise<Record<string, unknown>[]> {
  const maxPages = opts.maxPages ?? 200;
  const all: Record<string, unknown>[] = [];
  for (let page = 1; page <= maxPages; page++) {
    const rows = await searchLeads(cfg, filter, page, 1000, opts.columns);
    all.push(...rows);
    if (rows.length < 1000) break;
  }
  return all;
}

/** Negative control. Returns true when the filter correctly matched nothing. */
export async function negativeControlPasses(cfg: LsqConfig, lookupName: string): Promise<boolean> {
  const rows = await searchLeads(
    cfg,
    { LookupName: lookupName, LookupValue: "ZZ_NoSuchValue_ZZ_9f3a", SqlOperator: "=" },
    1,
    10,
    "ProspectID",
  );
  return rows.length === 0;
}

/**
 * Build a UTC watermark string from a Date.
 *
 * LSQ stores and returns ModifiedOn / CreatedOn / ProspectActivityDate_Max in UTC while
 * this account operates in IST. A watermark built from a local clock is 5.5 hours in the
 * FUTURE and matches zero rows forever - proven live: the UTC-correct filter returned 352
 * rows where the local-time one returned 0. A polling job built on it looks perfectly
 * healthy and does nothing at all.
 */
export function watermark(d: Date): string {
  return toLsqTimestamp(d);
}

export { parseLsqUtc };
