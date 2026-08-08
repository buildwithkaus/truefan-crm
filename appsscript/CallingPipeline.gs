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

var TABS = {
  DASHBOARD: 'Dashboard',
  REP_DAY: 'Rep Day',
  TREND: 'Daily Trend',
  FUNNEL: 'Funnel',
  EXCEPTIONS: 'Exceptions',
  PROSPECTS: 'Prospects',
  META: 'Meta',
  PENDING: 'Pending',      // webhook rows Supabase refused; retried by trigger
  UNPARSED: 'Unparsed'     // payload shapes the parser did not recognise
};

var IST_OFFSET_MS = 330 * 60 * 1000;

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
  ScriptApp.newTrigger('refreshReports').timeBased().everyMinutes(10).create();
  ScriptApp.newTrigger('enrichLeads').timeBased().everyMinutes(10).create();
  ScriptApp.newTrigger('flushPending').timeBased().everyMinutes(5).create();
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
  maxLeads = maxLeads || 200;

  var missing = sbSelect_('fact_call',
    'select=prospect_id&order=called_at_utc.desc&limit=4000', 4000);
  var known = {};
  var cached = sbSelect_('dim_contact', 'select=prospect_id', 50000);
  for (var i = 0; i < cached.length; i++) known[cached[i].prospect_id] = true;

  var wanted = [], seen = {};
  for (var j = 0; j < missing.length; j++) {
    var pid = missing[j].prospect_id;
    if (!pid || seen[pid] || known[pid]) continue;
    seen[pid] = true;
    wanted.push(pid);
    if (wanted.length >= maxLeads) break;
  }

  // Nothing new? Refresh today's contacts instead, so stage/disposition stay current.
  if (wanted.length === 0) {
    var todays = sbSelect_('fact_call',
      'select=prospect_id&call_date_ist=eq.' + istToday_() + '&limit=1000', 1000);
    var s2 = {};
    for (var t = 0; t < todays.length && wanted.length < maxLeads; t++) {
      var p2 = todays[t].prospect_id;
      if (p2 && !s2[p2]) { s2[p2] = true; wanted.push(p2); }
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
  try {
    writeDashboard_();
    writeRepDay_();
    writeTrend_();
    writeFunnel_();
    writeExceptions_();
    writeProspects_();
    writeMeta_();
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
function writeDashboard_(days) {
  days = days || 1;
  var from = istDaysAgo_(days - 1);
  var pivot = sbSelect_('v_pivot_disposition',
    'select=*&call_date_ist=gte.' + from + '&order=rep.asc', 20000);
  var totals = sbSelect_('v_daily_totals',
    'select=*&report_date=gte.' + from + '&order=report_date.desc', 400);

  var sh = ensureSheet_(TABS.DASHBOARD);
  sh.clear();

  // ---- KPI strip -------------------------------------------------------------------
  var dials = 0, connects = 0, contacts = 0, talk = 0, reps = 0;
  for (var i = 0; i < totals.length; i++) {
    dials += Number(totals[i].dials) || 0;
    connects += Number(totals[i].connects) || 0;
    contacts += Number(totals[i].contacts) || 0;
    talk += Number(totals[i].talk_min) || 0;
    reps = Math.max(reps, Number(totals[i].active_reps) || 0);
  }
  sh.getRange(1, 1).setValue(days === 1 ? ('Calling dashboard - ' + istToday_() + ' (IST)')
                                        : ('Calling dashboard - last ' + days + ' days'))
    .setFontSize(14).setFontWeight('bold');
  sh.getRange(2, 1).setValue('Refreshed ' + istStamp_(new Date()) + ' IST')
    .setFontColor('#5f6368').setFontStyle('italic');

  var kpi = [
    ['Dials', dials], ['Connected', connects],
    ['Connect %', dials ? Math.round(1000 * connects / dials) / 10 : 0],
    ['Contacts', contacts], ['Talk (min)', Math.round(talk)], ['Active reps', reps]
  ];
  for (var k = 0; k < kpi.length; k++) {
    sh.getRange(4, k + 1).setValue(kpi[k][0]).setFontSize(9).setFontColor('#5f6368');
    sh.getRange(5, k + 1).setValue(kpi[k][1]).setFontSize(18).setFontWeight('bold');
  }

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

  var top = 7;
  sh.getRange(top, 1).setValue('Calls by rep, stage at time of call, and disposition')
    .setFontWeight('bold');
  sh.getRange(top + 1, 1).setValue('* = value is not a selectable dropdown option in LSQ, so reps cannot filter on it')
    .setFontColor('#5f6368').setFontStyle('italic').setFontSize(9);

  var header = ['Rep', 'Stage at call'].concat(cols).concat(['Total']);
  var grid = [header];
  var lastRep = null;
  for (var q = 0; q < keys.length; q++) {
    var parts = keys[q].split('||');
    var row = [parts[0] === lastRep ? '' : parts[0], parts[1]];
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

  if (grid.length === 1) {
    sh.getRange(top + 2, 1).setValue('(no calls in range - check the Meta tab)').setFontColor('#5f6368');
    return;
  }
  var hRow = top + 2;
  sh.getRange(hRow, 1, grid.length, header.length).setValues(grid);
  sh.getRange(hRow, 1, 1, header.length).setFontWeight('bold').setBackground('#f1f3f4');
  sh.getRange(hRow + grid.length - 1, 1, 1, header.length).setFontWeight('bold').setBackground('#f8f9fa');
  sh.setFrozenRows(hRow);
  sh.autoResizeColumns(1, Math.min(header.length, 20));
}

function writeRepDay_() {
  var rows = sbSelect_('v_rep_day',
    'select=*&report_date=gte.' + istDaysAgo_(7) + '&order=report_date.desc,dials.desc', 3000);
  writeTable_(TABS.REP_DAY,
    [['report_date', 'Date'], ['rep', 'Rep'], ['dials', 'Dials'], ['contacts', 'Contacts'],
     ['connects', 'Connects'], ['connect_rate_pct', 'Connect %'], ['talk_min', 'Talk (min)'],
     ['inbound_calls', 'Inbound'],
     ['called_fresh', 'At Fresh'], ['called_engaged', 'At Engaged'], ['called_prospect', 'At Prospect'],
     ['called_customer', 'At Customer'], ['called_disqualified', 'At Disq'],
     ['contacts_updated', 'Updated'], ['discipline_pct', 'Discipline %'], ['clean_pct', 'Clean %'],
     ['gap_still_fresh', 'Gap: Fresh'], ['gap_no_disposition', 'Gap: No Disp'],
     ['gap_no_reason', 'Gap: No Reason'], ['gap_contradicts', 'Gap: Contradicts'],
     ['gap_bad_value', 'Gap: Bad Value']],
    rows,
    'Per rep per day, last 7 days. Read Clean % beside "Contradicts" - a jump straight after ' +
    'a batch cleanup means re-staging happened, not dispositioning.');
}

function writeTrend_() {
  var rows = sbSelect_('v_daily_totals', 'select=*&order=report_date.desc', 400);
  writeTable_(TABS.TREND,
    [['report_date', 'Date'], ['dials', 'Dials'], ['connects', 'Connects'],
     ['connect_rate_pct', 'Connect %'], ['contacts', 'Contacts'],
     ['active_reps', 'Active reps'], ['talk_min', 'Talk (min)']],
    rows, 'Whole-team totals by day. This is the month-over-month view.');
}

function writeFunnel_() {
  var rows = sbSelect_('v_funnel_movement',
    'select=*&report_date=gte.' + istDaysAgo_(30) + '&order=report_date.desc', 5000);
  writeTable_(TABS.FUNNEL,
    [['report_date', 'Date'], ['rep', 'Rep'], ['from_stage', 'From'], ['to_stage', 'To'],
     ['contacts', 'Contacts']],
    rows, 'Stage movement - calls measure effort, this measures progress.');
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
  if (rows.length) {
    sh.setConditionalFormatRules([
      SpreadsheetApp.newConditionalFormatRule().whenFormulaSatisfied('=$D3=1')
        .setBackground('#fce8e6').setRanges([sh.getRange(3, 1, rows.length, 14)]).build(),
      SpreadsheetApp.newConditionalFormatRule().whenFormulaSatisfied('=$D3=2')
        .setBackground('#fef7e0').setRanges([sh.getRange(3, 1, rows.length, 14)]).build()
    ]);
  }
}

function writeProspects_() {
  var rows = sbSelect_('v_funnel_movement',
    'select=*&to_stage=eq.Prospect&report_date=gte.' + istDaysAgo_(30) + '&order=report_date.desc', 2000);
  writeTable_(TABS.PROSPECTS,
    [['report_date', 'Date'], ['rep', 'Promoted by'], ['from_stage', 'From stage'],
     ['contacts', 'Contacts']],
    rows, 'Contacts promoted to Prospect. Sourced from stage-change history, so it is only ' +
          'as complete as the backfill and the stage-change webhook.');
}

function writeMeta_() {
  var h = sbSelect_('v_pipeline_health', 'select=*', 1)[0] || {};
  var pending = Math.max(0, ensureSheet_(TABS.PENDING).getLastRow() - 1);
  var unparsed = Math.max(0, ensureSheet_(TABS.UNPARSED).getLastRow() - 1);
  var mins = Number(h.minutes_since_last_ingest);
  var stale = !(mins >= 0) || mins > 30;

  var sh = ensureSheet_(TABS.META);
  sh.clear();
  sh.getRange(1, 1, 14, 2).setValues([
    ['TrueFan calling pipeline - health', ''],
    ['', ''],
    ['Reports refreshed', istStamp_(new Date()) + ' IST'],
    ['Minutes since last call ingested', isNaN(mins) ? 'never' : mins],
    ['STATUS', stale ? 'STALE - nothing ingested recently. Check the webhook is still enabled.' : 'Live'],
    ['', ''],
    ['Calls today (IST)', h.calls_today],
    ['Calls stored (all time)', h.calls_stored],
    ['Stage changes stored', h.stage_changes_stored],
    ['Contacts cached', h.contacts_cached],
    ['Calls awaiting enrichment', h.calls_awaiting_enrichment],
    ['', ''],
    ['Rows parked (Supabase was down)', pending],
    ['Unrecognised payloads', unparsed]
  ]);
  sh.getRange(1, 1).setFontWeight('bold').setFontSize(13);
  sh.getRange(5, 1, 1, 2).setFontWeight('bold').setBackground(stale ? '#fce8e6' : '#e6f4ea');
  if (pending > 0) sh.getRange(13, 1, 1, 2).setBackground('#fef7e0');
  if (unparsed > 0) sh.getRange(14, 1, 1, 2).setBackground('#fef7e0');
  sh.setColumnWidth(1, 300); sh.setColumnWidth(2, 560);
}

/** Columns are declared explicitly - an inferred header changes shape whenever a nullable
 *  field happens to be null in row 1, quietly breaking every formula built on top. */
function writeTable_(name, colDefs, rows, subtitle) {
  var sh = ensureSheet_(name);
  sh.clear();
  var header = colDefs.map(function (c) { return c[1]; });
  var out = [header];
  for (var i = 0; i < rows.length; i++) {
    out.push(colDefs.map(function (c) {
      var v = rows[i][c[0]];
      return (v === null || v === undefined) ? '' : v;
    }));
  }
  if (!rows.length) out.push(['(no rows as at ' + istStamp_(new Date()) + ' IST)']);
  var w = header.length;
  sh.getRange(1, 1, out.length, w).setValues(out.map(function (r) {
    var c = r.slice(); while (c.length < w) c.push(''); return c;
  }));
  sh.getRange(1, 1, 1, w).setFontWeight('bold').setBackground('#f1f3f4');
  sh.setFrozenRows(1);
  if (subtitle) {
    sh.insertRowBefore(1);
    sh.getRange(1, 1).setValue(subtitle).setFontStyle('italic').setFontColor('#5f6368');
    sh.setFrozenRows(2);
  }
  return sh;
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
function dashboardWeek() { writeDashboard_(7); }
function dashboardMonth() { writeDashboard_(30); }
