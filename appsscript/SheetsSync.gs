/**
 * TrueFan CRM - Google Sheets sync.
 *
 * Pulls the reporting views from Supabase over PostgREST and rewrites the workbook tabs.
 * Driven by a 5-minute time trigger; also runnable by hand from the Apps Script editor.
 *
 * Every tab is rewritten wholesale rather than appended to, so a run that overlaps another
 * or repeats after a failure converges to the same result instead of duplicating rows.
 *
 * SETUP (once):
 *   1. Extensions > Apps Script from the target spreadsheet.
 *   2. Project Settings > Script Properties, add:
 *        SUPABASE_URL          https://<project-ref>.supabase.co
 *        SUPABASE_SERVICE_KEY  <service role key>
 *      Script Properties are server-side and never reach the browser. The service key must
 *      not be pasted into a cell, a comment, or the dashboard HTML.
 *   3. Run installTriggers() once, and authorise when prompted.
 */

var TABS = {
  CONSOLIDATED: 'Consolidated',
  MASTER: 'Master',
  REP_DAY: 'Rep Day',
  EXCEPTIONS: 'Exceptions',
  PROSPECTS: 'Prospects',
  TREND: 'Trend',
  META: 'Meta'
};

var IST_OFFSET_MS = 330 * 60 * 1000;

// =======================================================================================
// Entry points
// =======================================================================================

function installTriggers() {
  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('syncAll').timeBased().everyMinutes(5).create();
  Logger.log('Trigger installed: syncAll every 5 minutes.');
}

function syncAll() {
  // Apps Script serialises executions of the same function, but a slow run plus a 5-minute
  // trigger can still overlap. Bail rather than queue - the next tick is 5 minutes away and
  // the data is cumulative, so skipping one is free.
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(5000)) {
    Logger.log('Another sync is running; skipping this tick.');
    return;
  }
  try {
    var started = new Date();
    writeConsolidated_();
    writeMaster_();
    writeRepDay_();
    writeExceptions_();
    writeProspects_();
    writeTrend_();
    writeMeta_(started);
    Logger.log('Sync complete in ' + (new Date() - started) + 'ms');
  } finally {
    lock.releaseLock();
  }
}

// =======================================================================================
// Supabase
// =======================================================================================

function cfg_(key) {
  var v = PropertiesService.getScriptProperties().getProperty(key);
  if (!v) throw new Error('Missing Script Property: ' + key);
  return v;
}

/**
 * Query a view. `query` is a PostgREST querystring, e.g. 'select=*&report_date=gte.2026-08-01'.
 * Rows are capped so a runaway view can never blow the Sheets cell limit or the 6-minute
 * execution budget.
 */
function fetchView_(view, query, limit) {
  var url = cfg_('SUPABASE_URL').replace(/\/+$/, '') + '/rest/v1/' + view + '?' + query;
  var res = UrlFetchApp.fetch(url, {
    method: 'get',
    headers: {
      apikey: cfg_('SUPABASE_SERVICE_KEY'),
      Authorization: 'Bearer ' + cfg_('SUPABASE_SERVICE_KEY'),
      Range: '0-' + ((limit || 5000) - 1)
    },
    muteHttpExceptions: true
  });
  var code = res.getResponseCode();
  if (code >= 300) {
    throw new Error('Supabase ' + view + ' HTTP ' + code + ': ' + res.getContentText().slice(0, 500));
  }
  return JSON.parse(res.getContentText());
}

// =======================================================================================
// Sheet writing
// =======================================================================================

function sheet_(name) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  return ss.getSheetByName(name) || ss.insertSheet(name);
}

/**
 * Write rows to a tab. Columns are declared explicitly rather than inferred from the first
 * row: an inferred header silently changes shape when a nullable field happens to be null
 * in row 1, which quietly breaks every downstream formula and pivot someone has built.
 */
