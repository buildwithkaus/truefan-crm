/**
 * Tests the REAL appsscript/CallingPipeline.gs against payloads captured live from
 * LeadSquared on 2026-08-08. The .gs file is evaluated as-is with Apps Script globals
 * stubbed, never copied, so this cannot drift from what actually runs.
 *
 *   deno run --allow-read --no-check scripts/pipeline/test-calling-pipeline.ts
 */
const src = await Deno.readTextFile("C:/Users/kaust/truefan-crm/appsscript/CallingPipeline.gs");

const stub = `
  var SpreadsheetApp = { getActiveSpreadsheet: () => ({ getSheetByName: () => null, insertSheet: () => ({}) }) };
  var PropertiesService = { getScriptProperties: () => ({ getProperty: () => null }) };
  var ScriptApp = { getProjectTriggers: () => [], newTrigger: () => ({}) };
  var ContentService = { createTextOutput: (s) => ({ setMimeType: () => s }), MimeType: { JSON: 1 } };
  var LockService = { getScriptLock: () => ({ waitLock(){}, tryLock(){return true;}, releaseLock(){} }) };
  var UrlFetchApp = { fetch: () => ({ getResponseCode: () => 500, getContentText: () => "" }) };
  var Logger = { log: () => {} };
  var Utilities = { sleep(){} };
`;

const mod = new Function(stub + src + `
  return { normalizeWebhookActivity_, noteValue_, parseLsqUtc_, istToday_ };
`)();

const P_ANSWERED = JSON.parse(`{"ProspectActivityId":"292b2477-92ee-11f1-bd10-0a70299d455d","RelatedProspectId":"48ad0efe-24c6-4115-af72-4ba0fb7cb257","ActivityEvent":"22","ActivityEventName":"Outbound Phone Call Activity","ActivityType":"3","CreatedBy":"7fb8f9e5-6bd3-11f1-bd10-0a70299d455d","CreatedOn":"2026-08-08 05:52:30","Score":0.0,"Data":{"Status":"Answered","Owner":"7fb8f9e5-6bd3-11f1-bd10-0a70299d455d","mx_Custom_2":"2026-08-08 05:52:30","Note":"Caller{=}Abhishek Tripathi{next}UserId{=}{next}UserId{=}7fb8f9e5-6bd3-11f1-bd10-0a70299d455d{next}Duration{=}73{next}Status{=}Answered{next}CallNotes{=}{next}ResourceURL{=}{next}StartTime{=}8/8/2026 5:52:30 AM{next}Tag{=}{next}DisplayNumber{=}{next}EventNote{=}{next}SourceData{=}{next}","mx_Custom_3":"73","mx_Custom_1":""}}`);
const P_MISSED = JSON.parse(`{"ProspectActivityId":"4205ea47-92ee-11f1-bd10-0a70299d455d","RelatedProspectId":"98f05ddb-12aa-486b-8831-c11e9276e93d","ActivityEvent":"22","CreatedBy":"7fb8f9e5-6bd3-11f1-bd10-0a70299d455d","CreatedOn":"2026-08-08 05:58:24","Data":{"Status":"NotAnswered","Owner":"7fb8f9e5-6bd3-11f1-bd10-0a70299d455d","Note":"Caller{=}Abhishek Tripathi{next}UserId{=}{next}UserId{=}7fb8f9e5-6bd3-11f1-bd10-0a70299d455d{next}Duration{=}0{next}Status{=}NotAnswered{next}CallNotes{=}{next}","mx_Custom_3":"0"}}`);
const P_OTHER_REP = JSON.parse(`{"ProspectActivityId":"71de93a6-92ee-11f1-bd10-0a70299d455d","RelatedProspectId":"cd43ce65-cd90-4b21-b12a-8d9ebf54d523","ActivityEvent":"22","CreatedBy":"a18229d0-7156-11f1-bd10-0a70299d455d","CreatedOn":"2026-08-08 05:59:40","Data":{"Status":"NotAnswered","Owner":"a18229d0-7156-11f1-bd10-0a70299d455d","Note":"Caller{=}Arjun Rathi{next}UserId{=}{next}UserId{=}a18229d0-7156-11f1-bd10-0a70299d455d{next}Duration{=}0{next}Status{=}NotAnswered{next}CallNotes{=}{next}","mx_Custom_3":"0"}}`);

