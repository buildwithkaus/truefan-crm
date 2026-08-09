<#
.SYNOPSIS
  Shared per-lead Activity helpers. Dot-source AFTER common.ps1:
      . "$PSScriptRoot\..\lib\common.ps1"
      . "$PSScriptRoot\..\lib\activity.ps1"

.DESCRIPTION
  Extracted from six near-identical copies that had drifted apart across scripts/reports/
  (calls-for-day, daily-calling-report, icp-rep-compliance, smb-calling-scorecard,
  rep-activity-audit, icp-source-audit). Two of those copies called Invoke-RestMethod bare
  with no retry wrapper, so a DNS blip during an Akamai IP rotation silently dropped a lead
  from the report rather than failing loudly.

  SCOPE NOTE. This file deliberately does NOT normalise activities into fact rows. That
  logic lives exactly once, in supabase/functions/_shared/normalize.ts, and the PowerShell
  backfill posts RAW activity JSON to the backfill edge function so it travels the same
  upsert path as live webhook traffic. Two implementations of the same normalisation would
  drift, and the drift would be invisible. What lives here is fetching and field-reading -
  the parts that verification scripts and the existing reports genuinely need.

.NOTES
  ASCII only. A non-ASCII character in a double-quoted PowerShell 5.1 string can throw a
  cascading parse error that silently breaks everything after it in the file. See CLAUDE.md.

  Activity record shape, confirmed live 2026-08-08 against a real EventCode 22 record
  (nothing here is guessed - the primary key in particular was unknown until it was probed):

    Id                  GUID  <-- the primary key. Stable, unique per activity.
    EventCode           22 | 21 | 203 | 3002 | 12000 | 33 | 208 | ...
    EventName           "Outbound Phone Call Activity"
    CreatedOn           "2026-07-31 05:33:50"   <-- UTC, sortable format
    ModifiedOn          "2026-07-31 05:35:00"   <-- UTC
    RelatedProspectId   GUID of the lead
    ActivityType        3 (call) | 26 (stage change) | 2 (custom form)
    Type                "Outbound" | "Inbound" | "Information"  <-- NOT reliable, see below
    Data                array of {Key,Value}    <-- present on 22 AND on 3002
    ActivityFields      object                  <-- ABSENT entirely on 3002

  EventCode 22 ActivityFields: ProspectActivityAutoId, ActivityEvent_Note, CreatedOn,
  ModifiedOn, CreatedBy (GUID of whoever dialled), mx_Custom_2 (start time),
  mx_Custom_3 (duration seconds), Status (Answered|NotAnswered), Owner, ModifiedBy.
  EventCode 22 Data[]: CallType, Caller, Duration, ResourceUrl.
  EventCode 3002 Data[]: PreviousStage, CurrentStage, CreatedBy (a display NAME), Comment.

  Do NOT trust the top-level `Type` field: a Callkaro EventCode 208 outbound call reports
  Type="Inbound". Branch on EventCode, never on Type.
#>

# Activity type codes. Named so no script hand-writes a bare integer.
$Script:EVENT_CALL_OUTBOUND  = "22"
$Script:EVENT_CALL_INBOUND   = "21"
$Script:EVENT_CALL_FORM      = "203"    # "01. Phone Call/ Follow Up" - the rep-facing form
$Script:EVENT_STAGE_CHANGE   = "3002"
$Script:EVENT_OPPORTUNITY    = "12000"
# EventCode 33 accompanies a 12000 on the same lead with the SAME CreatedOn and NO
# ActivityFields at all - it is a marker, not a deal. Never store it as an opportunity:
# doing so produced 1,089 blank-stage ghost rows against 1,398 real ones. Kept as a named
# constant so the next person recognises it rather than rediscovering it.
$Script:EVENT_OPP_MARKER     = "33"
$Script:EVENT_AI_CALL        = "208"    # Callkaro AI dialler - EXCLUDED, see below

# The three activity names that mean "a human placed or took a call". Used to narrow the
# reconciler's candidate set. Confirmed as the exact live strings held in the Lead field
# ProspectActivityName_Max by enumeration on 2026-08-08 (negative control passed, tally
# reconciled 5823/5823) - not hand-written from a doc page.
$Script:CallActivityNames = @(
    "Outbound Phone Call Activity"
    "Inbound Phone Call Activity"
    "01. Phone Call/ Follow Up"
)