function writeTable_(tabName, columns, rows, subtitle) {
  var sh = sheet_(tabName);
  sh.clear();

  var header = columns.map(function (c) { return c.label; });
  var out = [header];

  for (var i = 0; i < rows.length; i++) {
    var r = rows[i];
    out.push(columns.map(function (c) {
      var v = r[c.key];
      return (v === null || v === undefined) ? '' : v;
    }));
  }

  if (rows.length === 0) {
    // An empty tab must say WHY it is empty. A blank grid reads as "no calls today" when it
    // may equally mean the pipeline stopped four hours ago.
    out.push(['(no rows returned at ' + istStamp_(new Date()) + ')']);
  }

  sh.getRange(1, 1, out.length, header.length).setValues(padRows_(out, header.length));

  var head = sh.getRange(1, 1, 1, header.length);
  head.setFontWeight('bold').setBackground('#f1f3f4');
  sh.setFrozenRows(1);
  if (rows.length > 0) sh.autoResizeColumns(1, Math.min(header.length, 20));

  if (subtitle) {
    sh.insertRowBefore(1);
    sh.getRange(1, 1).setValue(subtitle).setFontStyle('italic').setFontColor('#5f6368');
    sh.setFrozenRows(2);
  }
  return sh;
}

function padRows_(rows, width) {
  return rows.map(function (r) {
    var copy = r.slice();
    while (copy.length < width) copy.push('');
    return copy;
  });
}

function istStamp_(d) {
  return Utilities.formatDate(new Date(d.getTime()), 'Asia/Kolkata', 'yyyy-MM-dd HH:mm:ss') + ' IST';
}

function istToday_() {
  return new Date(Date.now() + IST_OFFSET_MS).toISOString().slice(0, 10);
}

function istDaysAgo_(n) {
  return new Date(Date.now() + IST_OFFSET_MS - n * 86400000).toISOString().slice(0, 10);
}

// =======================================================================================
// Tabs
// =======================================================================================

function writeConsolidated_() {
  var rows = fetchView_(
    'v_rep_day',
    'select=*&report_date=gte.' + istDaysAgo_(7) + '&order=report_date.desc,dials.desc',
    2000
  );
  writeTable_(TABS.CONSOLIDATED, [
    { key: 'report_date', label: 'Date' },
    { key: 'rep_name', label: 'Rep' },
    { key: 'team', label: 'Team' },
    { key: 'dials', label: 'Dials' },
    { key: 'distinct_contacts', label: 'Contacts' },
    { key: 'connects', label: 'Connects' },
    { key: 'connect_rate_pct', label: 'Connect %' },
    { key: 'talk_time_min', label: 'Talk (min)' },
    { key: 'avg_connect_sec', label: 'Avg Conn (s)' },
    { key: 'inbound_calls', label: 'Inbound' },
    { key: 'called_fresh', label: 'Called: Fresh' },
    { key: 'called_engaged', label: 'Called: Engaged' },
    { key: 'called_prospect', label: 'Called: Prospect' },
    { key: 'called_customer', label: 'Called: Customer' },
    { key: 'called_disqualified', label: 'Called: Disq' },
    { key: 'moved_to_engaged', label: '-> Engaged' },
    { key: 'moved_to_prospect', label: '-> Prospect' },
    { key: 'moved_to_disqualified', label: '-> Disqualified' },
    { key: 'moved_to_customer', label: '-> Customer' },
    { key: 'contacts_worked', label: 'Worked' },
    { key: 'contacts_updated', label: 'Updated' },
    { key: 'stage_discipline_pct', label: 'Discipline %' },
    { key: 'compliance_score', label: 'Compliance %' },
    { key: 'gap_still_fresh', label: 'Gap: Still Fresh' },
    { key: 'gap_connected_no_disposition', label: 'Gap: No Disposition' },
    { key: 'gap_disqualified_no_reason', label: 'Gap: No Reason' },
    { key: 'gap_disposition_contradicts', label: 'Gap: Contradicts Log' },
    { key: 'gap_non_canonical_value', label: 'Gap: Bad Value' }
  ], rows,
    'Per rep per day, last 7 days. Read Discipline % alongside "Contradicts Log": a high ' +
    'discipline number after a batch cleanup is re-staging, not dispositioning.');
}