let fail = 0;
function check(label: string, actual: unknown, expected: unknown) {
  if (String(actual) === String(expected)) console.log(`  OK   ${label} = ${actual}`);
  else { console.log(`  FAIL ${label} = ${actual}  (want ${expected})`); fail++; }
}

console.log("--- answered call, 73s (Abhishek Tripathi) ---");
const a = mod.normalizeWebhookActivity_(P_ANSWERED);
check("kind", a.kind, "call");
check("activity_id", a.row.activity_id, "292b2477-92ee-11f1-bd10-0a70299d455d");
check("prospect_id", a.row.prospect_id, "48ad0efe-24c6-4115-af72-4ba0fb7cb257");
check("direction", a.row.direction, "outbound");
check("actor_owner_id", a.row.actor_owner_id, "7fb8f9e5-6bd3-11f1-bd10-0a70299d455d");
check("actor_name", a.row.actor_name, "Abhishek Tripathi");
check("duration_sec", a.row.duration_sec, 73);
check("connected", a.row.connected, true);
check("status", a.row.status, "Answered");
check("call_note null by design", a.row.call_note, "null");
// Stored as UTC; the IST date is a generated column in Postgres, not computed here.
check("called_at_utc", a.row.called_at_utc, "2026-08-08T05:52:30.000Z");
check("ingest_source", a.row.ingest_source, "webhook");

console.log("--- unanswered, 0s: must NOT be connected ---");
const m = mod.normalizeWebhookActivity_(P_MISSED);
check("duration_sec", m.row.duration_sec, 0);
check("connected", m.row.connected, false);

console.log("--- attribution follows CreatedBy, not the lead ---");
const o = mod.normalizeWebhookActivity_(P_OTHER_REP);
check("actor_owner_id", o.row.actor_owner_id, "a18229d0-7156-11f1-bd10-0a70299d455d");
check("actor_name", o.row.actor_name, "Arjun Rathi");

console.log("--- duplicate-key note blob ---");
const blob = P_ANSWERED.Data.Note;
check("UserId takes LAST non-empty", mod.noteValue_(blob, "UserId"), "7fb8f9e5-6bd3-11f1-bd10-0a70299d455d");
check("Caller", mod.noteValue_(blob, "Caller"), "Abhishek Tripathi");
check("Duration", mod.noteValue_(blob, "Duration"), "73");
check("CallNotes empty", mod.noteValue_(blob, "CallNotes"), "");

console.log("--- Callkaro (208) dropped entirely ---");
check("208 -> null", mod.normalizeWebhookActivity_({ ...P_ANSWERED, ActivityEvent: "208" }), "null");

console.log("--- EventCode 203 routes to outcomes, custom fields NOT read as call fields ---");
const form = mod.normalizeWebhookActivity_({
  ProspectActivityId: "form-1", RelatedProspectId: "lead-1", ActivityEvent: "203",
  CreatedBy: "rep-1", CreatedOn: "2026-08-08 06:10:00",
  Data: { Status: "Connected", Owner: "rep-1", mx_Custom_1: "", mx_Custom_2: "Interested/ Qualified",
          mx_Custom_3: "Requirement Gathering", Note: "Wants a Diwali reel." }
});
check("kind", form.kind, "outcome");
check("connected_outcome (mx_Custom_2)", form.row.connected_outcome, "Interested/ Qualified");
check("next_step (mx_Custom_3, NOT a duration)", form.row.next_step, "Requirement Gathering");
check("note", form.row.note, "Wants a Diwali reel.");

console.log("--- guards ---");
check("no activity id -> null", mod.normalizeWebhookActivity_({ ...P_ANSWERED, ProspectActivityId: "" }), "null");
check("no lead id -> null", mod.normalizeWebhookActivity_({ ...P_ANSWERED, RelatedProspectId: "" }), "null");
check("bad date -> null", mod.normalizeWebhookActivity_({ ...P_ANSWERED, CreatedOn: "garbage" }), "null");
check("out-of-scope code -> null", mod.normalizeWebhookActivity_({ ...P_ANSWERED, ActivityEvent: "3001" }), "null");

