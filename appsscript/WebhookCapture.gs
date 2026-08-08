/**
 * THROWAWAY webhook capture endpoint.
 *
 * Purpose: find out what LeadSquared actually sends on "Lead Activity Creation", so the real
 * pipeline can be built against a known payload instead of a guessed one. Guessing a field
 * name is what silently skipped 20,076 leads on this account once already.
 *
 * It logs whatever arrives - query string, headers, raw body - to a sheet and always returns
 * HTTP 200. Returning 200 unconditionally matters: LeadSquared retries 3 times and then
 * DISABLES the webhook after 10 consecutive failures, so a capture tool that ever errors
 * would switch off the thing it is trying to observe.
 *
 * Delete this once the payload is known. It authenticates nothing and stores everything.
 *
 * ---------------------------------------------------------------------------------------
 * SETUP (about 5 minutes)
 *
 *  1. Create a new Google Sheet. Extensions > Apps Script.
 *  2. Delete the placeholder code, paste this file, Save.
 *  3. Deploy > New deployment > type "Web app"
 *       Execute as:      Me
 *       Who has access:  Anyone            <-- must be "Anyone", LSQ is unauthenticated here
 *     Authorise when prompted, then COPY THE WEB APP URL.
 *  4. In LeadSquared: My Account > Settings > API and Webhooks > Webhooks > Add Webhook
 *       Event:        Lead Activity Creation
 *       URL:          <the web app URL from step 3>
 *       Content type: JSON
 *       Save / enable.
 *  5. Place one real phone call from a rep's handset, or log any activity on a test lead.
 *  6. Wait ~2 minutes (activity webhooks are batched per minute, not instant).
 *  7. Look at the "Captured" tab in the sheet. Send the RawBody cell contents back.
 *
 * If nothing arrives after 5 minutes, that is itself the answer - see TROUBLESHOOTING below.
 * ---------------------------------------------------------------------------------------
 */

var CAPTURE_SHEET = 'Captured';

/**
 * LeadSquared's contract, from its own best-practices page - all three are load bearing:
 *
 *  1. ALWAYS return HTTP 200, even on error. Report failure in a StatusReason field
 *     instead. Any non-200 counts as a failure, and TEN CONSECUTIVE FAILURES DISABLE THE
 *     WEBHOOK. A capture tool that returns 4xx would switch off the thing it is observing.
 *  2. Verification is performed WITHOUT a payload. An endpoint that only answers when a
 *     body is present never gets verified and so never goes live.
 *  3. The recommended response shape is {"Status":"Success","StatusReason":""}.
 */
function doPost(e) {
  return capture_(e, 'POST');
}

function doGet(e) {
  return capture_(e, 'GET');
}

function ok_(reason) {
  return ContentService
    .createTextOutput(JSON.stringify({ Status: 'Success', StatusReason: reason || '' }))
    .setMimeType(ContentService.MimeType.JSON);
}

function capture_(e, method) {
  try {
    var hasBody = !!(e && e.postData && e.postData.contents);
    var hasParams = !!(e && e.parameter && Object.keys(e.parameter).length > 0);

    // A bodyless, paramless hit is LeadSquared's verification handshake. Answer 200 and
    // record nothing - logging it as a captured payload would just be noise.
    if (!hasBody && !hasParams) {
      return ok_('verification ping - endpoint alive');
    }

    var sh = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(CAPTURE_SHEET);
    if (!sh) {
      sh = SpreadsheetApp.getActiveSpreadsheet().insertSheet(CAPTURE_SHEET);
      sh.appendRow(['ReceivedAt (IST)', 'Method', 'QueryParams', 'ContentType', 'RawBody', 'ParsedKeys']);
      sh.getRange(1, 1, 1, 6).setFontWeight('bold').setBackground('#f1f3f4');
      sh.setFrozenRows(1);
    }

    var raw = (e && e.postData && e.postData.contents) ? e.postData.contents : '';
    var ctype = (e && e.postData && e.postData.type) ? e.postData.type : '';
    var params = (e && e.parameter) ? JSON.stringify(e.parameter) : '{}';

    // Top-level keys of the parsed body, so the shape is readable at a glance without
    // having to squint at a wall of JSON in one cell.
    var keys = '';
    try {
      var parsed = raw ? JSON.parse(raw) : null;
      if (Array.isArray(parsed)) {
        keys = 'ARRAY[' + parsed.length + '] of: ' +
               (parsed.length ? Object.keys(parsed[0]).join(', ') : '(empty)');
      } else if (parsed && typeof parsed === 'object') {
        keys = Object.keys(parsed).join(', ');
      }
    } catch (parseErr) {
      keys = 'not JSON: ' + parseErr;
    }

    sh.appendRow([
      Utilities.formatDate(new Date(), 'Asia/Kolkata', 'yyyy-MM-dd HH:mm:ss'),
      method,
      params,
      ctype,
      raw.length > 45000 ? raw.substring(0, 45000) + '...[truncated]' : raw,
      keys
    ]);
  } catch (err) {
    // Swallowed deliberately. Throwing would return non-200, and ten consecutive non-200s
    // make LeadSquared disable the webhook. The error goes back in StatusReason instead,
    // where it is visible in LSQ's own webhook history.
    console.error('capture failed: ' + err);
    return ok_('capture error: ' + err);
  }

  return ok_('');
}

/**
 * TROUBLESHOOTING - if nothing lands in the sheet
 *
 * 1. Open the web app URL in a browser. It should print "capture endpoint alive". If it
 *    asks you to sign in, the deployment is not set to "Anyone" - redeploy.
 * 2. In LSQ, check the webhook's own delivery/failure log for HTTP status codes.
 * 3. IMPORTANT: after ANY code change you must Deploy > Manage deployments > Edit >
 *    Version: New version. Saving alone does not update the live URL - this catches
 *    almost everyone once.
 * 4. Activity webhooks are batched per minute; give it a full 2 minutes.
 * 5. If a Lead Update webhook fires but Lead Activity Creation never does, that is the
 *    finding: telephony-created activities do not raise the event, and the pipeline has
 *    to poll instead. Worth knowing before anything is built on top of it.
 */
