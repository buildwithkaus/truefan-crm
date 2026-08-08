/**
 * Tests for the normaliser. Run:  deno test supabase/functions/_shared/
 *
 * The fixtures below reproduce the EXACT structure of live LeadSquared activity records
 * captured on 2026-08-08, with identifiers and names replaced by fabricated ones so this
 * file carries no real business data. Every structural oddity is deliberate and load
 * bearing - in particular the duplicated UserId key in the note blob, the empty CallNotes
 * value, and the fact that EventCode 3002 has no ActivityFields at all.
 *
 * This is the only automated test in the repo, and it exists because the normaliser is the
 * one component every ingestion path depends on: webhook, hourly reconcile, end-of-day
 * reconcile and historical backfill all run through it. A defect here is a defect
 * everywhere, and it would show up as plausible-looking wrong numbers rather than an error.
 */

import { assert, assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { activityId, dataValue, lsqTruthy, normalizeContact, normalizeTrail, noteValue } from "./normalize.ts";
import { istDateString, parseLsqUtc } from "./schema.ts";

const REP_A = "4057ed7a-0000-0000-0000-000000000001";
const REP_B = "aaaa1111-0000-0000-0000-000000000002";
const LEAD = "00cab4f9-0000-0000-0000-0000000000aa";

/** EventCode 22. Note the duplicated UserId key - the first is empty. This is verbatim shape. */
const OUTBOUND_CALL = {
  Id: "92d82af3-0000-0000-0000-0000000000c1",
  EventCode: 22,
  EventName: "Outbound Phone Call Activity",
  CreatedOn: "2026-07-31 05:33:50",
  ModifiedOn: "2026-07-31 05:35:00",
  ActivityType: 3,
  Type: "Outbound",
  RelatedProspectId: LEAD,
  Data: [
    { Key: "CallType", Value: "Complete" },
    { Key: "Caller", Value: "Test Rep" },
    { Key: "Duration", Value: "64" },
    { Key: "ResourceUrl", Value: "" },
  ],
  ActivityFields: {
    ProspectActivityAutoId: "864307",
    ActivityEvent_Note:
      `Caller{=}Test Rep{next}UserId{=}{next}UserId{=}${REP_A}{next}Duration{=}64{next}Status{=}Answered{next}CallNotes{=}{next}ResourceURL{=}{next}StartTime{=}7/31/2026 5:33:49 AM{next}Tag{=}{next}DisplayNumber{=}{next}EventNote{=}{next}SourceData{=}{next}`,
    CreatedOn: "7/31/2026 5:33:50 AM",
    CreatedBy: REP_A,
    mx_Custom_2: "2026-07-31 05:33:50",
    mx_Custom_3: "64",
    Status: "Answered",
    Owner: REP_A,
    ModifiedBy: REP_A,
  },
};

/** EventCode 3002. No ActivityFields whatsoever - everything lives in Data[]. */
const STAGE_CHANGE = {
  Id: "9dd4a8d2-0000-0000-0000-0000000000c2",
  EventCode: 3002,
  EventName: "StageChange",
  CreatedOn: "2026-07-31 05:35:19",
  ActivityType: 26,
  Type: "Information",
  RelatedProspectId: LEAD,
  Data: [
    { Key: "PreviousStage", Value: "Fresh" },
    { Key: "CurrentStage", Value: "Disqualified" },
    { Key: "CreatedBy", Value: "Test Rep" },
    { Key: "Comment", Value: "" },
  ],
};

/** EventCode 208, the Callkaro AI dialler. Must never be stored or counted. */
const AI_CALL = {
  Id: "94874149-0000-0000-0000-0000000000c3",
  EventCode: 208,
  EventName: "AI Phone Call / Follow Up",
  CreatedOn: "2026-08-07 17:57:41",
  ActivityType: 2,
  Type: "Inbound", // deliberately wrong in the source data - an outbound AI call
  RelatedProspectId: LEAD,
  Data: [{ Key: "CreatedByName", Value: "Admin" }],
  ActivityFields: {
    ProspectActivityAutoId: "902147",
    ActivityEvent_Note: "https://example.invalid/rec.mp3\nConnected - Not Interested",
    CreatedBy: "b5c423b7-0000-0000-0000-00000000dead",
  },
};

/**
 * EventCode 203. mx_Custom_2 and mx_Custom_3 mean something COMPLETELY different here than
 * on EventCode 22 - Connected Outcome and Next Step, not Start Time and Call Duration.
 */
const OUTCOME_FORM = {
  Id: "11112222-0000-0000-0000-0000000000c4",
  EventCode: 203,
  EventName: "01. Phone Call/ Follow Up",
  CreatedOn: "2026-08-08 06:10:00",
  ActivityType: 2,
  RelatedProspectId: LEAD,
  ActivityFields: {
    ActivityEvent_Note: "Wants a Diwali reel. Budget 4L. Send deck Friday.",
    Status: "Connected",
    Owner: REP_A,
    mx_Custom_1: "",
    mx_Custom_2: "Interested/ Qualified",
    mx_Custom_3: "Requirement Gathering",
    mx_Custom_5: "2026-08-12 05:30:00",
  },
};

// ---------------------------------------------------------------------------------------

Deno.test("activityId reads the top-level Id", () => {
  assertEquals(activityId(OUTBOUND_CALL), "92d82af3-0000-0000-0000-0000000000c1");
});

Deno.test("activityId falls back to ProspectActivityAutoId", () => {
  const noId = { ...OUTBOUND_CALL, Id: "" };
  assertEquals(activityId(noId), "auto:864307");
});

Deno.test("activityId THROWS when no key exists - never silently invents one", () => {
  // A surrogate key here would mean every re-ingest inserts the same activity again,
  // quietly inflating every call count in the system. Failing loudly is the point.
  assertThrows(() => activityId({ EventCode: 22, ActivityFields: {} }));
});

Deno.test("noteValue returns the LAST non-empty value for a duplicated key", () => {
  // The real blob contains UserId twice, the first empty. A non-greedy first-match parser
  // returns "" here and looks correct while being wrong on every single record.
  const blob = OUTBOUND_CALL.ActivityFields.ActivityEvent_Note;
  assertEquals(noteValue(blob, "UserId"), REP_A);
});

Deno.test("noteValue reads a normal key and an empty key correctly", () => {
  const blob = OUTBOUND_CALL.ActivityFields.ActivityEvent_Note;
  assertEquals(noteValue(blob, "Caller"), "Test Rep");
  assertEquals(noteValue(blob, "Duration"), "64");
  assertEquals(noteValue(blob, "Status"), "Answered");
  assertEquals(noteValue(blob, "CallNotes"), ""); // genuinely empty on every call to date
  assertEquals(noteValue(blob, "NoSuchKey"), "");
});

Deno.test("dataValue reads the Data[] array", () => {
  assertEquals(dataValue(STAGE_CHANGE, "PreviousStage"), "Fresh");
  assertEquals(dataValue(STAGE_CHANGE, "CurrentStage"), "Disqualified");
  assertEquals(dataValue(OUTBOUND_CALL, "CallType"), "Complete");
  assertEquals(dataValue(OUTBOUND_CALL, "Nope"), "");
});

Deno.test("parseLsqUtc handles both formats LSQ returns on one record", () => {
  assertEquals(parseLsqUtc("2026-07-31 05:33:50")?.toISOString(), "2026-07-31T05:33:50.000Z");
  assertEquals(parseLsqUtc("7/31/2026 5:33:50 AM")?.toISOString(), "2026-07-31T05:33:50.000Z");
  assertEquals(parseLsqUtc("7/31/2026 5:33:50 PM")?.toISOString(), "2026-07-31T17:33:50.000Z");
  assertEquals(parseLsqUtc("7/31/2026 12:15:00 AM")?.toISOString(), "2026-07-31T00:15:00.000Z");
  assertEquals(parseLsqUtc("7/31/2026 12:15:00 PM")?.toISOString(), "2026-07-31T12:15:00.000Z");
  assertEquals(parseLsqUtc(""), null);
  assertEquals(parseLsqUtc(null), null);
  assertEquals(parseLsqUtc("not a date"), null);
});

Deno.test("istDateString files late-evening calls on the correct IST day", () => {
  // 23:45 IST on the 8th is 18:15 UTC on the 8th - same date.
  assertEquals(istDateString(new Date("2026-08-08T18:15:00Z")), "2026-08-08");
  // 02:00 IST on the 9th is 20:30 UTC on the 8th - the UTC date is a day behind. Reporting
  // on the UTC date would misfile exactly the late calls a daily scorecard cares about.
  assertEquals(istDateString(new Date("2026-08-08T20:30:00Z")), "2026-08-09");
});

Deno.test("lsqTruthy handles the string '1'/'0' convention", () => {
  // LSQ returns bit fields as the STRING "1"/"0" - not a boolean, not "true".
  assertEquals(lsqTruthy("1"), true);
  assertEquals(lsqTruthy("0"), false);
  assertEquals(lsqTruthy("true"), true);
  assertEquals(lsqTruthy(""), false);
  assertEquals(lsqTruthy(null), false);
  assertEquals(lsqTruthy(undefined), false);
});

Deno.test("normalizeTrail: outbound call maps every field correctly", () => {
  const r = normalizeTrail([OUTBOUND_CALL], LEAD, REP_A, "webhook");
  assertEquals(r.calls.length, 1);
  const c = r.calls[0];
  assertEquals(c.activity_id, "92d82af3-0000-0000-0000-0000000000c1");
  assertEquals(c.prospect_id, LEAD);
  assertEquals(c.direction, "outbound");
  assertEquals(c.duration_sec, 64);
  assertEquals(c.connected, true);
  assertEquals(c.answered_by_status, true);
  assertEquals(c.status, "Answered");
  assertEquals(c.call_type, "Complete");
  assertEquals(c.actor_owner_id, REP_A);
  assertEquals(c.called_at_utc, "2026-07-31T05:33:50.000Z");
  assertEquals(c.call_note, null); // empty CallNotes must be null, not ""
});

Deno.test("normalizeTrail: a call is credited ONLY when the dialler is the current owner", () => {
  // Contacts are reassigned constantly. Without this test a rep inherits the previous
  // owner's entire call history the day the lead lands in their book.
  const mine = normalizeTrail([OUTBOUND_CALL], LEAD, REP_A, "webhook");
  assertEquals(mine.calls[0].is_owner_call, true);

  const theirs = normalizeTrail([OUTBOUND_CALL], LEAD, REP_B, "webhook");
  assertEquals(theirs.calls[0].is_owner_call, false);

  const unowned = normalizeTrail([OUTBOUND_CALL], LEAD, null, "webhook");
  assertEquals(unowned.calls[0].is_owner_call, false);
});

Deno.test("normalizeTrail: duration falls back to Data[] then the note blob", () => {
  const noCustom3 = {
    ...OUTBOUND_CALL,
    ActivityFields: { ...OUTBOUND_CALL.ActivityFields, mx_Custom_3: "" },
  };
  // A missing field must not silently read as 0 seconds - that turns a connected call into
  // an unconnected one and corrupts the single most-used metric in the report.
  const r = normalizeTrail([noCustom3], LEAD, REP_A, "webhook");
  assertEquals(r.calls[0].duration_sec, 64);
  assertEquals(r.calls[0].connected, true);
});

Deno.test("normalizeTrail: a zero-duration call is not connected", () => {
  const missed = {
    ...OUTBOUND_CALL,
    Id: "dead0000-0000-0000-0000-0000000000c9",
    Data: [],
    ActivityFields: {
      ...OUTBOUND_CALL.ActivityFields,
      mx_Custom_3: "0",
      Status: "NotAnswered",
      ActivityEvent_Note: "Caller{=}Test Rep{next}Duration{=}0{next}Status{=}NotAnswered{next}CallNotes{=}{next}",
    },
  };
  const r = normalizeTrail([missed], LEAD, REP_A, "webhook");
  assertEquals(r.calls[0].duration_sec, 0);
  assertEquals(r.calls[0].connected, false);
  assertEquals(r.calls[0].answered_by_status, false);
});

Deno.test("normalizeTrail: EventCode 208 (Callkaro) is EXCLUDED entirely", () => {
  // Including the AI dialler manufactures coverage nobody worked: it appeared on 40 of 971
  // assigned contacts, 14 of which no rep had ever called.
  const r = normalizeTrail([AI_CALL], LEAD, REP_A, "webhook");
  assertEquals(r.calls.length, 0);
  assertEquals(r.outcomes.length, 0);
  assertEquals(r.skipped.length, 1);
  assertEquals(r.skipped[0].reason, "ai_dialler");
});

Deno.test("normalizeTrail: stage change reads Data[] with no ActivityFields present", () => {
  const r = normalizeTrail([STAGE_CHANGE], LEAD, REP_A, "webhook");
  assertEquals(r.stageChanges.length, 1);
  const s = r.stageChanges[0];
  assertEquals(s.previous_stage, "Fresh");
  assertEquals(s.current_stage, "Disqualified");
  assertEquals(s.changed_by_name, "Test Rep"); // a display NAME, not a GUID
  assertEquals(s.comment, null);
});

Deno.test("normalizeTrail: EventCode 203 does NOT reuse EventCode 22's custom-field meanings", () => {
  // The collision that would silently mix call durations into Next Step values.
  const r = normalizeTrail([OUTCOME_FORM], LEAD, REP_A, "webhook");
  assertEquals(r.outcomes.length, 1);
  const o = r.outcomes[0];
  assertEquals(o.status, "Connected");
  assertEquals(o.connected_outcome, "Interested/ Qualified"); // mx_Custom_2
  assertEquals(o.next_step, "Requirement Gathering"); // mx_Custom_3, NOT a duration
  assertEquals(o.not_connected_outcome, null);
  assertEquals(o.note, "Wants a Diwali reel. Budget 4L. Send deck Friday.");
  assertEquals(o.follow_up_at, "2026-08-12T05:30:00.000Z");
  assertEquals(r.calls.length, 0); // must not land in fact_call
});

Deno.test("normalizeTrail: a mixed trail routes every activity to the right table", () => {
  const r = normalizeTrail(
    [OUTBOUND_CALL, STAGE_CHANGE, AI_CALL, OUTCOME_FORM],
    LEAD,
    REP_A,
    "reconcile",
  );
  assertEquals(r.calls.length, 1);
  assertEquals(r.stageChanges.length, 1);
  assertEquals(r.outcomes.length, 1);
  assertEquals(r.opportunities.length, 0);
  assertEquals(r.calls[0].ingest_source, "reconcile");
});

Deno.test("normalizeTrail: an out-of-scope event code is skipped, not failed", () => {
  const leadCapture = {
    Id: "cccc0000-0000-0000-0000-0000000000ca",
    EventCode: 3001,
    CreatedOn: "2026-08-08 06:00:00",
    RelatedProspectId: LEAD,
  };
  const r = normalizeTrail([leadCapture], LEAD, REP_A, "webhook");
  assertEquals(r.calls.length, 0);
  assertEquals(r.skipped[0].reason, "not_in_scope");
});

Deno.test("normalizeTrail: an unparseable timestamp is skipped rather than stored as NaN", () => {
  const bad = { ...OUTBOUND_CALL, CreatedOn: "garbage" };
  const r = normalizeTrail([bad], LEAD, REP_A, "webhook");
  assertEquals(r.calls.length, 0);
  assertEquals(r.skipped[0].reason, "unparseable_timestamp");
});

Deno.test("normalizeTrail: the activity's own RelatedProspectId wins over the caller's", () => {
  const other = "ffff9999-0000-0000-0000-0000000000ff";
  const r = normalizeTrail([OUTBOUND_CALL], other, REP_A, "webhook");
  assertEquals(r.calls[0].prospect_id, LEAD);
});

Deno.test("normalizeContact maps a lead row and respects the '1'/'0' boolean convention", () => {
  const c = normalizeContact({
    ProspectID: LEAD,
    FirstName: "Rakesh",
    LastName: "Sharma",
    Company: "Sharma Textiles",
    Phone: "9999900000",
    OwnerId: REP_A,
    OwnerIdName: "Test Rep",
    ProspectStage: "Engaged",
    mx_Call_Disposition: "Follow Up",
    IsPrimaryContact: "1",
    Notes: "Furniture and Interior Design Services",
    ProspectActivityDate_Max: "2026-08-08 06:10:00",
    ProspectActivityName_Max: "Outbound Phone Call Activity",
  });
  assertEquals(c.prospect_id, LEAD);
  assertEquals(c.full_name, "Rakesh Sharma");
  assertEquals(c.is_primary_contact, true);
  assertEquals(c.contact_stage, "Engaged");
  assertEquals(c.prospect_activity_date_max, "2026-08-08T06:10:00.000Z");
  // The lead-level Notes field holds imported ICP business descriptions, NOT rep notes.
  // Kept in its own column so the two can never be confused in reporting.
  assertEquals(c.notes_field, "Furniture and Interior Design Services");
});

Deno.test("normalizeTrail is idempotent in shape - same input, identical activity ids", () => {
  const a = normalizeTrail([OUTBOUND_CALL, STAGE_CHANGE], LEAD, REP_A, "webhook");
  const b = normalizeTrail([OUTBOUND_CALL, STAGE_CHANGE], LEAD, REP_A, "reconcile");
  assertEquals(a.calls[0].activity_id, b.calls[0].activity_id);
  assertEquals(a.stageChanges[0].activity_id, b.stageChanges[0].activity_id);
  assert(a.calls[0].ingest_source !== b.calls[0].ingest_source);
});