function writeMaster_() {
  var rows = fetchView_(
    'v_call_enriched',
    'select=*&call_date_ist=gte.' + istDaysAgo_(30) + '&order=called_at_ist.desc',
    5000
  );
  writeTable_(TABS.MASTER, [
    { key: 'call_date_ist', label: 'Date' },
    { key: 'called_at_ist', label: 'Time (IST)' },
    { key: 'actor_name', label: 'Rep (dialled)' },
    { key: 'contact_owner_name', label: 'Owner' },
    { key: 'is_owner_call', label: 'Own Book' },
    { key: 'company_name', label: 'Company' },
    { key: 'contact_name', label: 'Contact' },
    { key: 'phone', label: 'Phone' },
    { key: 'direction', label: 'Dir' },
    { key: 'status', label: 'Status' },
    { key: 'duration_sec', label: 'Duration (s)' },
    { key: 'connected', label: 'Connected' },
    { key: 'stage_at_call', label: 'Stage at Call' },
    { key: 'stage_after_call', label: 'Stage After' },
    { key: 'stage_updated_after_call', label: 'Updated?' },
    { key: 'call_disposition', label: 'Disposition' },
    { key: 'disqualification_reason', label: 'Disq Reason' },
    { key: 'call_note', label: 'Note' },
    { key: 'source', label: 'Source' },
    { key: 'recording_url', label: 'Recording' },
    { key: 'ingest_source', label: 'Ingest' },
    { key: 'prospect_id', label: 'Prospect ID' }
  ], rows,
    'One row per call, rolling 30 days. "Note" stays blank until a note destination is ' +
    'switched on - that is a known system gap, not missing rep input.');
}

function writeRepDay_() {
  var rows = fetchView_(
    'v_contact_day',
    'select=*&call_date_ist=eq.' + istToday_() + '&order=rep_name.asc,dials.desc',
    5000
  );
  writeTable_(TABS.REP_DAY, [
    { key: 'rep_name', label: 'Rep' },
    { key: 'company_name', label: 'Company' },
    { key: 'contact_name', label: 'Contact' },
    { key: 'phone', label: 'Phone' },
    { key: 'dials', label: 'Dials' },
    { key: 'connects', label: 'Connects' },
    { key: 'talk_time_sec', label: 'Talk (s)' },
    { key: 'contact_stage', label: 'Stage' },
    { key: 'call_disposition', label: 'Disposition' },
    { key: 'disqualification_reason', label: 'Disq Reason' },
    { key: 'updated_after_call', label: 'Updated?' },
    { key: 'flag_called_still_fresh', label: 'Still Fresh' },
    { key: 'flag_connected_no_disposition', label: 'No Disposition' },
    { key: 'flag_disqualified_no_reason', label: 'No Reason' },
    { key: 'flag_disposition_contradicts', label: 'Contradicts Log' },
    { key: 'prospect_id', label: 'Prospect ID' }
  ], rows, "Today's calls by contact, grouped by rep. IST date: " + istToday_());
}

function writeExceptions_() {
  var rows = fetchView_(
    'v_hygiene_exceptions',
    'select=*&report_date=gte.' + istDaysAgo_(3) + '&order=severity.asc,rep_name.asc',
    5000
  );
  var sh = writeTable_(TABS.EXCEPTIONS, [
    { key: 'report_date', label: 'Date' },
    { key: 'rep_name', label: 'Rep' },
    { key: 'flag', label: 'Issue' },
    { key: 'severity', label: 'Sev' },
    { key: 'detail', label: 'What to fix' },
    { key: 'company_name', label: 'Company' },
    { key: 'contact_name', label: 'Contact' },
    { key: 'phone', label: 'Phone' },
    { key: 'contact_stage', label: 'Stage' },
    { key: 'call_disposition', label: 'Disposition' },
    { key: 'disqualification_reason', label: 'Disq Reason' },
    { key: 'dials', label: 'Dials' },
    { key: 'connects', label: 'Connects' },
    { key: 'prospect_id', label: 'Prospect ID' }
  ], rows, 'The worklist. One row per violation, last 3 days, severity 1 first.');

  // Severity 1 in red: these are the ones that destroy information or actively mislead.
  if (rows.length > 0) {
    var rules = [
      SpreadsheetApp.newConditionalFormatRule()
        .whenFormulaSatisfied('=$D3=1').setBackground('#fce8e6')
        .setRanges([sh.getRange(3, 1, rows.length, 14)]).build(),
      SpreadsheetApp.newConditionalFormatRule()
        .whenFormulaSatisfied('=$D3=2').setBackground('#fef7e0')
        .setRanges([sh.getRange(3, 1, rows.length, 14)]).build()
    ];
    sh.setConditionalFormatRules(rules);
  }
}

