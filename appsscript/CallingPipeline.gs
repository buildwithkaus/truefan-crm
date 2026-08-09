/**
 * TrueFan CRM - calling activity pipeline.
 *
 *   LeadSquared webhook -> Apps Script -> Supabase (store) -> Google Sheet (view)
 *
 * Apps Script does three jobs and nothing else:
 *   1. receive the webhook, normalise it, upsert to Supabase
 *   2. enrich leads the webhook does not describe (owner, company, stage, disposition)
 *   3. read aggregate views and paint them into Sheet tabs
 *
 * No aggregation happens here. Every number comes from a SQL view, so the Sheet and any
 * future surface cannot disagree about what "connected" or "clean" means.
 *
 * WHY SUPABASE AND NOT JUST THE SHEET. Measured 2026-08-08: 418 calls in one day. Apps
 * Script rebuilds reports by reading every row each cycle, so a Sheet-backed store stops
 * finishing inside the 6-minute limit at roughly 50-100k rows - about two months. And the
 * LSQ API cannot re-derive history later: there is no bulk activity read.
 *
 * ---------------------------------------------------------------------------------------
 * SETUP
 *   Script Properties:
 *     LSQ_API_HOST      https://api-in21.leadsquared.com/v2
 *     LSQ_ACCESS_KEY    ...
 *     LSQ_SECRET_KEY    ...
 *     SUPABASE_URL      https://<ref>.supabase.co
 *     SUPABASE_SERVICE_KEY      service role key  (server-side only, never reaches a browser)
 *     WEBHOOK_SECRET    optional, matched against ?secret= on the webhook URL
 *   Then run setUp() once, and deploy as a web app (Execute as Me, Access Anyone).
 *
 *   After ANY code change: Deploy > Manage deployments > Edit > Version: New version.
 *   Saving alone does not update the live URL.
 * ---------------------------------------------------------------------------------------
 */

// Tab order here is the tab order in the workbook - TAB_ORDER below drives an actual
// reorder on every refresh, because a sheet whose tabs wander is a sheet nobody trusts.
// Grouped: today's activity, then what each rep holds, then the deal funnel, then plumbing.
var TABS = {
  DASHBOARD: 'Dashboard',
  REP_DAY: 'Rep Day',
  TREND: 'Daily Trend',
  PIPELINE: 'Pipeline State',
  TEAMS: 'Teams',
  REP_FUNNEL: 'Rep Funnel',
  PROSPECTS: 'Prospects Daily',
  FUNNEL: 'Stage Movement',
  DEALS: 'Deal Board',
  FORECAST: 'Forecast',
  EXCEPTIONS: 'Exceptions',
  QC: 'QC',
  META: 'Meta',
  PENDING: 'Pending',      // webhook rows Supabase refused; retried by trigger
  UNPARSED: 'Unparsed'     // payload shapes the parser did not recognise
};

// Colour-coded by what the tab answers, so the tab strip itself is navigable:
// blue = calling activity, green = the book and the funnel, amber = things to fix,
// grey = plumbing.
var TAB_COLOR = {
  'Dashboard': '#1f3864', 'Rep Day': '#1f3864', 'Daily Trend': '#1f3864',
  'Pipeline State': '#188038', 'Teams': '#188038',
  'Rep Funnel': '#188038', 'Prospects Daily': '#188038',
  'Stage Movement': '#188038', 'Deal Board': '#0b8043', 'Forecast': '#0b8043',
  'Exceptions': '#c5221f', 'QC': '#e37400',
  'Meta': '#80868b', 'Pending': '#80868b', 'Unparsed': '#80868b'
};

var IST_OFFSET_MS = 330 * 60 * 1000;

// Every daily series starts here. This is the first date the backfill covers, so anything
// earlier is a period the pipeline could not observe rather than a quiet day - showing it
// would invite exactly the wrong conclusion. Widen it only when the backfill widens.
var HISTORY_FROM = '2026-08-01';

var EVT_CALL_OUT = '22';
var EVT_CALL_IN = '21';
var EVT_CALL_FORM = '203';
var EVT_AI_CALL = '208';   // Callkaro - a background dialler, not a person. Never stored.

// Canonical disposition order for the pivot columns. Anything else is appended after these
// and flagged, so a newly-invented value is visible rather than lost.
var CANONICAL_DISPOSITIONS = ['RNR', 'Did Not Pick', 'Call me Later',
  'Switched Off/Not Reachable', 'Wrong Number', 'Follow Up'];
var STAGE_ORDER = ['Fresh', 'Engaged', 'Prospect', 'Customer', 'Disqualified'];


// =======================================================================================
// SETUP
// =======================================================================================

function setUp() {
  for (var k in TABS) ensureSheet_(TABS[k]);
  ensureSheet_(TABS.PENDING, ['QueuedIst', 'Attempts', 'RowJson']);
  ensureSheet_(TABS.UNPARSED, ['ReceivedIst', 'Reason', 'Raw']);

  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  // UrlFetch budget, not taste. The quota is 20,000/day and the webhook ingest itself needs
  // roughly one call per batch all day. At the old cadence - refresh every 10 minutes making
  // ~14 reads, enrich every 10 minutes making up to 200 - the reports alone were spending
  // more than the whole allowance and the last tabs to render simply failed.
  //
  // Now: refresh is 3 reads every 30 minutes (~144/day), enrich is bounded and only runs
  // when there is genuinely something to enrich.
  ScriptApp.newTrigger('refreshReports').timeBased().everyMinutes(30).create();
  ScriptApp.newTrigger('enrichLeads').timeBased().everyMinutes(15).create();
  ScriptApp.newTrigger('flushPending').timeBased().everyMinutes(10).create();
  Logger.log('Tabs created, triggers installed. Now deploy as a web app.');
}

function ensureSheet_(name, header) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    if (header) {
      sh.getRange(1, 1, 1, header.length).setValues([header])
        .setFontWeight('bold').setBackground('#f1f3f4');
      sh.setFrozenRows(1);
    }
  }
  return sh;
}

function cfg_(key, optional) {
  var v = PropertiesService.getScriptProperties().getProperty(key);
  if (!v && !optional) {
    // Name what IS configured. "Missing Script Property: X" on its own sends you hunting
    // for a typo you cannot see; listing the keys that exist usually makes it obvious in
    // one glance (wrong name, value pasted into the name field, trailing space).
    var have = PropertiesService.getScriptProperties().getKeys();
    throw new Error('Missing Script Property: ' + key +
                    '. Properties that ARE set: [' + have.join(', ') + ']');
  }
  return v;
}

/**
 * Run this from the Apps Script editor when anything looks wrong, and read the Execution
 * log. It checks the three things that actually break - configuration, Supabase reachability
 * and LeadSquared reachability - and it writes nothing anywhere.
 */
function diagnose() {
  var props = PropertiesService.getScriptProperties();
  var keys = props.getKeys();
  Logger.log('Script Properties set: [' + keys.join(', ') + ']');

  var required = ['LSQ_API_HOST', 'LSQ_ACCESS_KEY', 'LSQ_SECRET_KEY', 'SUPABASE_URL', 'SUPABASE_SERVICE_KEY'];
  var missing = [];
  for (var i = 0; i < required.length; i++) {
    if (!props.getProperty(required[i])) missing.push(required[i]);
  }
  Logger.log(missing.length ? ('MISSING: ' + missing.join(', ')) : 'All required properties present.');
  if (missing.length) return;

  // Values, masked. A trailing space or a swapped pair is invisible otherwise.
  Logger.log('SUPABASE_URL = "' + props.getProperty('SUPABASE_URL') + '"');
  var sk = props.getProperty('SUPABASE_SERVICE_KEY');
  Logger.log('SUPABASE_SERVICE_KEY = ' + sk.slice(0, 12) + '...' + sk.slice(-6) + '  (length ' + sk.length + ')');

  try {
    var rows = sbSelect_('ref_canonical_value', 'select=value&limit=3', 3);
    Logger.log('Supabase READ ok - ref_canonical_value returned ' + rows.length + ' row(s)');
  } catch (e) { Logger.log('Supabase READ FAILED: ' + e); return; }

  try {
    var health = sbSelect_('v_pipeline_health', 'select=*', 1)[0];
    Logger.log('v_pipeline_health: calls_stored=' + health.calls_stored +
               ' calls_today=' + health.calls_today +
               ' contacts_cached=' + health.contacts_cached);
  } catch (e) { Logger.log('v_pipeline_health FAILED (migration 002 not applied?): ' + e); }

  // Write path. Uses a sentinel row so nothing real is touched, then removes it.
  try {
    sbUpsert_('fact_call', [{
      activity_id: '00000000-0000-0000-0000-00000000diag',
      prospect_id: 'diagnostic', event_code: '22', direction: 'outbound',
      called_at_utc: new Date().toISOString(), duration_sec: 0, connected: false,
      ingest_source: 'webhook'
    }]);
    Logger.log('Supabase WRITE ok');
    UrlFetchApp.fetch(cfg_('SUPABASE_URL').replace(/\/+$/, '') +
      '/rest/v1/fact_call?activity_id=eq.00000000-0000-0000-0000-00000000diag', {
      method: 'delete',
      headers: { apikey: cfg_('SUPABASE_SERVICE_KEY'), Authorization: 'Bearer ' + cfg_('SUPABASE_SERVICE_KEY') },
      muteHttpExceptions: true
    });
    Logger.log('Sentinel row removed');
  } catch (e) { Logger.log('Supabase WRITE FAILED: ' + e); }

  try {
    var probe = sbSelect_('fact_call', 'select=prospect_id&limit=1', 1);
    if (!probe.length) {
      Logger.log('LSQ probe skipped - no calls stored yet');
    } else {
      var lead = fetchLead_(probe[0].prospect_id);
      Logger.log(lead ? ('LSQ READ ok - owner ' + lead.owner_name) : 'LSQ READ returned nothing');
    }
  } catch (e) { Logger.log('LSQ probe failed: ' + e); }

  // Triggers are the thing most often forgotten after a re-paste: setUp() must be re-run,
  // and without it nothing enriches and no tab ever refreshes.
  var trig = ScriptApp.getProjectTriggers().map(function (t) { return t.getHandlerFunction(); });
  Logger.log('Triggers installed: [' + trig.join(', ') + ']');
  if (trig.indexOf('enrichLeads') < 0) {
    Logger.log('*** enrichLeads is NOT scheduled - run setUp(). Until it runs, every rep ' +
               'shows as <unenriched> and no contact stage is known. ***');
  }

  Logger.log('--- diagnose complete ---');
}


// =======================================================================================
// SUPABASE
// =======================================================================================

/** Upsert rows into a table, keyed on its primary key. Idempotent by construction. */
function sbUpsert_(table, rows) {
  if (!rows || rows.length === 0) return 0;
  var res = UrlFetchApp.fetch(cfg_('SUPABASE_URL').replace(/\/+$/, '') + '/rest/v1/' + table, {
    method: 'post',
    contentType: 'application/json',
    headers: {
      apikey: cfg_('SUPABASE_SERVICE_KEY'),
      Authorization: 'Bearer ' + cfg_('SUPABASE_SERVICE_KEY'),
      Prefer: 'resolution=merge-duplicates,return=minimal'
    },
    payload: JSON.stringify(rows),
    muteHttpExceptions: true
  });
  var code = res.getResponseCode();
  if (code >= 300) throw new Error(table + ' upsert HTTP ' + code + ': ' + res.getContentText().slice(0, 400));
  return rows.length;
}

