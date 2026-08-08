/**
 * Activity -> fact row normalisation. THE single source of truth.
 *
 * Every ingestion path goes through this file: the live webhook worker, the hourly and
 * end-of-day reconcilers, and the historical backfill (which posts RAW activity JSON from
 * PowerShell precisely so it travels this same code path). A second implementation in
 * PowerShell was deliberately not written - two normalisers would drift, and the drift
 * would be invisible until a number looked wrong months later.
 *
 * The record shape below is not inferred from documentation. It was captured from a live
 * EventCode 22 activity on 2026-08-08; the primary key in particular was genuinely unknown
 * until it was probed.
 */

import { EVENT, istDateString, parseLsqUtc } from "./schema.ts";

// ---------------------------------------------------------------------------------------
// Field readers
// ---------------------------------------------------------------------------------------

type Activity = Record<string, any>;

/**
 * The activity primary key. Confirmed live as the top-level `Id` (a GUID);
 * ActivityFields.ProspectActivityAutoId is a second, integer identifier on the same record.
 *
 * Throws rather than generating a surrogate. A missing key would otherwise become a silent
 * duplicate-row bug: every re-ingest of the same activity would insert again, quietly
 * inflating every call count in the system.
 */
export function activityId(a: Activity): string {
  const id = String(a?.Id ?? "").trim();
  if (id) return id;
  const auto = String(a?.ActivityFields?.ProspectActivityAutoId ?? "").trim();
  if (auto) return `auto:${auto}`;
  throw new Error(
    `Activity has neither Id nor ProspectActivityAutoId (EventCode=${a?.EventCode}, lead=${a?.RelatedProspectId})`,
  );
}

/** Read a key from the Data[] array of {Key,Value} pairs. Present on both 3002 and 22. */
export function dataValue(a: Activity, key: string): string {
  const arr = a?.Data;
  if (!Array.isArray(arr)) return "";
  for (const d of arr) {
    if (String(d?.Key) === key) return String(d?.Value ?? "");
  }
  return "";
}

/**
 * ActivityEvent_Note is a "{=}"/"{next}" delimited key-value blob, NOT JSON:
 *
 *   Caller{=}Vikhyat Verma{next}UserId{=}{next}UserId{=}4057ed7a-...{next}Duration{=}64
 *   {next}Status{=}Answered{next}CallNotes{=}{next}ResourceURL{=}{next}StartTime{=}...
 *
 * Keys: Caller, UserId, Duration, Status, CallNotes, ResourceURL, StartTime, Tag,
 * DisplayNumber, EventNote, SourceData.
 *
 * DUPLICATE KEYS ARE REAL. The blob above - captured verbatim on 2026-08-08 - contains
 * UserId twice, the first empty. The original PowerShell parser this replaces matched
 * non-greedily and returned the FIRST occurrence, so it read "" for UserId on every record
 * while appearing to work. This scans all occurrences and returns the last non-empty one.
 */
export function noteValue(blob: unknown, key: string): string {
  const s = String(blob ?? "");
  if (!s) return "";
  const re = new RegExp(`${key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\{=\\}(.*?)(?=\\{next\\}|$)`, "g");
  let found = "";
  for (const m of s.matchAll(re)) {
    const v = (m[1] ?? "").trim();
    if (v) found = v;
  }
  return found;
}

function intOf(v: unknown): number {
  const n = parseInt(String(v ?? "").trim(), 10);
  return Number.isFinite(n) ? n : 0;
}

/**
 * LSQ returns boolean-ish fields as the STRING "1"/"0" - not a boolean and not "true".
 * Comparing against true or "true" is false for every record, which silently makes every
 * primary contact look non-primary. That was a live bug in this repo's migration code,
 * caught before it ran; it would have attached a second Opportunity to a different contact
 * at an account that already had one.
 */
export function lsqTruthy(v: unknown): boolean {
  const s = String(v ?? "").trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes";
}

// ---------------------------------------------------------------------------------------
// Row types, matching the tables in 001_schema.sql
// ---------------------------------------------------------------------------------------

