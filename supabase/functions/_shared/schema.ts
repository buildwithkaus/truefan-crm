/**
 * Canonical vocabulary and activity-type constants.
 *
 * Mirrors scripts/lib/schema.ps1 and scripts/lib/activity.ps1. Every string here was read
 * from live data or from the live dropdown, never copied from a doc page - hand-written
 * field-value strings in this codebase have twice caused silent mass data loss (a guessed
 * "Invalid/Junk" instead of the real "Invalid/ Junk" skipped 20,076 leads).
 */

// ---------------------------------------------------------------------------------------
// Activity event codes. Always branch on these - never on the activity's `Type` field,
// which is unreliable: a Callkaro outbound AI call reports Type="Inbound".
// ---------------------------------------------------------------------------------------
export const EVENT = {
  CALL_INBOUND: "21",
  CALL_OUTBOUND: "22",
  CALL_FORM: "203", // "01. Phone Call/ Follow Up" - the rep-facing outcome form
  STAGE_CHANGE: "3002",
  OPPORTUNITY: "12000",
  OPP_CAPTURED: "33",
  AI_CALL: "208", // Callkaro. Excluded everywhere - see below.
} as const;

/**
 * Event codes this pipeline stores. EventCode 208 is deliberately absent.
 *
 * Callkaro is a background AI dialler, not a person. It appeared on 40 of 971 assigned
 * contacts, 14 of which no rep had ever called - including it would manufacture coverage
 * nobody worked. It is also 41% of all lead-touch volume (2,405 of 5,823 leads over two
 * days, measured 2026-08-08), which makes excluding it the largest single saving on the
 * per-lead API budget.
 */
export const STORED_EVENT_CODES: string[] = [
  EVENT.CALL_INBOUND,
  EVENT.CALL_OUTBOUND,
  EVENT.CALL_FORM,
  EVENT.STAGE_CHANGE,
  EVENT.OPPORTUNITY,
  EVENT.OPP_CAPTURED,
];

/**
 * The exact live strings held in the Lead field ProspectActivityName_Max for a
 * human-placed or human-received call. Enumerated 2026-08-08: negative control returned
 * zero rows, and the value tally reconciled 5,823/5,823 against the scanned total.
 *
 * Used to narrow the hourly reconciler's candidate set. NOT used by the end-of-day pass -
 * "last activity" is a single value, so a rep call followed by an AI dialler touch on the
 * same lead reads as AI and would be skipped.
 */
export const CALL_ACTIVITY_NAMES = [
  "Outbound Phone Call Activity",
  "Inbound Phone Call Activity",
  "01. Phone Call/ Follow Up",
] as const;

export const AI_ACTIVITY_NAME = "AI Phone Call / Follow Up";

// ---------------------------------------------------------------------------------------
// Lead columns pulled on every candidate scan. Kept in one place because Leads.Get silently
// returns fewer columns rather than erroring when a name is wrong.
// ---------------------------------------------------------------------------------------
export const LEAD_COLUMNS = [
  "ProspectID",
  "FirstName",
  "LastName",
  "EmailAddress",
  "Phone",
  "Company",
  "RelatedCompanyId",
  "OwnerId",
  "OwnerIdName",
  "ProspectStage",
  "mx_Call_Disposition",
  "mx_Disqualification_Reason",
  "mx_Disqualification_Category",
  "mx_Segment",
  "Source",
  "IsPrimaryContact",
  "Notes",
  "ProspectActivityDate_Max",
  "ProspectActivityName_Max",
  "ModifiedOn",
].join(",");

// ---------------------------------------------------------------------------------------
// Canonical values. Also seeded into ref_canonical_value so SQL can check membership; kept
// here too for edge-function-side validation and for tests.
// ---------------------------------------------------------------------------------------
/**
 * Six values. 'Future Prospect' was originally modelled as a Company stage only, so the
 * 2026-07-31 restructure treated it as a legacy CONTACT value and mapped it to Disqualified.
 * It is a real contact stage (Kaustubh, 2026-08-12): "right business, no need right now" -
 * a live revisit list rather than a closed account.
 *
 * Reading it as legacy moved 2,729 contacts to Disqualified on 2026-08-11, which had to be
 * rolled back the next day after reps noticed their accounts had gone.
 */
export const CONTACT_STAGES = [
  "Fresh",
  "Engaged",
  "Prospect",
  "Customer",
  "Disqualified",
  "Future Prospect",
] as const;

/** The six live mx_Call_Disposition dropdown options, read from the field on 2026-07-31. */
export const CALL_DISPOSITIONS = [
  "RNR",
  "Did Not Pick",
  "Call me Later",
  "Switched Off/Not Reachable",
  "Wrong Number",
  "Follow Up",
] as const;

/**
 * Dispositions that assert nobody was reached. When one of these sits on a contact whose
 * every logged attempt connected, the field contradicts the telephony log - the largest
 * data-quality problem in the funnel, and worse than a blank, because a blank reads as
 * "not filled in" while this reads as a real outcome and flows into reporting as one.
 */
export const NO_CONTACT_DISPOSITIONS = [
  "Did Not Pick",
  "RNR",
  "Switched Off/Not Reachable",
] as const;

// ---------------------------------------------------------------------------------------
// Time. India is UTC+5:30 year-round with no daylight saving, so a fixed offset is exact.
// Avoids depending on a timezone database whose identifier differs across platforms.
// ---------------------------------------------------------------------------------------
export const IST_OFFSET_MINUTES = 330;

/** UTC Date -> the calendar date in IST, as YYYY-MM-DD. */
export function istDateString(utc: Date): string {
  return new Date(utc.getTime() + IST_OFFSET_MINUTES * 60_000)
    .toISOString()
    .slice(0, 10);
}

/**
 * Parse an LSQ timestamp as UTC.
 *
 * LSQ returns two formats on the same record: the activity-level CreatedOn is
 * "2026-07-31 05:33:50" while ActivityFields.CreatedOn is "7/31/2026 5:33:50 AM". Neither
 * carries a zone, and both are UTC. Returns null rather than an Invalid Date so a caller
 * cannot accidentally persist NaN as a timestamp.
 */
export function parseLsqUtc(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  const s = String(value).trim();
  if (!s) return null;

  // "2026-07-31 05:33:50" / "2026-07-31T05:33:50"
  const iso = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(s);
  if (iso) {
    const [, y, mo, d, h, mi, sec] = iso;
    return new Date(Date.UTC(+y, +mo - 1, +d, +h, +mi, +(sec ?? 0)));
  }

  // "7/31/2026 5:33:50 AM"
  const us = /^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s*(AM|PM)$/i.exec(s);
  if (us) {
    const [, mo, d, y, h, mi, sec, ap] = us;
    let hour = +h % 12;
    if (ap.toUpperCase() === "PM") hour += 12;
    return new Date(Date.UTC(+y, +mo - 1, +d, hour, +mi, +sec));
  }

  const fallback = new Date(s.includes("T") ? s : s.replace(" ", "T") + "Z");
  return isNaN(fallback.getTime()) ? null : fallback;
}

/** Format a Date as the "yyyy-MM-dd HH:mm:ss" UTC string LSQ filters expect. */
export function toLsqTimestamp(d: Date): string {
  return d.toISOString().slice(0, 19).replace("T", " ");
}