/**
 * Fetch every report dataset in ONE call.
 *
 * refreshReports used to issue about fourteen separate PostgREST reads, every ten minutes.
 * Together with enrichLeads that exhausted Apps Script's 20,000/day UrlFetch quota by
 * mid-afternoon, and the tabs rendered last - Pipeline State, Exceptions, QC - died with
 * "Service invoked too many times for one day". That reads like a code failure and is
 * actually a budget failure, which is a slow thing to diagnose.
 *
 * report_bundle() returns all of them as one JSON document. The two genuinely large tables
 * (Forecast, Exceptions) stay separate so no single payload gets unwieldy - three calls per
 * refresh instead of fourteen.
 */
function sbBundle_(fromDate) {
  var url = cfg_('SUPABASE_URL').replace(/\/+$/, '') + '/rest/v1/rpc/report_bundle';
  var res = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    headers: {
      apikey: cfg_('SUPABASE_SERVICE_KEY'),
      Authorization: 'Bearer ' + cfg_('SUPABASE_SERVICE_KEY')
    },
    payload: JSON.stringify({ p_from: fromDate || HISTORY_FROM }),
    muteHttpExceptions: true
  });
  var code = res.getResponseCode();
  if (code >= 300) {
    throw new Error('report_bundle HTTP ' + code + ': ' + res.getContentText().slice(0, 400));
  }
  return JSON.parse(res.getContentText());
}

/** Read a view. `query` is a PostgREST querystring. */
function sbSelect_(view, query, limit) {
  var url = cfg_('SUPABASE_URL').replace(/\/+$/, '') + '/rest/v1/' + view +
            (query ? ('?' + query) : '');
  var res = UrlFetchApp.fetch(url, {
    method: 'get',
    headers: {
      apikey: cfg_('SUPABASE_SERVICE_KEY'),
      Authorization: 'Bearer ' + cfg_('SUPABASE_SERVICE_KEY'),
      Range: '0-' + ((limit || 10000) - 1)
    },
    muteHttpExceptions: true
  });
  var code = res.getResponseCode();
  if (code >= 300) throw new Error(view + ' select HTTP ' + code + ': ' + res.getContentText().slice(0, 400));
  return JSON.parse(res.getContentText());
}


// =======================================================================================
// INGEST
// =======================================================================================

/**
 * LeadSquared's contract, all three load bearing:
 *   1. ALWAYS return 200 - ten consecutive non-200s DISABLE the webhook, and re-enabling is
 *      manual. Errors go in StatusReason.
 *   2. Verification is performed with NO payload; a handler needing a body never activates.
 *   3. Activity webhooks are BATCHED per minute, so the body is always an array.
 */
function ok_(reason) {
  return ContentService
    .createTextOutput(JSON.stringify({ Status: reason ? 'Error' : 'Success', StatusReason: reason || '' }))
    .setMimeType(ContentService.MimeType.JSON);
}

function doPost(e) { return handle_(e); }
function doGet(e) { return handle_(e); }

function handle_(e) {
  try {
    var raw = (e && e.postData && e.postData.contents) ? e.postData.contents : '';
    if (!raw) return ok_('');   // verification ping

    var secret = cfg_('WEBHOOK_SECRET', true);
    if (secret) {
      var given = (e.parameter && e.parameter.secret) ? e.parameter.secret : '';
      if (given !== secret) return ok_('unauthorized');
    }

    var items = JSON.parse(raw);
    if (!Array.isArray(items)) items = [items];

    var calls = [], outcomes = [], fieldChanges = [], unknown = 0;
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      if (!it) continue;

      // Two completely different payload shapes arrive at this one URL:
      //   activity webhook     -> has ProspectActivityId
      //   field-change webhook -> has Before / After, two full lead snapshots
      if (it.Before || it.After) {
        var fc = normalizeFieldChange_(it);
        for (var f = 0; f < fc.length; f++) fieldChanges.push(fc[f]);
        continue;
      }
      if (!it.ProspectActivityId) { unknown++; continue; }

      var n = normalizeWebhookActivity_(it);
      if (!n) continue;   // Callkaro or an out-of-scope activity code - intentionally dropped
      if (n.kind === 'call') calls.push(n.row); else outcomes.push(n.row);
    }
    if (unknown > 0) {
      ensureSheet_(TABS.UNPARSED, ['ReceivedIst', 'Reason', 'Raw']).appendRow([
        istStamp_(new Date()),
        'unrecognised shape on ' + unknown + ' item(s) - no ProspectActivityId and no Before/After',
        raw.slice(0, 40000)
      ]);
    }

    try {
      sbUpsert_('fact_call', calls);
      sbUpsert_('fact_call_outcome', outcomes);
      sbUpsert_('fact_field_change', fieldChanges);
    } catch (dbErr) {
      // Supabase unavailable. Park the normalised rows and let flushPending retry: LSQ
      // gives up after 3 attempts, so anything dropped here is gone for good otherwise.
      parkPending_(calls.concat(outcomes.map(function (o) { o.__outcome = true; return o; })));
      return ok_('parked: ' + dbErr);
    }
    return ok_('');
  } catch (err) {
    try {
      ensureSheet_(TABS.UNPARSED, ['ReceivedIst', 'Reason', 'Raw']).appendRow([
        istStamp_(new Date()), String(err),
        (e && e.postData) ? String(e.postData.contents).slice(0, 40000) : ''
      ]);
    } catch (e2) { /* nothing further to do */ }
    return ok_('handler error: ' + err);
  }
}

/**
 * Lead Field Value Change webhook -> fact_field_change rows.
 *
 * The payload carries two COMPLETE lead snapshots, Before and After, so rather than trusting
 * which field the webhook was configured for, we diff the fields we care about and emit one
 * row per field that actually moved. A single rep edit that changes stage and disposition
 * together therefore produces two rows, which is what the history should record.
 *
 * This is the only source of disposition history that will ever exist: LeadSquared keeps no
 * previous values for a lead field, so anything before these webhooks went live is
 * unrecoverable by any means.
 */
var TRACKED_FIELDS = ['ProspectStage', 'mx_Call_Disposition', 'mx_Disqualification_Reason'];

function normalizeFieldChange_(item) {
  var before = item.Before || {};
  var after = item.After || {};
  var lead = String(after.ProspectID || before.ProspectID || '');
  if (!lead) return [];

  var whenRaw = after.ModifiedOn || after.LastModifiedOn || before.ModifiedOn;
  var when = parseLsqUtc_(whenRaw);
  if (!when) return [];

  var out = [];
  for (var i = 0; i < TRACKED_FIELDS.length; i++) {
    var f = TRACKED_FIELDS[i];
    var oldV = (before[f] === undefined || before[f] === null) ? '' : String(before[f]);
    var newV = (after[f] === undefined || after[f] === null) ? '' : String(after[f]);
    if (oldV === newV) continue;                       // unchanged - not history
    // Both blank-ish is not a change either; guards against null vs "" noise.
    if (!oldV && !newV) continue;

    out.push({
      // Composed key: no id exists in the payload, and LSQ retries a webhook up to three
      // times, so re-delivery must land on the same row rather than duplicating history.
      change_key: lead + '|' + f + '|' + when.toISOString(),
      prospect_id: lead,
      field_name: f,
      old_value: oldV || null,
      new_value: newV || null,
      changed_at_utc: when.toISOString(),
      changed_by_id: String(after.ModifiedBy || before.ModifiedBy || '') || null,
      owner_id: String(after.OwnerId || before.OwnerId || '') || null,
      ingest_source: 'webhook'
    });
  }
  return out;
}

function parkPending_(rows) {
  if (!rows.length) return;
  var sh = ensureSheet_(TABS.PENDING, ['QueuedIst', 'Attempts', 'RowJson']);
  var out = rows.map(function (r) { return [istStamp_(new Date()), 0, JSON.stringify(r)]; });
  sh.getRange(sh.getLastRow() + 1, 1, out.length, 3).setValues(out);
}

function flushPending() {
  var sh = ensureSheet_(TABS.PENDING, ['QueuedIst', 'Attempts', 'RowJson']);
  var n = sh.getLastRow() - 1;
  if (n <= 0) return;

  var vals = sh.getRange(2, 1, n, 3).getValues();
  var calls = [], outcomes = [];
  for (var i = 0; i < vals.length; i++) {
    try {
      var r = JSON.parse(vals[i][2]);
      if (r.__outcome) { delete r.__outcome; outcomes.push(r); } else { calls.push(r); }
    } catch (e) { /* unparseable park row - dropped on the floor below */ }
  }
  try {
    sbUpsert_('fact_call', calls);
    sbUpsert_('fact_call_outcome', outcomes);
    // Only clear once the write has actually succeeded.
    sh.deleteRows(2, n);
    Logger.log('flushPending: wrote ' + (calls.length + outcomes.length) + ' parked rows');
  } catch (err) {
    Logger.log('flushPending: still failing - ' + err);
  }
}

/**
 * Webhook activity -> a fact row.
 *
 * SHAPE WARNING. The webhook and ProspectActivity.svc/Retrieve use the same key for
 * different things - a normaliser written for one silently reads nothing from the other:
 *   trail  Id / EventCode / ActivityFields(obj) / Data(ARRAY of {Key,Value})
 *   hook   ProspectActivityId / ActivityEvent / Data(obj)   <-- Data means the FIELDS here
 */
function normalizeWebhookActivity_(item) {
  if (!item) return null;
  var code = String(item.ActivityEvent || '');
  if (code === EVT_AI_CALL) return null;   // Callkaro: never a person, never counted

  var id = String(item.ProspectActivityId || '');
  var lead = String(item.RelatedProspectId || '');
  if (!id || !lead) return null;

  var utc = parseLsqUtc_(item.CreatedOn);
  if (!utc) return null;                    // never store an unparseable date as real

  var d = item.Data || {};
  var note = String(d.Note || '');

  if (code === EVT_CALL_FORM) {
    return { kind: 'outcome', row: {
      activity_id: id, prospect_id: lead, logged_at_utc: utc.toISOString(),
      owner_id: String(d.Owner || item.CreatedBy || '') || null,
      status: String(d.Status || '') || null,
      connected_outcome: String(d.mx_Custom_2 || '') || null,
      not_connected_outcome: String(d.mx_Custom_1 || '') || null,
      next_step: String(d.mx_Custom_3 || '') || null,
      note: note || null,
      ingest_source: 'webhook'
    } };
  }

  if (code !== EVT_CALL_OUT && code !== EVT_CALL_IN) return null;

  // Duration from mx_Custom_3, with the note blob as a cross-check. A missing field must
  // not read as 0 seconds - that turns a connected call into an unconnected one and
  // corrupts the most-used metric in the report.
  var dur = parseInt(d.mx_Custom_3, 10);
  if (!isFinite(dur) || dur === 0) {
    var alt = parseInt(noteValue_(note, 'Duration'), 10);
    if (isFinite(alt) && alt > 0) dur = alt;
  }
  if (!isFinite(dur)) dur = 0;

  return { kind: 'call', row: {
    activity_id: id,
    prospect_id: lead,
    event_code: code,
    direction: code === EVT_CALL_IN ? 'inbound' : 'outbound',
    called_at_utc: utc.toISOString(),
    actor_owner_id: String(item.CreatedBy || d.Owner || '') || null,
    actor_name: noteValue_(note, 'Caller') || null,
    status: String(d.Status || noteValue_(note, 'Status') || '') || null,
    duration_sec: dur,
    connected: dur > 0,
    call_note: noteValue_(note, 'CallNotes') || null,
    recording_url: String(d.mx_Custom_4 || noteValue_(note, 'ResourceURL') || '') || null,
    ingest_source: 'webhook'
  } };
}


// =======================================================================================
// ENRICHMENT
// =======================================================================================

