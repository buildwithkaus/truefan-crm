/**
 * TrueFan CRM - live calling dashboard (Apps Script web app).
 *
 * Serves a single page that subscribes to Supabase Realtime and updates as calls land.
 *
 * WHY APPS SCRIPT HOSTS THIS: deploying as "Execute as: Me / Who has access: Anyone within
 * <domain>" gives Google Workspace authentication for free. No login to build, no separate
 * host to pay for or own, and the page is unreachable from outside the company - which is
 * what makes it acceptable to hand the browser a Supabase key at all.
 *
 * KEY HANDLING: the page receives the ANON key, never the service role key. The anon key is
 * constrained by RLS (003_rls.sql) to the reporting views plus the last 48 hours of
 * fact_call, which is the minimum Realtime needs. SheetsSync.gs uses the service key, but
 * that runs server-side and its value never reaches a browser.
 *
 * SETUP:
 *   1. Script Properties:  SUPABASE_URL, SUPABASE_ANON_KEY
 *   2. Deploy > New deployment > Web app
 *        Execute as:      Me
 *        Who has access:  Anyone within <your domain>
 */

function doGet() {
  var props = PropertiesService.getScriptProperties();
  var url = props.getProperty('SUPABASE_URL');
  var anon = props.getProperty('SUPABASE_ANON_KEY');

  if (!url || !anon) {
    return HtmlService.createHtmlOutput(
      '<p style="font:14px system-ui;padding:24px">' +
      'Not configured. Set <code>SUPABASE_URL</code> and <code>SUPABASE_ANON_KEY</code> ' +
      'in Project Settings &gt; Script Properties.</p>'
    );
  }

  var t = HtmlService.createTemplateFromFile('Dashboard');
  t.supabaseUrl = url;
  t.supabaseAnonKey = anon;

  return t.evaluate()
    .setTitle('TrueFan - Live Calling')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}