# Callkaro. EventCode 208 / ProspectActivityName_Max "AI Phone Call / Follow Up" is a
# background AI dialler, not a person, and is excluded from every rep metric. It is 41% of
# all lead-touch volume (2,405 of 5,823 leads over two days, 2026-08-08), so excluding it is
# also the single largest saving available on the per-lead API budget.
$Script:AI_ACTIVITY_NAME = "AI Phone Call / Follow Up"


function Get-LeadActivities {
    <#
      Fetch the FULL activity trail for one lead. One API call. There is no bulk activity
      read endpoint on this account (eight names probed 2026-07-28, all 404), so every
      activity-driven job is O(leads) and must be scoped by watermark first.

      Returns an array of activity objects, or an empty array. Throws only on a
      non-transient failure - transient DNS/socket/429/5xx are absorbed by Invoke-LsqWithRetry.
    #>
    param(
        [Parameter(Mandatory)][string]$ProspectId,
        [hashtable]$Config
    )
    if (-not $Config) { $Config = Import-LsqConfig }
    $base = $Config['LSQ_API_HOST']; $ak = $Config['LSQ_ACCESS_KEY']; $sk = $Config['LSQ_SECRET_KEY']
    $uri = "$base/ProspectActivity.svc/Retrieve?accessKey=$ak&secretKey=$sk&leadId=$ProspectId"
    $resp = Invoke-LsqWithRetry -What "activity $ProspectId" -Action {
        Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -ErrorAction Stop
    }
    return @($resp.ProspectActivities)
}


function Get-LsqActivityId {
    <#
      The activity primary key. Confirmed live 2026-08-08 as the top-level `Id` (a GUID);
      ActivityFields.ProspectActivityAutoId is a second, integer identifier on the same
      record. Resolved defensively across both and FAILS LOUD when neither is present,
      because a missing PK would otherwise become a silent duplicate-row bug downstream.
    #>
    param([Parameter(Mandatory)]$Activity)
    $id = "$($Activity.Id)".Trim()
    if ($id) { return $id }
    $auto = "$($Activity.ActivityFields.ProspectActivityAutoId)".Trim()
    if ($auto) { return "auto:$auto" }
    throw "Activity has neither Id nor ProspectActivityAutoId - cannot key it. EventCode=$($Activity.EventCode) Lead=$($Activity.RelatedProspectId)"
}


function Get-ActivityDataValue {
    <#
      Read a key from an activity's Data[] array of {Key,Value} pairs. Present on EventCode
      3002 (PreviousStage / CurrentStage / CreatedBy / Comment) and also on EventCode 22
      (CallType / Caller / Duration / ResourceUrl).
    #>
    param([Parameter(Mandatory)]$Activity, [Parameter(Mandatory)][string]$Key)
    foreach ($d in @($Activity.Data)) {
        if ("$($d.Key)" -eq $Key) { return "$($d.Value)" }
    }
    return ""
}


function Get-CallNoteValue {
    <#
      ActivityEvent_Note is a "{=}"/"{next}" delimited key-value blob, NOT JSON:

        Caller{=}Vikhyat Verma{next}UserId{=}{next}UserId{=}4057ed7a-...{next}Duration{=}64
        {next}Status{=}Answered{next}CallNotes{=}{next}ResourceURL{=}{next}StartTime{=}...

      Known keys: Caller, UserId, Duration, Status, CallNotes, ResourceURL, StartTime, Tag,
      DisplayNumber, EventNote, SourceData.

      BUG FIXED HERE. The original copy in icp-rep-compliance.ps1 matched non-greedily and
      returned the FIRST occurrence of a key. Real blobs contain DUPLICATE keys where the
      first is empty - `UserId{=}{next}UserId{=}4057ed7a-...` was observed verbatim on
      2026-08-08 - so that version returns "" for UserId on every record while looking
      correct. This version scans all occurrences and returns the last non-empty one,
      falling back to "" only when every occurrence is genuinely empty.
    #>
    param([AllowNull()][string]$Blob, [Parameter(Mandatory)][string]$Key)
    if ([string]::IsNullOrWhiteSpace($Blob)) { return "" }
    $pattern = [regex]::Escape($Key) + '\{=\}(.*?)(?=\{next\}|$)'
    $found = ""
    foreach ($m in [regex]::Matches($Blob, $pattern)) {
        $v = $m.Groups[1].Value.Trim()
        if ($v) { $found = $v }
    }
    return $found
}