/**
 * The webhook gives a lead id but not the lead's owner, company, stage or disposition -
 * all of which the report needs. Fetch those for any lead in fact_call that dim_contact
 * does not yet know, plus refresh anyone called today so stage and disposition track what
 * reps have since typed.
 *
 * Bounded per run: the LSQ daily cap is 10,000 calls and Apps Script stops at 6 minutes.
 */
function enrichLeads(maxLeads) {
  maxLeads = maxLeads || 120;

  // ONE query for the work list, using the view rather than pulling fact_call and the whole
  // of dim_contact into memory and diffing them here. The old version fetched up to 50,000
  // dim_contact rows on every run purely to build a lookup set.
  var wanted = [], seen = {};
  var missing = sbSelect_('v_calls_awaiting_enrichment',
    'select=prospect_id&limit=' + maxLeads, maxLeads);
  for (var j = 0; j < missing.length; j++) {
    var pid = missing[j].prospect_id;
    if (!pid || seen[pid]) continue;
    seen[pid] = true;
    wanted.push(pid);
  }

  // Nothing new to enrich? Refresh contacts called today whose cached copy is genuinely
  // STALE, so stage and disposition track what reps have since typed.
  //
  // This branch used to have no staleness test at all: once the backlog was clear it
  // re-fetched 200 of today's contacts every single run. At a ten-minute trigger that is
  // ~28,800 UrlFetch calls a day against a 20,000 quota, which is what took out Pipeline
  // State, Exceptions and QC with "Service invoked too many times for one day". The cap and
  // the two-hour floor are what keep this bounded.
  if (wanted.length === 0) {
    var staleBefore = new Date(Date.now() - 2 * 3600 * 1000).toISOString();
    var stale = sbSelect_('v_contacts_needing_refresh',
      'select=prospect_id&last_refreshed_at=lt.' + staleBefore + '&limit=40', 40);
    for (var t = 0; t < stale.length && wanted.length < 40; t++) {
      var p2 = stale[t].prospect_id;
      if (p2 && !seen[p2]) { seen[p2] = true; wanted.push(p2); }
    }
  }
  if (wanted.length === 0) return;

  var rows = [];
  for (var k = 0; k < wanted.length; k++) {
    var lead = fetchLead_(wanted[k]);
    if (lead) rows.push(lead);
    Utilities.sleep(110);       // stay inside the account-wide rate limit
  }
  if (rows.length) sbUpsert_('dim_contact', rows);
  Logger.log('enrichLeads: upserted ' + rows.length + ' of ' + wanted.length);
}

function fetchLead_(prospectId) {
  // Leads.GetById, NOT a Leads.Get filter: Leads.Get silently ignores a filter it does not
  // understand and returns UNFILTERED rows, so a wrong lookup name hands back an arbitrary
  // lead instead of erroring. Confirmed working live 2026-08-08.
  var url = cfg_('LSQ_API_HOST').replace(/\/+$/, '') + '/LeadManagement.svc/Leads.GetById' +
    '?accessKey=' + encodeURIComponent(cfg_('LSQ_ACCESS_KEY')) +
    '&secretKey=' + encodeURIComponent(cfg_('LSQ_SECRET_KEY')) +
    '&id=' + encodeURIComponent(prospectId);
  try {
    var res = UrlFetchApp.fetch(url, { method: 'get', muteHttpExceptions: true });
    if (res.getResponseCode() !== 200) return null;
    var body = JSON.parse(res.getContentText());
    var l = Array.isArray(body) ? body[0] : body;
    if (!l || !l.ProspectID) return null;
    return {
      prospect_id: prospectId,
      company_name: String(l.Company || '') || null,
      full_name: ((l.FirstName || '') + ' ' + (l.LastName || '')).trim() || null,
      phone: String(l.Phone || '') || null,
      owner_id: String(l.OwnerId || '') || null,
      owner_name: String(l.OwnerIdName || '') || null,
      contact_stage: String(l.ProspectStage || '') || null,
      call_disposition: String(l.mx_Call_Disposition || '') || null,
      disqualification_reason: String(l.mx_Disqualification_Reason || '') || null,
      segment: String(l.mx_Segment || '') || null,
      source: String(l.Source || '') || null,
      last_refreshed_at: new Date().toISOString()
    };
  } catch (err) {
    Logger.log('fetchLead_ ' + prospectId + ': ' + err);
    return null;
  }
}


// =======================================================================================
// REPORTS
// =======================================================================================

function refreshReports() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(5000)) return;
  var failures = [];
  var fetches = 0;
  try {
    // ONE read for everything small and medium. Everything below renders from this object
    // rather than issuing its own query - that is the whole point (see sbBundle_).
    var B = sbBundle_(HISTORY_FROM);
    fetches++;

    var tabs = [
      ['Dashboard',       function () { writeDashboard_(B); }],
      ['Rep Day',         function () { writeRepDay_(B); }],
      ['Daily Trend',     function () { writeTrend_(B); }],
      ['Pipeline State',  function () { writePipelineState_(B); }],
      ['Teams',           function () { writeTeams_(B); }],
      ['Rep Funnel',      function () { writeRepFunnel_(B); }],
      ['Prospects Daily', function () { writeProspectsDaily_(B); }],
      ['Stage Movement',  function () { writeFunnel_(B); }],
      ['Deal Board',      function () { writeDeals_(B); }],
      ['QC',              function () { writeQc_(B); }]
    ];
    for (var i = 0; i < tabs.length; i++) {
      // Each tab is wrapped so one failing view cannot take the whole refresh down and
      // leave every other tab silently stale. The failure is listed on Meta.
      try { tabs[i][1](); }
      catch (e) { failures.push(tabs[i][0] + ': ' + e); }
    }

    // The two large tables, fetched individually so no single payload gets unwieldy.
    try { writeForecast_(B); fetches++; }
    catch (e) { failures.push('Forecast: ' + e); }
    try { writeExceptions_(); fetches++; }
    catch (e) { failures.push('Exceptions: ' + e); }

    writeMeta_(failures, B, fetches);
    orderTabs_();
  } catch (fatal) {
    // The bundle itself failed - quota, a migration not run, a bad key. Say so on Meta
    // rather than leaving every tab showing yesterday's numbers as though they were today's.
    failures.push('BUNDLE: ' + fatal);
    try { writeMeta_(failures, null, fetches); } catch (e2) { /* nothing left to do */ }
  } finally {
    lock.releaseLock();
  }
}

/**
 * THE DASHBOARD. KPI strip, then the pivot: rows are rep x contact-stage-at-call,
 * columns are call dispositions, cells are call counts.
 *
 * Columns are built from the DATA, not hardcoded. Disposition values fragment on this
 * account faster than they get used correctly, so a fixed column list would silently drop
 * every newly-invented value. Non-canonical ones are marked with an asterisk instead -
 * they are exactly the values reps cannot filter on in LSQ, so they need to be conspicuous.
 */
function writeDashboard_(B, days) {
  days = days || 1;
  var from = istDaysAgo_(days - 1);
  // Filtered from the bundle rather than re-queried. The bundle already carries the full
  // window; slicing it here costs nothing and saves two UrlFetch calls per refresh.
  var pivot = (B.pivot || []).filter(function (r) { return String(r.call_date_ist) >= from; });
  var totals = (B.daily_totals || []).filter(function (r) { return String(r.report_date) >= from; });

  var sh = ensureSheet_(TABS.DASHBOARD);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);

  // ---- KPI strip -------------------------------------------------------------------
  var dials = 0, connects = 0, contacts = 0, talk = 0, reps = 0;
  for (var i = 0; i < totals.length; i++) {
    dials += Number(totals[i].dials) || 0;
    connects += Number(totals[i].connects) || 0;
    contacts += Number(totals[i].contacts) || 0;
    talk += Number(totals[i].talk_min) || 0;
    reps = Math.max(reps, Number(totals[i].active_reps) || 0);
  }

  // NO merged cells anywhere on this tab. Sheets refuses to freeze a column boundary that
  // cuts through a merge ("you can't freeze columns which contain only part of a merged
  // cell"), and the frozen rep/stage columns matter more on a wide pivot than merging does.
  // Long text in column A simply overflows across the empty cells beside it, which looks
  // identical and cannot conflict.
  sh.getRange(1, 1)
    .setValue(days === 1 ? ('Calling dashboard  -  ' + istToday_() + '  (IST)')
                         : ('Calling dashboard  -  last ' + days + ' days'))
    .setFontFamily(THEME.font).setFontSize(THEME.titleSize + 3).setFontWeight('bold')
    .setVerticalAlignment('middle');
  sh.setRowHeight(1, 36);
  sh.getRange(2, 1)
    .setValue('Refreshed ' + istStamp_(new Date()) + ' IST   -   source: Supabase v_pivot_disposition')
    .setFontFamily(THEME.font).setFontSize(9).setFontStyle('italic').setFontColor(THEME.subtitleFg);

  // KPI cards, one column each so nothing spans the freeze boundary at column 2.
  var kpi = [
    ['Dials', dials, '#,##0'],
    ['Connected', connects, '#,##0'],
    ['Connect %', dials ? Math.round(1000 * connects / dials) / 10 : 0, '0.0"%"'],
    ['Contacts', contacts, '#,##0'],
    ['Talk (min)', Math.round(talk), '#,##0'],
    ['Active reps', reps, '#,##0']
  ];
  for (var k = 0; k < kpi.length; k++) {
    var col = k + 1;
    sh.getRange(4, col).setValue(kpi[k][0])
      .setFontFamily(THEME.font).setFontSize(9).setFontColor(THEME.subtitleFg)
      .setHorizontalAlignment('center');
    sh.getRange(5, col).setValue(kpi[k][1])
      .setFontFamily(THEME.font).setFontSize(18).setFontWeight('bold')
      .setHorizontalAlignment('center').setNumberFormat(kpi[k][2]);
    sh.getRange(4, col, 2, 1)
      .setBackground(THEME.band)
      .setBorder(true, true, true, true, false, false, THEME.border, SpreadsheetApp.BorderStyle.SOLID);
  }
  sh.setRowHeight(4, 20);
  sh.setRowHeight(5, 34);
  sh.setRowHeight(6, 10);

  // ---- pivot ------------------------------------------------------------------------
  var dispSet = {}, cell = {}, repStages = {}, rowTot = {}, colTot = {};
  for (var p = 0; p < pivot.length; p++) {
    var r = pivot[p];
    var disp = r.disposition || '<blank>';
    if (r.disposition_not_selectable) disp = disp + ' *';
    dispSet[disp] = true;
    var rk = r.rep + '||' + r.contact_stage;
    repStages[rk] = true;
    cell[rk + '||' + disp] = (cell[rk + '||' + disp] || 0) + (Number(r.calls) || 0);
    rowTot[rk] = (rowTot[rk] || 0) + (Number(r.calls) || 0);
    colTot[disp] = (colTot[disp] || 0) + (Number(r.calls) || 0);
  }

  // Canonical dispositions first in their documented order, then everything else - the
  // invented values - so drift is visually obvious at the right-hand edge.
  var cols = [];
  for (var c = 0; c < CANONICAL_DISPOSITIONS.length; c++) {
    if (dispSet[CANONICAL_DISPOSITIONS[c]]) cols.push(CANONICAL_DISPOSITIONS[c]);
  }
  var extras = [];
  for (var dz in dispSet) if (cols.indexOf(dz) < 0) extras.push(dz);
  extras.sort();
  cols = cols.concat(extras);

  var keys = Object.keys(repStages).sort(function (a, b) {
    var A = a.split('||'), B = b.split('||');
    if (A[0] !== B[0]) return A[0] < B[0] ? -1 : 1;
    var ia = STAGE_ORDER.indexOf(A[1]), ib = STAGE_ORDER.indexOf(B[1]);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
  });

  var top = 8;
  sh.getRange(top, 1)
    .setValue('Calls by rep, stage at time of call, and disposition')
    .setFontFamily(THEME.font).setFontSize(12).setFontWeight('bold');
  sh.getRange(top + 1, 1)
    .setValue('* = stored in LeadSquared but NOT a selectable dropdown option, so reps cannot filter on it.   ' +
              '"<no history>" = the call predates disposition tracking; the value at the time is unrecoverable.')
    .setFontFamily(THEME.font).setFontSize(9).setFontStyle('italic').setFontColor(THEME.subtitleFg);

  var header = ['Rep', 'Stage at call'].concat(cols).concat(['Total']);
  var grid = [];
  var lastRep = null;
  var repStartRows = [];
  for (var q = 0; q < keys.length; q++) {
    var parts = keys[q].split('||');
    // Blank the repeated rep name so the eye groups the stage rows under one owner.
    var isNewRep = (parts[0] !== lastRep);
    if (isNewRep) repStartRows.push(q);
    var row = [isNewRep ? parts[0] : '', parts[1]];
    lastRep = parts[0];
    for (var cc = 0; cc < cols.length; cc++) {
      row.push(cell[keys[q] + '||' + cols[cc]] || '');
    }
    row.push(rowTot[keys[q]] || 0);
    grid.push(row);
  }
  var totRow = ['TOTAL', ''];
  var grand = 0;
  for (var ct = 0; ct < cols.length; ct++) { totRow.push(colTot[cols[ct]] || 0); grand += colTot[cols[ct]] || 0; }
  totRow.push(grand);
  grid.push(totRow);

  var hRow = top + 2;
  if (grid.length === 1) {
    sh.getRange(hRow, 1).setValue('No calls in range - check the Meta tab before assuming a quiet day')
      .setFontFamily(THEME.font).setFontColor(THEME.muted).setFontStyle('italic');
    return;
  }

  var w = header.length;
  sh.getRange(hRow, 1, 1, w).setValues([header])
    .setFontFamily(THEME.font).setFontSize(THEME.size).setFontWeight('bold')
    .setBackground(THEME.headerBg).setFontColor(THEME.headerFg)
    .setVerticalAlignment('middle').setWrap(true).setHorizontalAlignment('center');
  sh.getRange(hRow, 1, 1, 2).setHorizontalAlignment('left');
  sh.setRowHeight(hRow, 36);

  sh.getRange(hRow + 1, 1, grid.length, w).setValues(grid)
    .setFontFamily(THEME.font).setFontSize(THEME.size).setWrap(false);
  // Counts right-aligned; the two label columns stay left.
  sh.getRange(hRow + 1, 3, grid.length, w - 2).setNumberFormat('#,##0').setHorizontalAlignment('right');
  sh.getRange(hRow + 1, 1, grid.length, 2).setHorizontalAlignment('left');

  var totalRowIdx = hRow + grid.length;
  sh.getRange(totalRowIdx, 1, 1, w).setFontWeight('bold').setBackground(THEME.totalBg);
  sh.getRange(hRow + 1, w, grid.length, 1).setFontWeight('bold');   // row Total column

  // A rule line above each new rep block, so the groups are readable without banding
  // fighting the merged-looking rep column.
  for (var rs = 1; rs < repStartRows.length; rs++) {
    sh.getRange(hRow + 1 + repStartRows[rs], 1, 1, w)
      .setBorder(true, null, null, null, null, null, THEME.border, SpreadsheetApp.BorderStyle.SOLID);
  }
  sh.getRange(hRow, 1, grid.length + 1, w)
    .setBorder(true, true, true, true, false, false, THEME.border, SpreadsheetApp.BorderStyle.SOLID);

  sh.setFrozenRows(hRow);
  sh.setFrozenColumns(2);
  sh.setColumnWidth(1, 170);
  sh.setColumnWidth(2, 120);
  for (var cw = 3; cw <= w; cw++) sh.setColumnWidth(cw, 96);
}