console.log("--- duration falls back to the note blob ---");
const nd = mod.normalizeWebhookActivity_({ ...P_ANSWERED, Data: { ...P_ANSWERED.Data, mx_Custom_3: "" } });
check("fallback duration", nd.row.duration_sec, 73);
check("still connected", nd.row.connected, true);

console.log("--- timestamp formats, including the MILLISECOND form that caused a false zero ---");
check("webhook form", mod.parseLsqUtc_("2026-08-08 05:52:30")?.toISOString(), "2026-08-08T05:52:30.000Z");
check("milliseconds", mod.parseLsqUtc_("2026-08-08 07:38:00.000")?.toISOString(), "2026-08-08T07:38:00.000Z");
check("US AM", mod.parseLsqUtc_("8/8/2026 5:52:30 AM")?.toISOString(), "2026-08-08T05:52:30.000Z");
check("US PM", mod.parseLsqUtc_("8/8/2026 5:52:30 PM")?.toISOString(), "2026-08-08T17:52:30.000Z");
check("garbage -> null", mod.parseLsqUtc_("nope"), "null");
check("empty -> null", mod.parseLsqUtc_(""), "null");

console.log("");
console.log(fail === 0 ? "ALL PIPELINE TESTS PASSED" : `*** ${fail} FAILURE(S) ***`);
if (fail > 0) Deno.exit(1);

// ---------------------------------------------------------------------------------------
// Field-change webhook. Payload shape captured live 2026-08-08 - two full lead snapshots.
// ---------------------------------------------------------------------------------------
const modFC = new Function(stub + src + `return { normalizeFieldChange_ };`)();
let fcFail = 0;
function fcheck(label: string, actual: unknown, expected: unknown) {
  if (String(actual) === String(expected)) console.log(`  OK   ${label} = ${actual}`);
  else { console.log(`  FAIL ${label} = ${actual}  (want ${expected})`); fcFail++; }
}

console.log("--- field change: stage Fresh -> Engaged ---");
const fc1 = modFC.normalizeFieldChange_({
  Before: { ProspectID: "fe34dd7b", ProspectStage: "Fresh", mx_Call_Disposition: null,
            OwnerId: "own-1", ModifiedBy: "sys", ModifiedOn: "2026-08-08 09:02:18" },
  After:  { ProspectID: "fe34dd7b", ProspectStage: "Engaged", mx_Call_Disposition: null,
            OwnerId: "own-1", ModifiedBy: "rep-1", ModifiedOn: "2026-08-08 09:02:30" }
});
fcheck("one row emitted", fc1.length, 1);
fcheck("field_name", fc1[0].field_name, "ProspectStage");
fcheck("old_value", fc1[0].old_value, "Fresh");
fcheck("new_value", fc1[0].new_value, "Engaged");
fcheck("changed_by_id is the AFTER editor", fc1[0].changed_by_id, "rep-1");
fcheck("changed_at_utc", fc1[0].changed_at_utc, "2026-08-08T09:02:30.000Z");
fcheck("change_key composed", fc1[0].change_key, "fe34dd7b|ProspectStage|2026-08-08T09:02:30.000Z");

console.log("--- unchanged fields emit nothing ---");
fcheck("no rows", modFC.normalizeFieldChange_({
  Before: { ProspectID: "x", ProspectStage: "Engaged", ModifiedOn: "2026-08-08 09:00:00" },
  After:  { ProspectID: "x", ProspectStage: "Engaged", ModifiedOn: "2026-08-08 09:05:00" }
}).length, 0);

console.log("--- null vs empty string is not a change ---");
fcheck("no rows", modFC.normalizeFieldChange_({
  Before: { ProspectID: "x", mx_Call_Disposition: null, ModifiedOn: "2026-08-08 09:00:00" },
  After:  { ProspectID: "x", mx_Call_Disposition: "",   ModifiedOn: "2026-08-08 09:05:00" }
}).length, 0);

console.log("--- a multi-field edit emits one row PER field ---");
const fc2 = modFC.normalizeFieldChange_({
  Before: { ProspectID: "y", ProspectStage: "Engaged", mx_Call_Disposition: null,
            mx_Disqualification_Reason: null, ModifiedOn: "2026-08-08 10:00:00" },
  After:  { ProspectID: "y", ProspectStage: "Disqualified", mx_Call_Disposition: "Did Not Pick",
            mx_Disqualification_Reason: "Invalid / Not a Business", ModifiedOn: "2026-08-08 10:00:05" }
});
fcheck("three rows", fc2.length, 3);
fcheck("fields covered", fc2.map((r: any) => r.field_name).sort().join(","),
       "ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason");