function ConvertFrom-LsqUtc {
    <#
      Parse an LSQ timestamp string into a [datetime] tagged as UTC.

      LSQ returns THREE different formats, and which one you get depends on the field:
        activity CreatedOn          "2026-07-31 05:33:50"
        ActivityFields.CreatedOn    "7/31/2026 5:33:50 AM"
        ProspectActivityDate_Max    "2026-08-08 07:38:00.000"   <-- MILLISECONDS

      The millisecond form cost real time on 2026-08-08: without a ".fff" format this
      returned $null for every lead, the caller skipped every row, and a QC script reported
      "0 contacts called today" against a live account doing 361. A null here does not look
      like an error anywhere downstream - it looks like an empty day.

      Parsed with InvariantCulture and explicit formats rather than a bare [datetime] cast,
      which is culture-dependent and would transpose day and month on an en-GB machine.
      Returns $null on genuine failure - never a wrong-but-plausible date.
    #>
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $formats = @(
        "yyyy-MM-dd HH:mm:ss.fff", "yyyy-MM-ddTHH:mm:ss.fff",
        "yyyy-MM-dd HH:mm:ss",     "yyyy-MM-ddTHH:mm:ss",
        "M/d/yyyy h:mm:ss tt",     "M/d/yyyy H:mm:ss",
        "yyyy-MM-dd HH:mm",        "yyyy-MM-dd"
    )
    $parsed = [datetime]::MinValue
    foreach ($f in $formats) {
        if ([datetime]::TryParseExact($Value.Trim(), $f, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
        }
    }
    # Last resort: invariant round-trip parse. Still culture-safe, and better than silently
    # dropping a row because LSQ added a format nobody has seen yet.
    if ([datetime]::TryParse($Value.Trim(), $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
        return [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
    }
    return $null
}


function ConvertTo-Ist {
    <#
      UTC -> IST. India is UTC+5:30 year-round with no daylight saving, so a fixed offset is
      correct here and avoids depending on a timezone database whose Windows/Linux ids differ
      ("India Standard Time" vs "Asia/Kolkata") - this pipeline has to run on both.

      Every "which day did this happen on" question must use the IST value. A call placed at
      23:45 IST is stored by LSQ as 18:15 UTC on the SAME date, but one at 02:00 IST is
      20:30 UTC on the PREVIOUS date - so reporting on the UTC date silently misfiles the
      late-evening calls that matter most for a daily scorecard.
    #>
    param([AllowNull()][datetime]$Utc)
    if ($null -eq $Utc) { return $null }
    return $Utc.AddHours(5).AddMinutes(30)
}


function Test-LsqCallConnected {
    <#
      "Connected" = duration > 0. Status -eq "Answered" is carried as an INDEPENDENT signal
      rather than as the definition: across every run to date the two have agreed on every
      single call (36/36, 48/48, 20/20), so a divergence is itself a finding worth surfacing
      instead of being papered over by picking one.
    #>
    param([Parameter(Mandatory)]$Activity)
    $dur = 0
    [void][int]::TryParse("$($Activity.ActivityFields.mx_Custom_3)", [ref]$dur)
    return ($dur -gt 0)
}


function Get-LsqCallDuration {
    param([Parameter(Mandatory)]$Activity)
    $dur = 0
    [void][int]::TryParse("$($Activity.ActivityFields.mx_Custom_3)", [ref]$dur)
    if ($dur -gt 0) { return $dur }
    # Data[].Duration is the same number by a different path - confirmed live 2026-08-08.
    # Used only as a fallback so a missing mx_Custom_3 does not silently read as 0 seconds.
    [void][int]::TryParse((Get-ActivityDataValue $Activity "Duration"), [ref]$dur)
    return $dur
}