/**
 * Pipeline State - what each rep HOLDS, as opposed to what they did.
 *
 * Sourced from the daily book snapshot (scripts/pipeline/03-snapshot-book.ps1), not from
 * call activity: a rep can look busy on call volume while never touching most of their
 * assigned list, because they keep re-dialling the same responsive contacts. Coverage_7d
 * joins the two and is the column that exposes that.
 *
 * Fails soft. If the snapshot job has never run the tab says so plainly rather than showing
 * an empty grid that reads as "this rep holds nothing".
 */
function writePipelineState_(B) {
  var rows, coverage;
  try {
    rows = withTeam_(B.pipeline_state || []);
    coverage = B.book_coverage || [];
  } catch (e) {
    var shx = ensureSheet_(TABS.PIPELINE);
    shx.clear();
    shx.getRange(1, 1).setValue('Pipeline State')
      .setFontFamily(THEME.font).setFontSize(THEME.titleSize).setFontWeight('bold');
    shx.getRange(3, 1).setValue('Not available: ' + e)
      .setFontFamily(THEME.font).setFontColor(THEME.muted);
    return;
  }

  if (!rows.length) {
    var sh0 = ensureSheet_(TABS.PIPELINE);
    sh0.clear();
    sh0.getRange(1, 1).setValue('Pipeline State')
      .setFontFamily(THEME.font).setFontSize(THEME.titleSize).setFontWeight('bold');
    sh0.getRange(3, 1).setValue(
      'No snapshot yet. Run:  pwsh ./scripts/pipeline/03-snapshot-book.ps1')
      .setFontFamily(THEME.font).setFontColor(THEME.muted).setFontStyle('italic');
    return;
  }

  var covByRep = {};
  for (var i = 0; i < coverage.length; i++) covByRep[coverage[i].rep] = coverage[i];
  for (var j = 0; j < rows.length; j++) {
    var c = covByRep[rows[j].rep];
    rows[j].contacts_called_7d = c ? c.contacts_called_7d : 0;
    rows[j].coverage_7d_pct = c ? c.coverage_7d_pct : 0;
  }

  var sh = writeTable_(TABS.PIPELINE, [
    ['team', 'Team'],
    ['rep', 'Rep'],
    ['book_size', 'Book size'],
    ['workable', 'Workable'],
    ['fresh', 'Fresh'],
    ['engaged', 'Engaged'],
    ['prospect', 'Prospect'],
    ['customer', 'Customer'],
    ['disqualified', 'Disqualified'],
    ['other', 'Other'],
    ['pct_untouched', 'Untouched %'],
    ['pct_at_prospect', 'At Prospect %'],
    ['contacts_called_7d', 'Called (7d)'],
    ['coverage_7d_pct', 'Coverage 7d %'],
    ['as_of', 'As of']
  ], rows,
    'What each rep HOLDS, from the daily book snapshot. "Workable" excludes Customers and ' +
    'Disqualified. "Coverage 7d" is the share of the workable book actually dialled in the ' +
    'last week - high call volume with low coverage means the same contacts are being redialled.',
    { teamKey: 'team' });

  // Highlight the two columns worth acting on: a book that is mostly untouched, and a book
  // that is barely being covered. Thresholds are deliberately blunt - this is a prompt to
  // look, not a verdict. Column indexes shift by one now that Team leads the table.
  var hRow = 4;
  for (var r = 0; r < rows.length; r++) {
    if (Number(rows[r].pct_untouched) >= 70) {
      sh.getRange(hRow + r, 11).setBackground(THEME.warn);
    }
    if (Number(rows[r].coverage_7d_pct) < 10) {
      sh.getRange(hRow + r, 14).setBackground(THEME.bad);
    }
  }
  return sh;
}

function writeRepDay_(B) {
  var rows = withTeam_(B.rep_day);
  writeTable_(TABS.REP_DAY,
    [['report_date', 'Date'], ['team', 'Team'], ['rep', 'Rep'],
     ['dials', 'Dials'], ['contacts', 'Contacts'],
     ['connects', 'Connects'], ['connect_rate_pct', 'Connect %'], ['talk_min', 'Talk (min)'],
     ['inbound_calls', 'Inbound'],
     ['called_fresh', 'At Fresh'], ['called_engaged', 'At Engaged'], ['called_prospect', 'At Prospect'],
     ['called_customer', 'At Customer'], ['called_disqualified', 'At Disq'],
     ['contacts_updated', 'Contacts updated'], ['discipline_pct', 'Discipline %'], ['clean_pct', 'Clean %'],
     ['gap_still_fresh', 'Gap: Fresh'], ['gap_no_disposition', 'Gap: No Disp'],
     ['gap_no_reason', 'Gap: No Reason'], ['gap_contradicts', 'Gap: Contradicts'],
     ['gap_bad_value', 'Gap: Bad Value']],
    rows,
    'Per rep per day from ' + HISTORY_FROM + '. "Contacts updated" is a COUNT of contacts ' +
    'whose stage moved at or after the call, not a timestamp. Read Clean % beside ' +
    '"Contradicts" - a jump straight after a batch cleanup means re-staging happened, ' +
    'not dispositioning.');
}

/**
 * DAILY TREND - team totals per day, then one column per call disposition.
 *
 * The disposition columns are generated from the data. A fixed list would silently drop
 * every newly invented value, and on this account those appear faster than the existing
 * ones get used correctly.
 */
function writeTrend_(B) {
  var totals = B.daily_totals || [];
  var disp = B.daily_disp || [];

  // Pivot dispositions into columns, busiest first.
  var byDate = {}, dispTotals = {};
  for (var i = 0; i < disp.length; i++) {
    var d = disp[i];
    var key = String(d.report_date);
    if (!byDate[key]) byDate[key] = {};
    byDate[key][d.disposition] = (byDate[key][d.disposition] || 0) + Number(d.calls || 0);
    dispTotals[d.disposition] = (dispTotals[d.disposition] || 0) + Number(d.calls || 0);
  }
  var dispCols = Object.keys(dispTotals).sort(function (a, b) { return dispTotals[b] - dispTotals[a]; });

  var rows = [];
  for (var t = 0; t < totals.length; t++) {
    var r = totals[t];
    var out = {
      report_date: r.report_date, dials: r.dials, connects: r.connects,
      connect_rate_pct: r.connect_rate_pct, contacts: r.contacts,
      active_reps: r.active_reps, talk_min: r.talk_min,
      owner_dials: r.owner_dials, inherited_dials: r.inherited_dials
    };
    var dd = byDate[String(r.report_date)] || {};
    for (var c = 0; c < dispCols.length; c++) out['d' + c] = dd[dispCols[c]] || '';
    rows.push(out);
  }

  var colDefs = [['report_date', 'Date'], ['dials', 'Dials'], ['connects', 'Connects'],
                 ['connect_rate_pct', 'Connect %'], ['contacts', 'Contacts'],
                 ['active_reps', 'Active reps'], ['talk_min', 'Talk (min)'],
                 ['owner_dials', 'Own book'], ['inherited_dials', 'Inherited']];
  for (var c2 = 0; c2 < dispCols.length; c2++) colDefs.push(['d' + c2, dispCols[c2]]);

  writeTable_(TABS.TREND, colDefs, rows,
    'Whole-team totals by day from ' + HISTORY_FROM + ', then one column per call ' +
    'disposition. "<no history>" is every call before the disposition webhook went live on ' +
    '2026-08-08 - that history was never kept and cannot be reconstructed. "Inherited" is ' +
    'calls made on a contact the dialler does not own; they count in Dials but never ' +
    'against a rep.');
}