function writeProspects_() {
  var rows = fetchView_(
    'v_prospects_created',
    'select=*&change_date_ist=gte.' + istDaysAgo_(14) + '&order=changed_at_utc.desc',
    2000
  );
  writeTable_(TABS.PROSPECTS, [
    { key: 'change_date_ist', label: 'Date' },
    { key: 'promoted_by', label: 'Promoted By' },
    { key: 'company_name', label: 'Company' },
    { key: 'contact_name', label: 'Contact' },
    { key: 'phone', label: 'Phone' },
    { key: 'previous_stage', label: 'From Stage' },
    { key: 'source', label: 'Source' },
    { key: 'preceding_call_at_ist', label: 'Call Before' },
    { key: 'preceding_call_duration_sec', label: 'That Call (s)' },
    { key: 'preceding_call_note', label: 'Note' },
    { key: 'prospect_id', label: 'Prospect ID' }
  ], rows, 'Every contact promoted to Prospect, last 14 days, with the call that preceded it.');
}

function writeTrend_() {
  var rows = fetchView_('v_trend', 'select=*&order=report_date.desc,rep_name.asc', 5000);
  writeTable_(TABS.TREND, [
    { key: 'report_date', label: 'Date' },
    { key: 'rep_name', label: 'Rep' },
    { key: 'dials', label: 'Dials' },
    { key: 'connects', label: 'Connects' },
    { key: 'connect_rate_pct', label: 'Connect %' },
    { key: 'contacts_worked', label: 'Worked' },
    { key: 'stage_discipline_pct', label: 'Discipline %' },
    { key: 'compliance_score', label: 'Compliance %' },
    { key: 'moved_to_prospect', label: '-> Prospect' },
    { key: 'gap_disposition_contradicts', label: 'Contradicts Log' }
  ], rows, '60-day history. Improvements that come from batch cleanups look identical to ' +
    'real improvement here - check whether "Contradicts Log" moved too.');
}

/**
 * The Meta tab. Non-negotiable: a stale report MUST announce itself. A pipeline that has
 * quietly stopped looks exactly like a slow sales day, and that class of silent failure has
 * already cost this project real time more than once.
 */
function writeMeta_(started) {
  var health = fetchView_('v_pipeline_health', 'select=*', 1)[0] || {};
  var sh = sheet_(TABS.META);
  sh.clear();

  var stale = (health.minutes_since_last_ingest === null ||
               health.minutes_since_last_ingest === undefined ||
               health.minutes_since_last_ingest > 15);

  var coverage = health.latest_webhook_coverage_pct;
  var rows = [
    ['TrueFan calling pipeline - status', ''],
    ['', ''],
    ['Sheet last refreshed', istStamp_(started)],
    ['Newest data ingested', health.last_fact_ingested_at ? istStamp_(new Date(health.last_fact_ingested_at)) : 'NEVER'],
    ['Minutes since last ingest', health.minutes_since_last_ingest],
    ['STATUS', stale ? 'STALE - data is not flowing, do not trust these numbers' : 'Live'],
    ['', ''],
    ['Calls today (IST)', health.calls_today],
    ['Webhooks received, last hour', health.webhooks_last_hour],
    ['Queue pending', health.queue_pending],
    ['Queue dead-lettered', health.queue_dead],
    ['Last successful reconcile', health.last_reconcile_ok_at ? istStamp_(new Date(health.last_reconcile_ok_at)) : 'NEVER'],
    ['', ''],
    ['Webhook coverage %', coverage === null || coverage === undefined ? 'not yet measured' : coverage],
    ['  What this means', coverageNote_(coverage)],
    ['', ''],
    ['Note capture enabled', health.note_capture_enabled ? 'yes' : 'no - "Note" columns are blank by design']
  ];

  sh.getRange(1, 1, rows.length, 2).setValues(rows);
  sh.getRange(1, 1).setFontWeight('bold').setFontSize(13);
  sh.getRange(6, 1, 1, 2).setFontWeight('bold')
    .setBackground(stale ? '#fce8e6' : '#e6f4ea');
  sh.setColumnWidth(1, 260);
  sh.setColumnWidth(2, 620);
}

function coverageNote_(pct) {
  if (pct === null || pct === undefined) return 'No reconcile has run yet.';
  if (pct >= 98) return 'Webhook is delivering. The reconciler is a genuine safety net.';
  if (pct >= 60) return 'Webhook is missing some events - the reconciler is filling real gaps. Investigate.';
  return 'Webhook is largely NOT firing. The reconciler is carrying the system; ' +
         'latency is up to an hour, not real time. Check the LSQ automation is published and enabled.';
}