console.log("--- guards ---");
fcheck("no ProspectID -> none", modFC.normalizeFieldChange_({ Before: {}, After: {} }).length, 0);
fcheck("no timestamp -> none", modFC.normalizeFieldChange_({
  Before: { ProspectID: "z", ProspectStage: "Fresh" },
  After:  { ProspectID: "z", ProspectStage: "Engaged" }
}).length, 0);

console.log("");
console.log(fcFail === 0 ? "FIELD-CHANGE TESTS PASSED" : `*** ${fcFail} FIELD-CHANGE FAILURE(S) ***`);
if (fcFail > 0) Deno.exit(1);


// =========================================================================================
// buildMatrix_ - the pivot behind Prospects Daily and the Deal Board stage grid.
//
// Worth testing rather than eyeballing: it is the only place in the file that invents column
// keys, and a collision there silently overwrites a rep's column with another rep's numbers.
// =========================================================================================
const modM = new Function(stub + src + `return { buildMatrix_ };`)();

let mFail = 0;
function mcheck(label: string, actual: unknown, expected: unknown) {
  if (String(actual) === String(expected)) console.log(`  OK   ${label} = ${actual}`);
  else { console.log(`  FAIL ${label} = ${actual}  (want ${expected})`); mFail++; }
}

console.log("");
console.log("=========================================================");
console.log("buildMatrix_");
console.log("=========================================================");

const MROWS = [
  { d: "2026-08-08", rep: "Rishi",    n: 3 },
  { d: "2026-08-08", rep: "Abhishek", n: 5 },
  { d: "2026-08-07", rep: "Rishi",    n: 2 },
  { d: "2026-08-07", rep: "Mayank",   n: 1 }
];

console.log("--- shape and totals ---");
const m1 = modM.buildMatrix_(MROWS, "d", "rep", "n");
mcheck("row count", m1.rows.length, 2);
mcheck("grand total", m1.grand, 11);
// Columns are ordered by their own total descending: Abhishek 5, Rishi 5, Mayank 1. Abhishek
// and Rishi tie, so only the last position is asserted - a tie-break is not a contract.
mcheck("busiest column is not last", m1.cols[2], "Mayank");
mcheck("total row grand", m1.totalRow._total, 11);

console.log("--- a zero renders blank, not 0 ---");
// Mayank has nothing on the 8th. A grid of literal zeroes is unreadable and makes a genuine
// zero indistinguishable from a rep who was not working that day.
const aug8 = m1.rows.filter((r: any) => r._row === "2026-08-08")[0];
const mayankCol = "c" + m1.cols.indexOf("Mayank");
mcheck("empty cell is blank", JSON.stringify(aug8[mayankCol]), '""');
mcheck("row total still correct", aug8._total, 8);

console.log("--- a rep literally called 'Total' does not collide ---");
// Column keys are positional (c0, c1, ...) precisely so a rep name can never overwrite the
// _total column. Using the name as the key would silently destroy the row total here.
const m2 = modM.buildMatrix_(
  [{ d: "2026-08-08", rep: "Total", n: 4 }, { d: "2026-08-08", rep: "Rishi", n: 6 }],
  "d", "rep", "n");
mcheck("row total survives", m2.rows[0]._total, 10);
mcheck("two real columns", m2.cols.length, 2);

console.log("--- duplicate cells accumulate rather than overwrite ---");
const m3 = modM.buildMatrix_(
  [{ d: "x", rep: "A", n: 2 }, { d: "x", rep: "A", n: 3 }], "d", "rep", "n");
mcheck("summed", m3.rows[0].c0, 5);

console.log("--- empty input ---");
const m4 = modM.buildMatrix_([], "d", "rep", "n");
mcheck("no rows", m4.rows.length, 0);
mcheck("no columns", m4.cols.length, 0);
mcheck("grand zero", m4.grand, 0);

console.log("");
console.log(mFail === 0 ? "MATRIX TESTS PASSED" : `*** ${mFail} MATRIX FAILURE(S) ***`);
if (mFail > 0) Deno.exit(1);