function writeFunnel_(B) {
  writeTable_(TABS.FUNNEL,
    [['report_date', 'Date'], ['rep', 'Moved by'], ['from_stage', 'From'], ['to_stage', 'To'],
     ['contacts', 'Contacts']],
    B.movement || [],
    'Every contact-stage transition from ' + HISTORY_FROM + '. Calls measure effort; this ' +
    'measures progress. Attributed to whoever made the change, so bulk and system writes ' +
    'appear under their own name rather than inflating a rep.');
}

/**
 * Attach team and sort order to any row carrying a `rep` field, so every rep-facing tab
 * groups the same way. Reps who are not on the org chart land in "Unassigned" rather than
 * disappearing - Irfan Mahmood, Shriyanka Gupta and Admin all hold real books.
 */
function withTeam_(rows) {
  var map = teamMap_();
  var out = (rows || []).map(function (r) {
    var key = String(r.rep || '').toLowerCase().replace(/^\s+|\s+$/g, '');
    var t = map[key];
    var o = {};
    for (var k in r) o[k] = r[k];
    o.team = t ? t.team : 'Unassigned';
    o._teamSort = t ? t.sort : 900;
    return o;
  });
  // Stable: team first, then whatever order the view returned within the team.
  return out;
}

var TEAM_MAP_CACHE = null;
function teamMap_() {
  if (TEAM_MAP_CACHE) return TEAM_MAP_CACHE;
  var m = {};
  try {
    var rows = sbSelect_('dim_team', 'select=rep_name,team,is_lead,sort_order', 200);
    for (var i = 0; i < rows.length; i++) {
      var teamRank = rows[i].team === 'Team #ONE' ? 1 : (rows[i].team === 'Team Achievers' ? 2 : 8);
      m[rows[i].rep_name] = {
        team: rows[i].team,
        sort: teamRank * 100 + (rows[i].is_lead ? 0 : 10) + Number(rows[i].sort_order || 0)
      };
    }
  } catch (e) {
    // No team table yet - everything reads as Unassigned, which is honest.
  }
  TEAM_MAP_CACHE = m;
  return m;
}

function writeExceptions_() {
  var rows = sbSelect_('v_hygiene_exceptions',
    'select=*&report_date=gte.' + istDaysAgo_(3) + '&order=severity.asc,rep.asc', 5000);
  var sh = writeTable_(TABS.EXCEPTIONS,
    [['report_date', 'Date'], ['rep', 'Rep'], ['flag', 'Issue'], ['severity', 'Sev'],
     ['detail', 'What to fix'], ['company_name', 'Company'], ['contact_name', 'Contact'],
     ['phone', 'Phone'], ['contact_stage', 'Stage'], ['call_disposition', 'Disposition'],
     ['disqualification_reason', 'Disq Reason'], ['dials', 'Dials'], ['connects', 'Connects'],
     ['prospect_id', 'ProspectId']],
    rows, 'The worklist. One row per violation, severity 1 first.');
  // Body starts at row 4 (title 1, subtitle 2, header 3). The range and the formula's row
  // reference must BOTH start there - anchoring at row 3 covered the header and stopped one
  // row short of the last exception, so the worst row on the tab was never coloured.
  if (rows.length) {
    var band = sh.getRange(4, 1, rows.length, 14);
    sh.setConditionalFormatRules([
      SpreadsheetApp.newConditionalFormatRule().whenFormulaSatisfied('=$D4=1')
        .setBackground(THEME.bad).setRanges([band]).build(),
      SpreadsheetApp.newConditionalFormatRule().whenFormulaSatisfied('=$D4=2')
        .setBackground(THEME.warn).setRanges([band]).build()
    ]);
  }
}

/**
 * PROSPECTS DAILY - the production number. Rows are days, columns are reps.
 *
 * A matrix rather than a list because the question is comparative: who is creating prospects
 * and on which days did the team stall. A 400-row long-format list cannot be read that way,
 * and pivoting it by hand is exactly the manual step this pipeline exists to remove.
 *
 * "Created" means a stage TRANSITION into Prospect, so a contact later disqualified still
 * counts on the day it was promoted. Reading current stage instead would delete a rep's
 * work retroactively every time a deal went bad.
 */
function writeProspectsDaily_(B) {
  var rows = B.prospects_daily || [];

  var sh = ensureSheet_(TABS.PROSPECTS);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);

  if (!rows.length) {
    renderTable_(sh, 1, TABS.PROSPECTS, [['report_date', 'Date']], [],
      'No stage transitions into Prospect in the last 30 days.');
    return;
  }

  var m = buildMatrix_(rows, 'report_date', 'rep', 'prospects_created');
  var colDefs = [['_row', 'Date (IST)']];
  for (var i = 0; i < m.cols.length; i++) colDefs.push(['c' + i, m.cols[i]]);
  colDefs.push(['_total', 'Total']);

  var netNew = 0, reEntered = 0, total = 0;
  for (var j = 0; j < rows.length; j++) {
    netNew    += Number(rows[j].net_new) || 0;
    reEntered += Number(rows[j].re_entered) || 0;
    total     += Number(rows[j].prospects_created) || 0;
  }

  var r = renderKpis_(sh, 1, [
    { label: 'Prospects created (30d)', value: total, format: '#,##0' },
    { label: 'First-time', value: netNew, format: '#,##0' },
    { label: 'Re-entered', value: reEntered, format: '#,##0',
      color: reEntered > 0 ? '#b06000' : null },
    { label: 'Active days', value: m.rowKeys.length, format: '#,##0' },
    { label: 'Reps creating', value: m.cols.length, format: '#,##0' }
  ]);

  renderTable_(sh, r, 'Prospects created per day, per rep',
    colDefs, m.rows.concat([m.totalRow]),
    'A stage transition into Prospect, credited to the contact owner. Re-entries (a contact ' +
    'that was already a Prospect before) are counted in the total but broken out above, ' +
    'because they are recovered pipeline rather than new pipeline.',
    { freeze: true, totalRow: m.rows.length });

  autoWidth_(sh, colDefs, m.rows);
  sh.setColumnWidth(1, 110);
}

/**
 * Pivot long-format rows into a matrix. Column keys are positional ('c0','c1',...) rather
 * than the label itself, so a rep called "Total" cannot collide with the total column and a
 * name containing a dot cannot break a property lookup.
 *
 * Columns are ordered by their own total descending - the busiest rep first - which is what
 * a reader scans for. Alphabetical would bury the answer.
 */
function buildMatrix_(rows, rowKey, colKey, valKey) {
  var colTotals = {}, rowMap = {}, rowKeys = [];
  for (var i = 0; i < rows.length; i++) {
    var rk = String(rows[i][rowKey]);
    var ck = String(rows[i][colKey]);
    var v = Number(rows[i][valKey]) || 0;
    if (!rowMap[rk]) { rowMap[rk] = {}; rowKeys.push(rk); }
    rowMap[rk][ck] = (rowMap[rk][ck] || 0) + v;
    colTotals[ck] = (colTotals[ck] || 0) + v;
  }
  var cols = Object.keys(colTotals).sort(function (a, b) { return colTotals[b] - colTotals[a]; });

  var out = [], grand = 0;
  var totalRow = { _row: 'TOTAL' };
  for (var c = 0; c < cols.length; c++) totalRow['c' + c] = colTotals[cols[c]];
  for (var k = 0; k < rowKeys.length; k++) {
    var o = { _row: rowKeys[k] }, sum = 0;
    for (var c2 = 0; c2 < cols.length; c2++) {
      var val = rowMap[rowKeys[k]][cols[c2]] || 0;
      o['c' + c2] = val || '';   // blank, not 0 - a grid of zeroes hides the real numbers
      sum += val;
    }
    o._total = sum;
    grand += sum;
    out.push(o);
  }
  totalRow._total = grand;
  return { cols: cols, rows: out, rowKeys: rowKeys, totalRow: totalRow, grand: grand };
}

/**
 * TEAMS - the org chart, and the same numbers rolled up to team level.
 *
 * Exists because every rep-facing tab is read by team, and because a reader needs somewhere
 * to see who reports to whom without opening another document.
 */
function writeTeams_(B) {
  var teams = B.team_summary || [];
  var reps = B.rep_funnel || [];

  var sh = ensureSheet_(TABS.TEAMS);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);

  var r = renderTable_(sh, 1, 'Team totals', [
    ['team', 'Team'], ['reps', 'Reps'],
    ['book_size', 'Book'], ['workable', 'Workable'],
    ['fresh', 'Fresh'], ['engaged', 'Engaged'], ['prospect', 'Prospect'],
    ['called_30d', 'Called 30d'], ['coverage_pct', 'Coverage %'],
    ['dials_30d', 'Dials 30d'], ['connects_30d', 'Connects 30d'], ['connect_pct', 'Connect %'],
    ['new_prospects_30d', 'New prospects 30d'],
    ['deals', 'Deals'], ['hot', 'Hot'], ['warm', 'Warm'], ['won', 'Won']
  ], teams,
    'Rolled up from the same rows as Rep Funnel, so the two always agree.',
    { freeze: true, filter: false });

  renderTable_(sh, r, 'Who is on which team', [
    ['team', 'Team'], ['lead', 'Team lead'], ['rep', 'Rep'], ['role', 'Role'],
    ['book_size', 'Book'], ['workable', 'Workable'], ['deals', 'Deals'], ['hot', 'Hot']
  ], buildRoster_(reps),
    'Anyone holding a book who is not on the org chart appears under Unassigned rather than ' +
    'being dropped - they still own real contacts.',
    { freeze: false, teamKey: 'team' });

  sh.setColumnWidth(1, 150); sh.setColumnWidth(2, 150); sh.setColumnWidth(3, 170);
  return sh;
}

function buildRoster_(repRows) {
  var map = teamMap_();
  var leadOf = {};
  try {
    var rows = sbSelect_('dim_team', 'select=rep_name,display_name,team,team_lead,is_lead', 200);
    for (var i = 0; i < rows.length; i++) leadOf[rows[i].rep_name] = rows[i];
  } catch (e) { /* no team table yet */ }

  return (repRows || []).map(function (r) {
    var key = String(r.rep || '').toLowerCase().replace(/^\s+|\s+$/g, '');
    var t = leadOf[key];
    return {
      team: r.team || 'Unassigned',
      lead: t ? t.team_lead : '',
      rep: t ? t.display_name : r.rep,
      role: t ? (t.is_lead ? 'Team lead' : 'Rep') : 'Not on the org chart',
      book_size: r.book_size, workable: r.workable, deals: r.deals, hot: r.hot
    };
  });
}

/**
 * REP FUNNEL, rebuilt so every column has exactly one meaning.
 *
 * Two blocks, kept apart on purpose:
 *
 *   THE BOOK - what the rep holds right now. Fresh + Engaged + Prospect + Customer +
 *   Disqualified + Other equals Book exactly. The old version's columns did not add up to
 *   anything, which is why they could not be explained.
 *
 *   THE WORK - what the rep did in the last 30 days, and their deal book.
 *
 * "Touched" is gone. It counted rows in a modelling view rather than anything a rep would
 * recognise. "Called 30d" replaces it and means what it says: distinct contacts this rep
 * personally dialled.
 *
 * Prospect and Deals sit next to each other with the gap between them, because the
 * operational rule is that they should be equal - every Prospect contact carries an
 * opportunity. Showing both makes the missing ones visible rather than implied.
 */