export interface NormalizedRows {
  calls: Record<string, unknown>[];
  outcomes: Record<string, unknown>[];
  stageChanges: Record<string, unknown>[];
  opportunities: Record<string, unknown>[];
  skipped: { activity_id: string | null; event_code: string; reason: string }[];
}

export function emptyRows(): NormalizedRows {
  return { calls: [], outcomes: [], stageChanges: [], opportunities: [], skipped: [] };
}

// ---------------------------------------------------------------------------------------
// The normaliser
// ---------------------------------------------------------------------------------------

/**
 * Normalise one lead's full activity trail.
 *
 * @param leadOwnerId  the lead's CURRENT owner. Used to decide is_owner_call: a call is
 *                     credited to a rep only when the dialler is also the present owner.
 *                     Contacts are reassigned constantly, and without this test a rep
 *                     inherits the previous owner's entire call history the day they get
 *                     the lead - which both misattributes work and inflates coverage.
 */
export function normalizeTrail(
  activities: Activity[],
  prospectId: string,
  leadOwnerId: string | null,
  ingestSource: "webhook" | "reconcile" | "backfill",
): NormalizedRows {
  const out = emptyRows();

  for (const a of activities) {
    const code = String(a?.EventCode ?? "");

    // Callkaro AI dialler. Not a person, never stored, never counted. See schema.ts.
    if (code === EVENT.AI_CALL) {
      out.skipped.push({ activity_id: null, event_code: code, reason: "ai_dialler" });
      continue;
    }

    let id: string;
    try {
      id = activityId(a);
    } catch (err) {
      out.skipped.push({ activity_id: null, event_code: code, reason: String(err) });
      continue;
    }

    // The lead id on the activity itself is authoritative; the caller's is the fallback.
    const lead = String(a?.RelatedProspectId ?? "").trim() || prospectId;

    switch (code) {
      case EVENT.CALL_OUTBOUND:
      case EVENT.CALL_INBOUND: {
        const row = normalizeCall(a, id, lead, code, leadOwnerId, ingestSource);
        if (row) out.calls.push(row);
        else out.skipped.push({ activity_id: id, event_code: code, reason: "unparseable_timestamp" });
        break;
      }
      case EVENT.CALL_FORM: {
        const row = normalizeOutcome(a, id, lead, ingestSource);
        if (row) out.outcomes.push(row);
        else out.skipped.push({ activity_id: id, event_code: code, reason: "unparseable_timestamp" });
        break;
      }
      case EVENT.STAGE_CHANGE: {
        const row = normalizeStageChange(a, id, lead, ingestSource);
        if (row) out.stageChanges.push(row);
        else out.skipped.push({ activity_id: id, event_code: code, reason: "unparseable_timestamp" });
        break;
      }
      case EVENT.OPPORTUNITY:
      case EVENT.OPP_CAPTURED: {
        const row = normalizeOpportunity(a, id, lead, code, ingestSource);
        if (row) out.opportunities.push(row);
        else out.skipped.push({ activity_id: id, event_code: code, reason: "unparseable_timestamp" });
        break;
      }
      default:
        // Lead Capture, Dynamic Form Submission, 3001, 3006 and friends. Not an error -
        // simply outside this pipeline's scope.
        out.skipped.push({ activity_id: id, event_code: code, reason: "not_in_scope" });
    }
  }

  return out;
}

/**
 * EventCode 22 (outbound) / 21 (inbound).
 *
 * ActivityFields: CreatedBy (GUID of whoever dialled), mx_Custom_2 (start time),
 * mx_Custom_3 (duration in seconds), mx_Custom_4 (recording URL), Status, Owner.
 * Data[]: CallType, Caller, Duration, ResourceUrl.
 *
 * NOTE the custom-field collision: EventCode 203 uses mx_Custom_2 and mx_Custom_3 for
 * Connected Outcome and Next Step. Reading a custom field without branching on event code
 * first would silently mix call durations into text outcomes.
 */