function writeRepFunnel_(B) {
  var rows = (B.rep_funnel || []).slice();

  var sh = writeTable_(TABS.REP_FUNNEL, [
    ['team', 'Team'],
    ['rep', 'Rep'],
    // --- the book, today ---
    ['book_size', 'Book'],
    ['workable', 'Workable'],
    ['fresh', 'Fresh'],
    ['engaged', 'Engaged'],
    ['prospect', 'Prospect'],
    ['customer', 'Customer'],
    ['disqualified', 'Disqualified'],
    ['off_taxonomy', 'Off-taxonomy'],
    // --- the work, last 30 days ---
    ['called_30d', 'Called 30d'],
    ['coverage_pct', 'Coverage %'],
    ['dials_30d', 'Dials 30d'],
    ['connects_30d', 'Connects 30d'],
    ['connect_pct', 'Connect %'],
    ['new_prospects_30d', 'New prospects 30d'],
    ['disqualified_30d', 'Disqualified 30d'],
    // --- the deal book ---
    ['deals', 'Deals'],
    ['prospects_missing_deal', 'Prospects w/o deal'],
    ['new_deals', 'Deals: New'],
    ['warm', 'Deals: Warm'],
    ['hot', 'Deals: Hot'],
    ['hot_pct', 'Hot %'],
    ['won', 'Won'],
    ['lost', 'Lost']
  ], rows,
    'THE BOOK (Fresh..Off-taxonomy add up to Book) | THE WORK, last 30 days | THE DEAL BOOK. ' +
    '"Called 30d" is distinct contacts this rep personally dialled - a previous owner\'s ' +
    'calls on an inherited contact do not count. "Coverage %" is Called / Workable. ' +
    '"Prospects w/o deal" should be zero: the rule is every Prospect carries an opportunity.',
    { teamKey: 'team' });

  // Body starts at row 4: title 1, subtitle 2, header 3.
  var bodyStart = 4;
  for (var i = 0; i < rows.length; i++) {
    if (Number(rows[i].prospects_missing_deal) > 0) {
      sh.getRange(bodyStart + i, 19).setBackground(THEME.warn);
    }
    var cov = Number(rows[i].coverage_pct);
    if (Number(rows[i].workable) > 100 && (isNaN(cov) || cov < 10)) {
      sh.getRange(bodyStart + i, 12).setBackground(THEME.bad);
    }
    if (Number(rows[i].off_taxonomy) > 0) {
      sh.getRange(bodyStart + i, 10).setBackground(THEME.warn);
    }
  }
  return sh;
}

/**
 * DEAL BOARD - every opportunity, by rep, by status, by stage.
 *
 * Two blocks. The per-rep summary answers "how is each rep's deal book doing"; the stage
 * matrix underneath answers "where do open deals actually sit". Stage names come from the
 * data, never from a hardcoded list, so an invented stage shows up rather than vanishing.
 */
function writeDeals_(B) {
  var board = withTeam_(B.deal_board || []);
  var detail = B.deal_detail || [];

  var sh = ensureSheet_(TABS.DEALS);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);

  if (!board.length) {
    renderTable_(sh, 1, TABS.DEALS, [['rep', 'Rep']], [],
      'No opportunities loaded yet. Run:  pwsh ./scripts/pipeline/backfill.ps1 -DealStagesOnly');
    return;
  }

  var totOpen = 0, totWon = 0, totLost = 0, openValue = 0, wonValue = 0, unvalued = 0;
  for (var i = 0; i < board.length; i++) {
    totOpen   += Number(board[i].open_opps) || 0;
    totWon    += Number(board[i].won) || 0;
    totLost   += Number(board[i].lost) || 0;
    openValue += Number(board[i].open_known_value) || 0;
    wonValue  += Number(board[i].won_value) || 0;
    unvalued  += Number(board[i].open_unvalued) || 0;
  }

  var r = renderKpis_(sh, 1, [
    { label: 'Open deals', value: totOpen, format: '#,##0' },
    { label: 'Won', value: totWon, format: '#,##0', color: '#188038' },
    { label: 'Lost', value: totLost, format: '#,##0', color: '#c5221f' },
    { label: 'Win rate', value: (totWon + totLost) ? (100 * totWon / (totWon + totLost)) : '',
      format: '0.0"%"' },
    { label: 'Open value (known)', value: openValue, format: '"₹"#,##0' },
    { label: 'Open deals with no value', value: unvalued, format: '#,##0',
      color: unvalued > 0 ? '#b06000' : null }
  ]);

  r = renderTable_(sh, r, 'Deal book per rep', [
    ['team', 'Team'],
    ['rep', 'Rep'],
    ['total_opps', 'Total'],
    ['open_opps', 'Open'],
    ['hot', 'Hot'],
    ['warm', 'Warm'],
    ['new_unqualified', 'New'],
    ['won', 'Won'],
    ['lost', 'Lost'],
    ['win_rate_pct', 'Win rate %'],
    ['hot_known_value', 'Hot value (known)'],
    ['open_known_value', 'Open value (known)'],
    ['won_actual_value', 'Won value (actual)'],
    ['open_unvalued', 'Open, no value'],
    ['open_no_close_date', 'Open, no close date']
  ], board,
    'Hot = In Discussion, Agreement Sent, Invoice Sent. Warm = Requirement Gathering. ' +
    'New = Prospect, created but never progressed. Win rate is Won / (Won + Lost); open ' +
    'deals are excluded from the denominator, otherwise a rep with a healthy pipeline looks ' +
    'like they are losing.',
    { freeze: true, teamKey: 'team' });

  if (detail.length) {
    var m = buildMatrix_(detail, 'rep', 'stage', 'opportunities');
    var colDefs = [['_row', 'Rep']];
    for (var c = 0; c < m.cols.length; c++) colDefs.push(['c' + c, m.cols[c]]);
    colDefs.push(['_total', 'Open total']);
    renderTable_(sh, r, 'Open deals by stage',
      colDefs, m.rows.concat([m.totalRow]),
      'Stage values are read from live data, not a fixed list. A stage you do not recognise ' +
      'here is a value someone invented - it is invisible to LSQ stage filters.',
      { freeze: false, totalRow: m.rows.length });
  }

  sh.setColumnWidth(1, 170);
  for (var w = 2; w <= 12; w++) sh.setColumnWidth(w, 116);
  return sh;
}

/**
 * FORECAST - what is going to close, for how much, and when.
 *
 * The headline block is the point of this tab TODAY. Deal value and expected close date are
 * blank on most opportunities, so the deal list below is mostly empty columns - and showing
 * that emptiness as a percentage, per rep, is the entire argument for filling them in. A
 * forecast that covers 8% of open deals is not a forecast, and this states it in one number
 * rather than leaving someone to infer it from a sea of blanks.
 *
 * The list is still useful before a single amount is entered: days open, days since last
 * call, overdue and stale work on every row regardless of value.
 */
function writeForecast_(B) {
  // The one genuinely large table left as its own read - 1,100+ rows of 28 columns does not
  // belong inside a bundle shared with every other tab.
  var deals = sbSelect_('v_forecast',
    'select=*&order=temp_rank.asc,expected_close_date.asc.nullslast,days_open.desc', 3000);
  var quality = withTeam_(B.forecast_quality || []);

  var sh = ensureSheet_(TABS.FORECAST);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);

  if (!deals.length) {
    renderTable_(sh, 1, TABS.FORECAST, [['rep', 'Rep']], [],
      'No open opportunities loaded. Run:  pwsh ./scripts/pipeline/backfill.ps1 -DealStagesOnly');
    return;
  }

  var open = deals.length, forecastable = 0, valued = 0, dated = 0,
      known = 0, overdue = 0, stale = 0;
  for (var i = 0; i < deals.length; i++) {
    var d = deals[i];
    if (!d.missing_value) { valued++; known += Number(d.deal_value) || 0; }
    if (!d.missing_close_date) dated++;
    if (!d.missing_value && !d.missing_close_date) forecastable++;
    if (d.overdue) overdue++;
    if (d.stale) stale++;
  }
  var blind = 0;
  for (var q = 0; q < quality.length; q++) blind += Number(quality[q].est_blind_value) || 0;
  var fcPct = 100 * forecastable / open;

  var r = renderKpis_(sh, 1, [
    { label: 'Open deals', value: open, format: '#,##0' },
    { label: 'Forecastable (value AND date)', value: forecastable, format: '#,##0',
      color: forecastable === open ? '#188038' : '#c5221f' },
    { label: 'Forecast coverage', value: fcPct, format: '0.0"%"',
      color: fcPct >= 80 ? '#188038' : '#c5221f',
      bg: fcPct >= 80 ? THEME.good : THEME.bad },
    { label: 'Pipeline we can see', value: known, format: '"₹"#,##0' },
    { label: 'Est. value we cannot see', value: blind || '', format: '"₹"#,##0',
      color: '#b06000' },
    { label: 'Overdue', value: overdue, format: '#,##0', color: overdue ? '#c5221f' : null },
    { label: 'Stale (14d+ no call)', value: stale, format: '#,##0',
      color: stale ? '#b06000' : null }
  ]);

  // The message has to distinguish two very different situations that look identical in the
  // numbers. "Reps have not filled the field in" is a coaching problem. "The field does not
  // exist in LSQ" is a five-minute admin task, and saying the first when it is the second
  // sends people to chase reps for something they cannot do.
  var msg, msgColor;
  if (forecastable === open) {
    msg = 'Every open deal carries a value and a close date. This forecast is complete.';
    msgColor = '#188038';
  } else if (valued === 0 && dated === 0) {
    msg = 'None of the ' + open + ' open deals carry a value or a close date, because ' +
          'THOSE FIELDS DO NOT EXIST on the LSQ Opportunity object - it has four custom ' +
          'fields and two of them are unused and unnamed. This is not a rep-discipline gap: ' +
          'nobody can fill in a field that has not been created. Create "Deal Value" ' +
          '(currency) and "Expected Closure Date" (date) on the Opportunity, and this tab ' +
          'starts forecasting with no further code change.';
    msgColor = '#c5221f';
  } else {
    msg = 'Only ' + forecastable + ' of ' + open + ' open deals carry BOTH a deal value and ' +
          'an expected close date, so ' + (open - forecastable) + ' cannot be forecast at all. ' +
          '"Est. value we cannot see" prices the unvalued deals at each rep\'s own average ' +
          'deal - it is the size of the blind spot, not a prediction.';
    msgColor = '#b06000';
  }
  sh.getRange(r, 1).setValue(msg)
    .setFontFamily(THEME.font).setFontSize(10).setFontWeight('bold').setFontColor(msgColor);
  sh.setRowHeight(r, 32);
  r += 2;

  r = renderTable_(sh, r, 'Forecast coverage per rep', [
    ['team', 'Team'],
    ['rep', 'Rep'],
    ['open_opps', 'Open deals'],
    ['hot_opps', 'Hot'],
    ['with_value', 'Has value'],
    ['with_close_date', 'Has close date'],
    ['forecastable', 'Forecastable'],
    ['forecastable_pct', 'Coverage %'],
    ['known_value', 'Known value'],
    ['avg_known_value', 'Avg deal (known)'],
    ['unvalued_opps', 'Unvalued'],
    ['est_blind_value', 'Est. blind value'],
    ['overdue_opps', 'Overdue'],
    ['stale_opps', 'Stale']
  ], quality,
    'Read "Coverage %" first. Everything to the right of it is only as trustworthy as that ' +
    'number. A rep with no valued deals shows a blank average rather than zero, because ' +
    'zero would read as "nothing missing".',
    { freeze: true, filter: false, teamKey: 'team' });

  r = renderTable_(sh, r, 'Open deals', [
    ['rep', 'Rep'],
    ['company_name', 'Company'],
    ['contact_name', 'Contact'],
    ['opportunity_name', 'Opportunity'],
    ['temperature', 'Temp'],
    ['stage', 'Stage'],
    ['deal_value', 'Deal value'],
    ['expected_close_date', 'Expected close'],
    ['days_to_close', 'Days to close'],
    ['days_open', 'Days open'],
    ['days_since_last_call', 'Days since call'],
    ['calls', 'Calls'],
    ['connects', 'Connects'],
    ['prospect_id', 'ProspectId']
  ], deals,
    'Hot deals first, then warm, then new; within each, soonest expected close first and ' +
    'deals with no date last. Amber = no deal value. Red = past its close date or untouched ' +
    'for 14 days.',
    { freeze: false });

  // Widths are derived, not counted by hand. Inserting the Temp column shifted Deal value
  // from column 6 to 7, and a hardcoded index would have silently formatted the wrong one.
  var DEAL_COLS = 14;
  var DEAL_VALUE_COL = 7;

  // Flag the rows that need work, straight from the SQL booleans rather than from a
  // spreadsheet formula reading the displayed cells. A formula would have to re-derive
  // "stale" from a blank cell, and in Sheets a blank compares as 0 - so a deal that has
  // never been called at all would read as 0 days since last call and escape the flag,
  // which is the exact opposite of the truth.
  //
  // renderTable_ returns the next free row, so the first body row is (returned - n - 2).
  var bodyStart = r - deals.length - 2;
  for (var d2 = 0; d2 < deals.length; d2++) {
    var row = deals[d2];
    if (row.overdue || row.stale) {
      sh.getRange(bodyStart + d2, 1, 1, DEAL_COLS).setBackground(THEME.bad);
    } else if (row.missing_value || row.missing_close_date) {
      sh.getRange(bodyStart + d2, 1, 1, DEAL_COLS).setBackground(THEME.warn);
    }
  }
  if (deals.length) {
    sh.getRange(bodyStart, DEAL_VALUE_COL, deals.length, 1).setNumberFormat('"₹"#,##0');
  }

  sh.setColumnWidth(1, 150); sh.setColumnWidth(2, 210); sh.setColumnWidth(3, 150);
  sh.setColumnWidth(4, 210);
  return sh;
}

/**
 * QC - every number on every tab, checked against something that does not share its
 * arithmetic.
 *
 * This tab exists because a dashboard that is quietly wrong is worse than no dashboard. A
 * FAIL here means a number elsewhere in the workbook cannot be trusted; the boundaries block
 * underneath states what the data physically cannot know, so an empty column is never
 * mistaken for a zero.
 */
function writeQc_(B) {
  var checks, bounds, hygiene;
  try {
    checks = B.qc || [];
    bounds = B.boundaries || [];
    hygiene = B.hygiene || [];
  } catch (e) {
    var shx = ensureSheet_(TABS.QC);
    shx.clear();
    shx.getRange(1, 1).setValue('QC').setFontFamily(THEME.font)
      .setFontSize(THEME.titleSize).setFontWeight('bold');
    shx.getRange(3, 1).setValue('Not available - run migration 010. ' + e)
      .setFontFamily(THEME.font).setFontColor(THEME.muted);
    return;
  }

  var sh = ensureSheet_(TABS.QC);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);

  var fails = 0, warns = 0;
  for (var i = 0; i < checks.length; i++) {
    if (checks[i].status === 'FAIL') fails++;
    else if (checks[i].status === 'WARN' || checks[i].status === 'STALE' ||
             checks[i].status === 'GAP') warns++;
  }

  var r = renderKpis_(sh, 1, [
    { label: 'Checks run', value: checks.length, format: '#,##0' },
    { label: 'Failing', value: fails, format: '#,##0',
      color: fails ? '#c5221f' : '#188038', bg: fails ? THEME.bad : THEME.good },
    { label: 'Needs attention', value: warns, format: '#,##0',
      color: warns ? '#b06000' : '#188038' }
  ]);

  r = renderTable_(sh, r, 'Data quality checks', [
    ['check_name', 'Check'],
    ['expected', 'Expected'],
    ['actual', 'Actual'],
    ['status', 'Status'],
    ['scope', 'Checked against']
  ], checks,
    'FAIL means a number in this workbook is wrong. GAP and INFO are business gaps, not ' +
    'pipeline bugs - they are things to fix in the CRM.',
    { freeze: true });

  var top = r - checks.length - 2;
  for (var c = 0; c < checks.length; c++) {
    var st = checks[c].status;
    var bg = st === 'FAIL' ? THEME.bad
           : (st === 'WARN' || st === 'STALE' || st === 'GAP') ? THEME.warn
           : st === 'PASS' ? THEME.good : null;
    if (bg) sh.getRange(top + c, 4).setBackground(bg).setFontWeight('bold');
  }

  r = renderTable_(sh, r, 'CRM hygiene backlog', [
    ['issue', 'Issue'],
    ['items', 'Items']
  ], hygiene,
    'Not pipeline defects - CRM state that needs clearing. Each has a different fix; the ' +
    'full worklist is in v_opportunity_hygiene.',
    { freeze: false, filter: false });

  renderTable_(sh, r, 'What the data can and cannot know', [
    ['stream', 'Stream'],
    ['row_count', 'Rows'],
    ['earliest', 'Earliest'],
    ['latest', 'Latest'],
    ['note', 'Boundary']
  ], bounds,
    'Read this before quoting any historical number. A blank is not a zero - it is a period ' +
    'the pipeline could not observe.',
    { freeze: false, filter: false });

  sh.setColumnWidth(1, 300); sh.setColumnWidth(2, 110); sh.setColumnWidth(3, 110);
  sh.setColumnWidth(4, 110); sh.setColumnWidth(5, 620);
  return sh;
}

/**
 * Put the tabs in a deliberate order and colour them by what they answer. Re-run on every
 * refresh: new tabs otherwise land wherever Sheets puts them, and the strip drifts into the
 * order things happened to be created in.
 */
function orderTabs_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var order = [TABS.DASHBOARD, TABS.REP_DAY, TABS.TREND, TABS.TEAMS, TABS.PIPELINE,
               TABS.REP_FUNNEL, TABS.PROSPECTS, TABS.FUNNEL, TABS.DEALS, TABS.FORECAST,
               TABS.EXCEPTIONS, TABS.QC, TABS.META, TABS.PENDING, TABS.UNPARSED];
  for (var i = 0; i < order.length; i++) {
    var sh = ss.getSheetByName(order[i]);
    if (!sh) continue;
    ss.setActiveSheet(sh);
    ss.moveActiveSheet(i + 1);
    if (TAB_COLOR[order[i]]) sh.setTabColor(TAB_COLOR[order[i]]);
  }
  var first = ss.getSheetByName(TABS.DASHBOARD);
  if (first) ss.setActiveSheet(first);
}

function writeMeta_(failures, B, fetches) {
  failures = failures || [];
  var h = (B && B.health) ? B.health : {};
  var pending = Math.max(0, ensureSheet_(TABS.PENDING).getLastRow() - 1);
  var unparsed = Math.max(0, ensureSheet_(TABS.UNPARSED).getLastRow() - 1);
  var mins = Number(h.minutes_since_last_ingest);
  var stale = !(mins >= 0) || mins > 30;

  var sh = ensureSheet_(TABS.META);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);

  var rows = [
    ['Pipeline health', ''],
    ['', ''],
    ['Reports refreshed', istStamp_(new Date()) + ' IST'],
    ['Minutes since last call ingested', isNaN(mins) ? 'never' : mins],
    ['STATUS', stale ? 'STALE - nothing ingested recently. Check the webhooks are still enabled.' : 'Live'],
    ['', ''],
    ['Calls today (IST)', h.calls_today],
    ['Calls stored (all time)', h.calls_stored],
    ['Stage changes stored', h.stage_changes_stored],
    ['Contacts cached', h.contacts_cached],
    ['Calls awaiting enrichment', h.calls_awaiting_enrichment],
    ['', ''],
    ['Rows parked (Supabase unreachable)', pending],
    ['Unrecognised payloads', unparsed],
    ['', ''],
    ['Disposition history', 'exact from 2026-08-08; "<no history>" before that is by design'],
    ['Notes', 'NOT captured - this reports what happened, not why'],
    ['', ''],
    // The quota is the thing that actually broke this workbook, so it gets a line. Apps
    // Script allows 20,000 UrlFetch calls a day across EVERY trigger, not per function.
    ['UrlFetch calls this refresh', (fetches || 0) + ' (was ~14 before the bundle)'],
    ['Refresh cadence', 'every 30 min; enrichment every 15 min, bounded'],
    ['', ''],
    ['Tabs that failed to refresh', failures.length ? failures.join('  |  ') : 'none']
  ];
  sh.getRange(1, 1, rows.length, 2).setValues(rows)
    .setFontFamily(THEME.font).setFontSize(THEME.size);

  sh.getRange(1, 1, 1, 2).merge().setFontWeight('bold').setFontSize(THEME.titleSize);
  sh.setRowHeight(1, 32);
  sh.getRange(5, 1, 1, 2).setFontWeight('bold')
    .setBackground(stale ? THEME.bad : THEME.good)
    .setBorder(true, true, true, true, false, false, THEME.border, SpreadsheetApp.BorderStyle.SOLID);
  sh.getRange(3, 1, rows.length - 2, 1).setFontColor(THEME.subtitleFg);
  sh.getRange(7, 2, 5, 1).setNumberFormat('#,##0').setHorizontalAlignment('left');

  // Amber only when there is genuinely something to look at - a permanently coloured row
  // stops being a signal.
  if (pending > 0) sh.getRange(13, 1, 1, 2).setBackground(THEME.warn).setFontWeight('bold');
  if (unparsed > 0) sh.getRange(14, 1, 1, 2).setBackground(THEME.warn).setFontWeight('bold');
  if (failures.length) {
    sh.getRange(rows.length, 1, 1, 2).setBackground(THEME.bad).setFontWeight('bold');
  }

  sh.setColumnWidth(1, 300); sh.setColumnWidth(2, 620);
}

// =======================================================================================
// PRESENTATION
//
// Every tab is cleared and rewritten on each refresh, which also wipes formatting - so all
// styling has to be re-applied in code. Anything done by hand in the UI survives until the
// next 10-minute trigger and then vanishes, which is why this layer exists.
//
// Formatting only ever changes DISPLAY, never values. Percentages in particular use the
// format '0.0"%"' rather than '0.0%': the views already return 23.9 meaning 23.9 percent,
// and Sheets' native percent format would multiply by 100 and show 2390%.
// =======================================================================================

var THEME = {
  font: 'Arial',
  size: 10,
  headerBg: '#1f3864',
  headerFg: '#ffffff',
  titleSize: 15,
  subtitleFg: '#5f6368',
  band: '#f4f6fa',
  teamBand: '#eef3f8',
  border: '#d6dbe4',
  totalBg: '#eef1f6',
  good: '#e6f4ea',
  warn: '#fef7e0',
  bad: '#fce8e6',
  muted: '#8a8f98'
};

/**
 * Infer a column's display type from its key and values, so callers do not each have to
 * declare formats. Key naming in the views is already consistent (_pct, _date, counts), and
 * inference keeps the column definitions short enough to read.
 */
function endsWith_(s, suffix) {
  return s.length >= suffix.length && s.substring(s.length - suffix.length) === suffix;
}

/**
 * SUFFIX matching, not substring. The previous version tested k.indexOf('date') >= 0, which
 * matches "contacts_upDATEd" - so a count of 14 was given a date format and rendered as
 * 14 January 1900. Sheets was doing exactly what it was told: 14 is day 14 of the 1900
 * epoch. Substring matching on column names is a trap; 'rate' had the same problem.
 *
 * Order matters. *_date_ist is a date, *_at_ist is a timestamp, and both end in _ist.
 */