function normalizeCall(
  a: Activity,
  id: string,
  prospectId: string,
  code: string,
  leadOwnerId: string | null,
  ingestSource: string,
): Record<string, unknown> | null {
  const at = parseLsqUtc(a?.CreatedOn);
  if (!at) return null;

  const af = a?.ActivityFields ?? {};

  // Duration primarily from mx_Custom_3, confirmed by cross-checking against the Duration
  // embedded in ActivityEvent_Note across 116 real calls - exact match every time. Data[]
  // and the note blob are fallbacks so a missing field never silently reads as 0 seconds,
  // which would turn a connected call into an unconnected one.
  let duration = intOf(af.mx_Custom_3);
  if (duration === 0) duration = intOf(dataValue(a, "Duration"));
  if (duration === 0) duration = intOf(noteValue(af.ActivityEvent_Note, "Duration"));

  const actor = String(af.CreatedBy ?? "").trim() || null;
  const status = String(af.Status ?? "").trim() || noteValue(af.ActivityEvent_Note, "Status");

  return {
    activity_id: id,
    prospect_id: prospectId,
    event_code: code,
    direction: code === EVENT.CALL_OUTBOUND ? "outbound" : "inbound",
    called_at_utc: at.toISOString(),
    actor_owner_id: actor,
    lead_owner_id_at_pull: leadOwnerId,
    is_owner_call: !!actor && !!leadOwnerId && actor === leadOwnerId,
    status: status || null,
    duration_sec: duration,
    // "Connected" is duration > 0. Status === "Answered" is kept as a separate column
    // rather than folded in: the two have agreed on every call measured to date, so a
    // divergence is itself a finding and should not be hidden by picking one definition.
    connected: duration > 0,
    answered_by_status: status === "Answered",
    call_type: dataValue(a, "CallType") || null,
    recording_url: String(af.mx_Custom_4 ?? "").trim() ||
      dataValue(a, "ResourceUrl") ||
      noteValue(af.ActivityEvent_Note, "ResourceURL") ||
      null,
    call_note: noteValue(af.ActivityEvent_Note, "CallNotes") || null,
    ingest_source: ingestSource,
    raw: a,
  };
}

/**
 * EventCode 203, "01. Phone Call/ Follow Up" - the rep-facing outcome form.
 *
 * Long believed dead ("unused since November 2025"), but an enumeration on 2026-08-08
 * found it as the last activity on 806 leads account-wide and 7 within two days. It is also
 * the leading candidate destination for rep notes: ActivityEvent_Note here is a first-class
 * String field labelled "Notes" in the form metadata.
 *
 * Field map (all currently optional in LSQ, which is the root cause of the capture gap):
 *   Status       Connected | Not Connected
 *   mx_Custom_1  Not Connected Outcome
 *   mx_Custom_2  Connected Outcome
 *   mx_Custom_3  Next Step
 *   mx_Custom_5  Follow Up Date/Time
 */
function normalizeOutcome(
  a: Activity,
  id: string,
  prospectId: string,
  ingestSource: string,
): Record<string, unknown> | null {
  const at = parseLsqUtc(a?.CreatedOn);
  if (!at) return null;
  const af = a?.ActivityFields ?? {};

  return {
    activity_id: id,
    prospect_id: prospectId,
    logged_at_utc: at.toISOString(),
    owner_id: String(af.Owner ?? af.CreatedBy ?? "").trim() || null,
    status: String(af.Status ?? "").trim() || null,
    connected_outcome: String(af.mx_Custom_2 ?? "").trim() || null,
    not_connected_outcome: String(af.mx_Custom_1 ?? "").trim() || null,
    next_step: String(af.mx_Custom_3 ?? "").trim() || null,
    follow_up_at: parseLsqUtc(af.mx_Custom_5)?.toISOString() ?? null,
    note: String(af.ActivityEvent_Note ?? "").trim() || null,
    ingest_source: ingestSource,
    raw: a,
  };
}

/**
 * EventCode 3002, StageChange.
 *
 * This record has NO ActivityFields at all - confirmed live. Everything is in Data[]:
 * PreviousStage, CurrentStage, CreatedBy, Comment. CreatedBy here is a DISPLAY NAME
 * ("Vikhyat Verma"), not a GUID, so it can only be joined to the roster by name.
 */