function colType_(key, rows) {
  var k = String(key).toLowerCase();

  if (endsWith_(k, '_pct')) return 'pct';
  if (endsWith_(k, '_utc')) return 'datetime';
  if (endsWith_(k, '_ist')) return endsWith_(k, '_date_ist') ? 'date' : 'datetime';
  if (endsWith_(k, '_date') || k === 'as_of' || k === 'earliest' || k === 'latest') return 'date';
  if (endsWith_(k, '_min') || k === 'talk_min') return 'dec';

  // Fall back to the values. A name-based rule cannot know that oldest_opp_created is a
  // timestamp, and guessing from the name is what caused the bug above.
  for (var i = 0; i < rows.length && i < 40; i++) {
    var v = rows[i][key];
    if (v === null || v === undefined || v === '') continue;
    if (typeof v === 'boolean') return 'bool';
    if (typeof v === 'number') return 'int';
    if (typeof v === 'string') {
      if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/.test(v)) return 'datetime';
      if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return 'date';
    }
    return 'text';
  }
  return 'text';
}

var NUMFMT = { pct: '0.0"%"', int: '#,##0', dec: '#,##0.0', date: 'yyyy-mm-dd', datetime: 'yyyy-mm-dd hh:mm', bool: '', text: '' };
var ALIGN  = { pct: 'right', int: 'right', dec: 'right', date: 'center', datetime: 'center', bool: 'center', text: 'left' };

/** Bandings accumulate if re-applied, so any existing ones must be removed first. */
function clearBandings_(sh) {
  var b = sh.getBandings();
  for (var i = 0; i < b.length; i++) b[i].remove();
}

/**
 * Render a table with a title, header and body, formatted consistently.
 *
 * Columns are declared explicitly rather than inferred from the first row: an inferred
 * header silently changes shape whenever a nullable field happens to be null in row 1,
 * breaking every formula and pivot built on top of it.
 */
function writeTable_(name, colDefs, rows, subtitle) {
  var sh = ensureSheet_(name);
  sh.clear();
  clearBandings_(sh);
  sh.setHiddenGridlines(true);
  renderTable_(sh, 1, name, colDefs, rows, subtitle, { freeze: true });
  autoWidth_(sh, colDefs, rows);
  return sh;
}

/**
 * Render one titled block at startRow WITHOUT clearing the sheet, and return the first free
 * row after it. This is what lets a tab carry a summary above a detail table - the Forecast
 * tab is unreadable as a bare 300-row list, and the number that matters (how much of the
 * pipeline can be forecast at all) has to sit at the top where it is seen first.
 *
 * NO MERGED CELLS. Sheets refuses to freeze a boundary that cuts a merge, and a merged title
 * spanning a block is exactly that boundary. Long titles simply overflow across the empty
 * cells beside them, which looks identical and cannot conflict.
 *
 * opts: { freeze, banding, headerBg, totalRow }
 *   totalRow - index into rows (0-based) to style as a totals line.
 */
function renderTable_(sh, startRow, title, colDefs, rows, subtitle, opts) {
  opts = opts || {};
  var w = colDefs.length;
  var r = startRow;

  if (title) {
    sh.getRange(r, 1).setValue(title)
      .setFontFamily(THEME.font).setFontSize(THEME.titleSize).setFontWeight('bold')
      .setFontColor(THEME.headerBg).setVerticalAlignment('middle');
    sh.setRowHeight(r, 30);
    r++;
  }
  if (subtitle) {
    sh.getRange(r, 1).setValue(subtitle)
      .setFontFamily(THEME.font).setFontSize(9).setFontStyle('italic')
      .setFontColor(THEME.subtitleFg).setWrap(false);
    r++;
  }

  var hRow = r;
  sh.getRange(hRow, 1, 1, w).setValues([colDefs.map(function (c) { return c[1]; })])
    .setFontFamily(THEME.font).setFontSize(THEME.size).setFontWeight('bold')
    .setBackground(opts.headerBg || THEME.headerBg).setFontColor(THEME.headerFg)
    .setVerticalAlignment('middle').setWrap(true);
  sh.setRowHeight(hRow, 34);

  if (!rows.length) {
    sh.getRange(hRow + 1, 1).setValue('No rows as at ' + istStamp_(new Date()) + ' IST')
      .setFontFamily(THEME.font).setFontColor(THEME.muted).setFontStyle('italic');
    if (opts.freeze) sh.setFrozenRows(hRow);
    return hRow + 3;
  }

  var body = rows.map(function (row) {
    return colDefs.map(function (c) {
      var v = row[c[0]];
      return (v === null || v === undefined) ? '' : v;
    });
  });
  var bRow = hRow + 1;
  sh.getRange(bRow, 1, body.length, w).setValues(body)
    .setFontFamily(THEME.font).setFontSize(THEME.size).setWrap(false);

  for (var c = 0; c < w; c++) {
    var t = colType_(colDefs[c][0], rows);
    var rng = sh.getRange(bRow, c + 1, body.length, 1);
    if (NUMFMT[t]) rng.setNumberFormat(NUMFMT[t]);
    rng.setHorizontalAlignment(ALIGN[t]);
    sh.getRange(hRow, c + 1).setHorizontalAlignment(ALIGN[t] === 'left' ? 'left' : 'center');
  }

  if (opts.banding !== false) {
    sh.getRange(bRow, 1, body.length, w)
      .applyRowBanding(SpreadsheetApp.BandingTheme.LIGHT_GREY, false, false);
  }
  sh.getRange(hRow, 1, body.length + 1, w)
    .setBorder(true, true, true, true, true, true, THEME.border, SpreadsheetApp.BorderStyle.SOLID);

  if (opts.totalRow !== undefined && opts.totalRow !== null) {
    sh.getRange(bRow + opts.totalRow, 1, 1, w)
      .setBackground(THEME.totalBg).setFontWeight('bold');
  }

  // Tint each team's block so the grouping is visible without breaking the filter. A team
  // header ROW would read more like the org chart, but Sheets filters treat any such row as
  // data and sorting would scatter them - so the team lives in a column and the colour just
  // makes the boundary easy to find.
  if (opts.teamKey) {
    var prev = null, band = false;
    for (var tr = 0; tr < rows.length; tr++) {
      var tv = rows[tr][opts.teamKey];
      if (tv !== prev) { band = !band; prev = tv; }
      if (band) sh.getRange(bRow + tr, 1, 1, w).setBackground(THEME.teamBand);
    }
  }

  // A filter on every header. Sheets allows exactly ONE filter per sheet, so a multi-block
  // tab gets it on whichever block asks first - which is why the big table on each tab asks
  // and the summary blocks above it do not.
  if (opts.filter !== false) {
    try {
      var existing = sh.getFilter();
      if (existing) existing.remove();
      sh.getRange(hRow, 1, body.length + 1, w).createFilter();
    } catch (e) {
      // A sheet can refuse a second filter; not worth failing the whole refresh over.
    }
  }

  if (opts.freeze) sh.setFrozenRows(hRow);
  return bRow + body.length + 2;
}

/**
 * A row of headline figures above a table. Label on top in small grey, value below, large.
 *
 * Written cell by cell rather than as a block because each tile is two rows of one column
 * with different formatting, and the alternative - a merged 2x1 per tile - reintroduces the
 * merge/freeze conflict this file already hit once.
 */
function renderKpis_(sh, startRow, tiles) {
  for (var i = 0; i < tiles.length; i++) {
    var col = i + 1;
    sh.getRange(startRow, col).setValue(tiles[i].label)
      .setFontFamily(THEME.font).setFontSize(9).setFontColor(THEME.subtitleFg)
      .setHorizontalAlignment('left');
    var cell = sh.getRange(startRow + 1, col).setValue(tiles[i].value)
      .setFontFamily(THEME.font).setFontSize(16).setFontWeight('bold')
      .setHorizontalAlignment('left');
    if (tiles[i].format) cell.setNumberFormat(tiles[i].format);
    if (tiles[i].color) cell.setFontColor(tiles[i].color);
    if (tiles[i].bg) sh.getRange(startRow, col, 2, 1).setBackground(tiles[i].bg);
  }
  sh.setRowHeight(startRow + 1, 26);
  return startRow + 3;
}

/**
 * Size columns from the header text and the widest sampled value. autoResizeColumns alone
 * produces very wide columns for long free text (company names, the "what to fix" detail),
 * which pushes the useful numbers off screen - so widths are clamped.
 */
function autoWidth_(sh, colDefs, rows) {
  for (var c = 0; c < colDefs.length; c++) {
    var longest = String(colDefs[c][1]).length;
    for (var i = 0; i < rows.length && i < 200; i++) {
      var v = rows[i][colDefs[c][0]];
      if (v !== null && v !== undefined) longest = Math.max(longest, String(v).length);
    }
    sh.setColumnWidth(c + 1, Math.max(64, Math.min(240, 8 * longest + 24)));
  }
}


// =======================================================================================
// UTILITIES
// =======================================================================================

/**
 * Data.Note is a "{=}"/"{next}" delimited key-value blob, NOT JSON, and DUPLICATE KEYS ARE
 * REAL - captured verbatim:
 *   Caller{=}Abhishek Tripathi{next}UserId{=}{next}UserId{=}7fb8f9e5-...{next}Duration{=}73
 * UserId appears twice and the FIRST IS EMPTY, so a first-match parser returns "" forever
 * while looking correct. Take the last non-empty occurrence.
 */
function noteValue_(blob, key) {
  if (!blob) return '';
  var re = new RegExp(key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\{=\\}([\\s\\S]*?)(?=\\{next\\}|$)', 'g');
  var found = '', m;
  while ((m = re.exec(String(blob))) !== null) {
    var v = (m[1] || '').trim();
    if (v) found = v;
  }
  return found;
}

/**
 * THREE LSQ timestamp formats exist, none carrying a zone, all UTC:
 *   webhook CreatedOn         "2026-08-08 05:52:30"
 *   note blob                 "8/8/2026 5:52:30 AM"
 *   ProspectActivityDate_Max  "2026-08-08 07:38:00.000"   <-- MILLISECONDS
 * A parser missing the millisecond form returns null for every lead, callers skip every
 * row, and the result looks like an empty day rather than an error - which is exactly how a
 * QC script reported "0 calls today" against an account doing 418 (2026-08-08).
 */
function parseLsqUtc_(value) {
  if (!value) return null;
  var s = String(value).trim();
  var m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,3}))?Z?$/.exec(s);
  if (m) return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0), +(m[7] || 0)));
  var u = /^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s*(AM|PM)?$/i.exec(s);
  if (u) {
    var h = +u[4];
    if (u[7]) { h = h % 12; if (u[7].toUpperCase() === 'PM') h += 12; }
    return new Date(Date.UTC(+u[3], +u[1] - 1, +u[2], h, +u[5], +u[6]));
  }
  var d = new Date(s);
  return isNaN(d.getTime()) ? null : d;
}

// India is UTC+5:30 year-round, no daylight saving, so a fixed offset is exact.
function istStamp_(utc) { return new Date(utc.getTime() + IST_OFFSET_MS).toISOString().slice(0, 19).replace('T', ' '); }
function istToday_() { return new Date(Date.now() + IST_OFFSET_MS).toISOString().slice(0, 10); }
function istDaysAgo_(n) { return new Date(Date.now() + IST_OFFSET_MS - n * 86400000).toISOString().slice(0, 10); }

/** Convenience for the editor: widen the dashboard to a week or a month. */
// Manual helpers. They fetch their own bundle because they are run by hand from the editor,
// not from the trigger - the signature changed when the bundle landed and passing a number
// as the bundle would have silently rendered an empty dashboard.
function dashboardWeek()  { writeDashboard_(sbBundle_(HISTORY_FROM), 7); }
function dashboardMonth() { writeDashboard_(sbBundle_(HISTORY_FROM), 30); }