function normalizeStageChange(
  a: Activity,
  id: string,
  prospectId: string,
  ingestSource: string,
): Record<string, unknown> | null {
  const at = parseLsqUtc(a?.CreatedOn);
  if (!at) return null;

  return {
    activity_id: id,
    prospect_id: prospectId,
    changed_at_utc: at.toISOString(),
    previous_stage: dataValue(a, "PreviousStage") || null,
    current_stage: dataValue(a, "CurrentStage") || null,
    changed_by_name: dataValue(a, "CreatedBy") || null,
    comment: dataValue(a, "Comment") || null,
    ingest_source: ingestSource,
    raw: a,
  };
}

/**
 * EventCode 12000 (Opportunity) / 33 (Opportunity Captured).
 *
 * Opportunity Stage is mx_Custom_2, a dependent dropdown under the native Status field that
 * reps see labelled "Deal Stage". ModifiedOn moves on ANY opportunity edit, not only a
 * stage change - LSQ emits no per-field opportunity change event, so "modified today" is
 * the finest granularity available.
 */
function normalizeOpportunity(
  a: Activity,
  id: string,
  prospectId: string,
  code: string,
  ingestSource: string,
): Record<string, unknown> | null {
  const at = parseLsqUtc(a?.CreatedOn);
  if (!at) return null;
  const af = a?.ActivityFields ?? {};

  return {
    activity_id: id,
    prospect_id: prospectId,
    opportunity_id: String(a?.Id ?? "").trim() || null,
    event_at_utc: at.toISOString(),
    modified_at_utc: parseLsqUtc(a?.ModifiedOn)?.toISOString() ?? null,
    event_code: code,
    stage: String(af.mx_Custom_2 ?? "").trim() || null,
    loss_reason: String(af.mx_Custom_4 ?? "").trim() || null,
    ingest_source: ingestSource,
    raw: a,
  };
}

// ---------------------------------------------------------------------------------------
// Lead row -> dim_contact
// ---------------------------------------------------------------------------------------

export function normalizeContact(lead: Record<string, any>): Record<string, unknown> {
  const first = String(lead.FirstName ?? "").trim();
  const last = String(lead.LastName ?? "").trim();
  return {
    prospect_id: String(lead.ProspectID ?? "").trim(),
    company_id: String(lead.RelatedCompanyId ?? "").trim() || null,
    company_name: String(lead.Company ?? "").trim() || null,
    full_name: `${first} ${last}`.trim() || null,
    phone: String(lead.Phone ?? "").trim() || null,
    email: String(lead.EmailAddress ?? "").trim() || null,
    owner_id: String(lead.OwnerId ?? "").trim() || null,
    owner_name: String(lead.OwnerIdName ?? "").trim() || null,
    contact_stage: String(lead.ProspectStage ?? "").trim() || null,
    call_disposition: String(lead.mx_Call_Disposition ?? "").trim() || null,
    disqualification_reason: String(lead.mx_Disqualification_Reason ?? "").trim() || null,
    disqualification_category: String(lead.mx_Disqualification_Category ?? "").trim() || null,
    segment: String(lead.mx_Segment ?? "").trim() || null,
    source: String(lead.Source ?? "").trim() || null,
    is_primary_contact: lsqTruthy(lead.IsPrimaryContact),
    // The lead-level Notes field is NOT a rep note. It is 100% populated with imported ICP
    // business descriptions, and a rep writing here destroys that enrichment. Stored so the
    // distinction stays visible in reporting rather than being mistaken for a call note.
    notes_field: String(lead.Notes ?? "").trim() || null,
    prospect_activity_date_max: parseLsqUtc(lead.ProspectActivityDate_Max)?.toISOString() ?? null,
    prospect_activity_name_max: String(lead.ProspectActivityName_Max ?? "").trim() || null,
    modified_on: parseLsqUtc(lead.ModifiedOn)?.toISOString() ?? null,
    last_refreshed_at: new Date().toISOString(),
  };
}

export { istDateString };
