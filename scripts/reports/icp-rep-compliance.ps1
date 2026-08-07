<#
.SYNOPSIS
  READ-ONLY: per-rep coverage and CRM-hygiene audit of the assigned "Kaustubh ICP" contacts.
  Answers, for every contact handed to a rep: was it actually called, did it connect, and
  was the resulting CRM record filled in (Call Disposition, Contact Stage, Disqualification
  Reason, note).

.DESCRIPTION
  The reporting model is deliberately NOT "what does the Lead field say" - reps demonstrably
  do not always move the stage or set a disposition, so the field values alone understate
  and misattribute the work. Instead the source of truth for "did they reach out" is the
  native telephony log (EventCode 22, Outbound Phone Call Activity), and the Lead fields are
  measured AGAINST it to expose the gap.

  Per assigned contact this collects:
    - Outbound calls placed BY THE CURRENT OWNER (call.ActivityFields.CreatedBy == lead
      OwnerId), with first/last timestamp, attempt count, and per-call duration.
      Calls on the same contact placed by SOMEONE ELSE (a previous owner, or Kaustubh) are
      counted separately so a rep is never credited with inherited activity.
    - EventCode 208 "AI Phone Call / Follow Up" counted separately and NEVER as rep activity.
      That is the Callkaro AI dialler, a background system, not a person - counting it as
      outreach would inflate every rep's coverage.
    - Inbound calls (EventCode 21) counted separately - the ask is outbound reach.
    - Stage changes (EventCode 3002) with timestamp, to distinguish "never touched the
      record" from "worked it but left the stage alone".
    - CallNotes from inside the call activity's ActivityEvent_Note blob (a {=}/{next}
      delimited key-value string, not JSON), plus the lead-level Notes field.

  "Connected" = call duration > 0 (ActivityFields.mx_Custom_3, seconds). Status == "Answered"
  is captured alongside as an independent check; the two have agreed on every call observed
  so far and a divergence is worth knowing about.

  Compliance gaps flagged per contact:
    - Assigned but never called by the owner
    - Connected but no Call Disposition
    - Stage = Disqualified but no Disqualification Reason
    - Connected but stage still Fresh (worked, but the record does not show it)
    - Called but no note anywhere

  NOTE ON NOTES: there is no separate Notes API on this account (five candidate endpoints
  probed 2026-08-05, all 404). The lead-level "Notes" field is the only note store, and it
  is currently populated with imported ICP business descriptions rather than rep call notes,
  so its mere presence does NOT indicate a rep wrote anything. This script therefore reports
  the in-call CallNotes field (the only place a rep note can land without destroying the ICP
  description) separately from the Notes field, and does not conflate them.

  Read-only throughout - no CRM writes.

.NOTES
  pwsh ./scripts/leadsquared/migration/24-icp-rep-compliance-audit.ps1
#>

param(
    [string]$SourceValue = "Kaustubh ICP",
    [int]$ExpectedTotal = 4135,
    # The holding owner: contacts still parked here are not yet assigned to a rep and are
    # excluded from the per-rep compliance view. Enumerated live, not assumed - anyone else
    # holding these contacts is treated as an assigned rep.
    [string]$HoldingOwner = "Kaustubh Chauhan",
    [int]$SleepMs = 300,
    # Smoke-test escape hatch: process only the first N assigned contacts. Any value > 0
    # produces a PARTIAL report - the output is marked as such and must not be quoted as
    # coverage. 0 = full run.
    [int]$MaxContacts = 0
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "icp_rep_compliance_log.txt"
$jsonPath = Join-Path $dataDir "icp_rep_compliance_$stamp.json"
$csvPath = Join-Path $dataDir "icp_rep_compliance_contacts_$stamp.csv"
$summaryPath = Join-Path $dataDir "icp_rep_compliance_summary_$stamp.md"

Write-LsqLog "=== ICP rep compliance audit: Source = [$SourceValue] (READ-ONLY) ===" $logPath

# --- Negative control before trusting the Source filter ---
$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch `
    -Filter @{ LookupName = "Source"; LookupValue = "__NO_SUCH_SOURCE_ZZZ__"; SqlOperator = "=" } `
    -ColumnsCsv "ProspectID" -SortColumn "CreatedOn" -SortDirection "1" -PageIndex 1 -PageSize 10))
if ($neg.Count -ne 0) { throw "Negative control FAILED: a nonsense Source returned $($neg.Count) rows - the filter is not filtering. Aborting." }
Write-LsqLog "Negative control passed." $logPath

# --- Pull every contact with this Source ---
$leadCols = "ProspectID,FirstName,LastName,CompanyName,Phone,Source,OwnerId,OwnerIdName,ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason,mx_Disqualification_Category,Notes,ModifiedOn,ProspectActivityDate_Max"
$leads = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "Source"; LookupValue = $SourceValue; SqlOperator = "=" } `
        -ColumnsCsv $leadCols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$leads.Add($l) }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
$allLeads = $leads.ToArray()
Write-LsqLog "Total contacts with Source = [$SourceValue]: $($allLeads.Count)" $logPath

# Absolute guard against a silently truncated scan (CLAUDE.md gotcha #8).
if ($ExpectedTotal -gt 0) {
    $drift = [Math]::Abs($allLeads.Count - $ExpectedTotal)
    if ($drift -gt ($ExpectedTotal * 0.05)) {
        throw "Scan size $($allLeads.Count) differs from expected $ExpectedTotal by >5% - refusing to report a possibly truncated scan."
    }
}

# --- Enumerate the rep set from live data rather than hardcoding names ---
$ownerTally = $allLeads | Group-Object OwnerIdName | Sort-Object Count -Descending
Write-LsqLog "" $logPath
Write-LsqLog "--- Owner distribution (all $($allLeads.Count)) ---" $logPath
foreach ($g in $ownerTally) {
    $nm = $g.Name
    if ([string]::IsNullOrWhiteSpace($nm)) { $nm = "<NONE>" }
    Write-LsqLog ("  {0,6}  [{1}]" -f $g.Count, $nm) $logPath
}

$assigned = @($allLeads | Where-Object { $_.OwnerIdName -ne $HoldingOwner -and -not [string]::IsNullOrWhiteSpace($_.OwnerIdName) })
$reps = @($assigned | Group-Object OwnerIdName | Sort-Object Count -Descending | ForEach-Object { $_.Name })
Write-LsqLog "" $logPath
Write-LsqLog "Assigned contacts: $($assigned.Count) across $($reps.Count) reps: $($reps -join ', ')" $logPath
if ($assigned.Count -eq 0) { throw "0 assigned contacts - refusing to report an empty result." }

$isPartial = $false
if ($MaxContacts -gt 0 -and $assigned.Count -gt $MaxContacts) {
    $assigned = @($assigned | Select-Object -First $MaxContacts)
    $isPartial = $true
    Write-LsqLog "*** PARTIAL RUN: limited to the first $MaxContacts assigned contacts. Coverage numbers below are NOT the real coverage. ***" $logPath
}

# --- Per-contact activity pull ---
$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# ActivityEvent_Note is a "{=}"/"{next}" delimited key-value blob, not JSON. Pure parse, no logging.
function Get-CallNoteValue {
    param([string]$Blob, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Blob)) { return "" }
    $m = [regex]::Match($Blob, [regex]::Escape($Key) + '\{=\}(.*?)(\{next\}|$)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ""
}

Write-LsqLog "" $logPath
Write-LsqLog "Pulling activity for $($assigned.Count) assigned contacts (1 API call each)..." $logPath

$rows = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0
foreach ($c in $assigned) {
    $ownerId = "$($c.OwnerId)"
    $ownerCalls = 0; $ownerConnects = 0; $ownerAnswered = 0
    $ownerTalkSec = 0; $ownerMaxSec = 0
    $firstCall = $null; $lastCall = $null
    $otherCalls = 0; $aiCalls = 0; $inboundCalls = 0
    $stageChanges = 0; $lastStageChange = $null
    $callNoteText = ""

    try {
        $r = Invoke-LsqWithRetry -What "activity $($c.ProspectID)" -Action {
            Invoke-RestMethod -Uri "$base/ProspectActivity.svc/Retrieve?accessKey=$ak&secretKey=$sk&leadId=$($c.ProspectID)" -Method Post -ContentType "application/json" -ErrorAction Stop
        }
        $ok++
        foreach ($a in @($r.ProspectActivities)) {
            $code = "$($a.EventCode)"
            if ($code -eq "208") { $aiCalls++; continue }        # AI dialler - never rep activity
            if ($code -eq "21")  { $inboundCalls++; continue }
            if ($code -eq "3002") {
                $stageChanges++
                $when = [datetime]$a.CreatedOn
                if (-not $lastStageChange -or $when -gt $lastStageChange) { $lastStageChange = $when }
                continue
            }
            if ($code -ne "22") { continue }

            $by = "$($a.ActivityFields.CreatedBy)"
            if ($by -ne $ownerId) { $otherCalls++; continue }

            $ownerCalls++
            $when = [datetime]$a.CreatedOn
            if (-not $firstCall -or $when -lt $firstCall) { $firstCall = $when }
            if (-not $lastCall  -or $when -gt $lastCall)  { $lastCall = $when }

            $dur = 0
            [void][int]::TryParse("$($a.ActivityFields.mx_Custom_3)", [ref]$dur)
            if ($dur -gt 0) {
                $ownerConnects++
                $ownerTalkSec += $dur
                if ($dur -gt $ownerMaxSec) { $ownerMaxSec = $dur }
            }
            if ("$($a.ActivityFields.Status)" -eq "Answered") { $ownerAnswered++ }

            $cn = Get-CallNoteValue -Blob "$($a.ActivityFields.ActivityEvent_Note)" -Key "CallNotes"
            if (-not [string]::IsNullOrWhiteSpace($cn)) { $callNoteText = $cn }
        }
    } catch {
        $failed++
        Write-LsqLog "  activity fetch failed for $($c.ProspectID) -> $($_.Exception.Message)" $logPath
        continue
    }

    $stage = "$($c.ProspectStage)"
    $disp = "$($c.mx_Call_Disposition)"
    $dqReason = "$($c.mx_Disqualification_Reason)"

    $wasCalled = ($ownerCalls -gt 0)
    $wasConnected = ($ownerConnects -gt 0)

    [void]$rows.Add([pscustomobject]@{
        ProspectId = $c.ProspectID
        Rep = $c.OwnerIdName
        Company = $c.CompanyName
        Contact = ("$($c.FirstName) $($c.LastName)").Trim()
        Phone = $c.Phone
        Stage = $stage
        Disposition = $disp
        DisqualificationReason = $dqReason
        # Attempts / outcomes attributed to the CURRENT owner only
        OwnerAttempts = $ownerCalls
        OwnerConnects = $ownerConnects
        OwnerAnswered = $ownerAnswered
        TalkTimeSec = $ownerTalkSec
        LongestCallSec = $ownerMaxSec
        FirstCall = $(if ($firstCall) { $firstCall.ToString("yyyy-MM-dd HH:mm") } else { "" })
        LastCall  = $(if ($lastCall)  { $lastCall.ToString("yyyy-MM-dd HH:mm") }  else { "" })
        # Context, deliberately not credited to the rep
        CallsByOthers = $otherCalls
        AiDiallerCalls = $aiCalls
        InboundCalls = $inboundCalls
        StageChanges = $stageChanges
        LastStageChange = $(if ($lastStageChange) { $lastStageChange.ToString("yyyy-MM-dd HH:mm") } else { "" })
        CallNote = $callNoteText
        HasCallNote = (-not [string]::IsNullOrWhiteSpace($callNoteText))
        NotesField = $c.Notes
        # Compliance flags
        NotCalled = (-not $wasCalled)
        CalledNotConnected = ($wasCalled -and -not $wasConnected)
        Connected = $wasConnected
        GapConnectedNoDisposition = ($wasConnected -and [string]::IsNullOrWhiteSpace($disp))
        GapDisqualifiedNoReason = (($stage -eq "Disqualified") -and [string]::IsNullOrWhiteSpace($dqReason))
        GapConnectedStillFresh = ($wasConnected -and ($stage -eq "Fresh" -or $stage -eq "Fresh Lead"))
        GapCalledNoNote = ($wasCalled -and [string]::IsNullOrWhiteSpace($callNoteText))
    })

    if (($ok + $failed) % 100 -eq 0) { Write-LsqLog "  processed $($ok + $failed)/$($assigned.Count)" $logPath }
    Start-Sleep -Milliseconds $SleepMs
}

$contacts = $rows.ToArray()
Write-LsqLog "Activity pull complete: $ok ok, $failed failed, of $($assigned.Count)." $logPath
if ($failed -gt 0) {
    Write-LsqLog "*** WARNING: $failed contacts could not be checked - call coverage below is an UNDERCOUNT for those. ***" $logPath
}

# --- Pure tally helper (compute only, no logging - CLAUDE.md gotcha #11 corollary) ---
function Get-Tally {
    param($Rows, [string]$Field)
    $out = New-Object System.Collections.Generic.List[object]
    $Rows | Group-Object -Property $Field | Sort-Object Count -Descending | ForEach-Object {
        $name = $_.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "<BLANK>" }
        [void]$out.Add([pscustomobject]@{ Value = $name; Count = $_.Count })
    }
    return $out.ToArray()
}

function Write-Tally {
    param($Tally, [string]$Title, [string]$LogPath, [int]$Total)
    Write-LsqLog "" $LogPath
    Write-LsqLog "--- $Title ---" $LogPath
    foreach ($t in $Tally) {
        $pct = 0
        if ($Total -gt 0) { $pct = [Math]::Round(100.0 * $t.Count / $Total, 1) }
        Write-LsqLog ("  {0,6}  {1,5}%  [{2}]" -f $t.Count, $pct, $t.Value) $LogPath
    }
}

# --- Per-rep aggregation ---
$repRows = New-Object System.Collections.Generic.List[object]
foreach ($rep in $reps) {
    $m = @($contacts | Where-Object { $_.Rep -eq $rep })
    if ($m.Count -eq 0) { continue }
    $called    = @($m | Where-Object { -not $_.NotCalled })
    $connected = @($m | Where-Object { $_.Connected })
    $cnc       = @($m | Where-Object { $_.CalledNotConnected })
    $talk = ($m | Measure-Object -Property TalkTimeSec -Sum).Sum
    $attempts = ($m | Measure-Object -Property OwnerAttempts -Sum).Sum

    $avgConnect = 0
    if ($connected.Count -gt 0) { $avgConnect = [Math]::Round($talk / $connected.Count, 0) }
    $connectPct = 0
    if ($called.Count -gt 0) { $connectPct = [Math]::Round(100.0 * $connected.Count / $called.Count, 1) }

    [void]$repRows.Add([pscustomobject]@{
        Rep = $rep
        Assigned = $m.Count
        Called = $called.Count
        NotCalled = $m.Count - $called.Count
        CoveragePct = [Math]::Round(100.0 * $called.Count / $m.Count, 1)
        Attempts = $attempts
        Connected = $connected.Count
        NotConnected = $cnc.Count
        ConnectPctOfCalled = $connectPct
        TalkTimeMin = [Math]::Round($talk / 60.0, 1)
        AvgConnectSec = $avgConnect
        GapConnectedNoDisposition = @($m | Where-Object { $_.GapConnectedNoDisposition }).Count
        GapDisqualifiedNoReason = @($m | Where-Object { $_.GapDisqualifiedNoReason }).Count
        GapConnectedStillFresh = @($m | Where-Object { $_.GapConnectedStillFresh }).Count
        GapCalledNoNote = @($m | Where-Object { $_.GapCalledNoNote }).Count
        WithCallNote = @($m | Where-Object { $_.HasCallNote }).Count
        AiDialledContacts = @($m | Where-Object { $_.AiDiallerCalls -gt 0 }).Count
        ContactsCalledByOthers = @($m | Where-Object { $_.CallsByOthers -gt 0 }).Count
    })
}
$repArr = $repRows.ToArray()

Write-LsqLog "" $logPath
Write-LsqLog "=== COVERAGE BY REP ===" $logPath
foreach ($r in $repArr) {
    Write-LsqLog ("  {0,-20} assigned={1,-5} called={2,-5} ({3,5}%)  notCalled={4,-5} attempts={5,-5} connected={6,-5} notConnected={7,-5} talk={8,7}min" -f `
        $r.Rep, $r.Assigned, $r.Called, $r.CoveragePct, $r.NotCalled, $r.Attempts, $r.Connected, $r.NotConnected, $r.TalkTimeMin) $logPath
}
Write-LsqLog "" $logPath
Write-LsqLog "=== CRM HYGIENE GAPS BY REP ===" $logPath
foreach ($r in $repArr) {
    Write-LsqLog ("  {0,-20} connectedNoDisposition={1,-5} disqualifiedNoReason={2,-5} connectedStillFresh={3,-5} calledNoNote={4,-5}" -f `
        $r.Rep, $r.GapConnectedNoDisposition, $r.GapDisqualifiedNoReason, $r.GapConnectedStillFresh, $r.GapCalledNoNote) $logPath
}

# --- Distributions, overall and per rep ---
$stageAll = Get-Tally $contacts "Stage"
$dispAll  = Get-Tally $contacts "Disposition"
$dqAll    = Get-Tally @($contacts | Where-Object { $_.Stage -eq "Disqualified" }) "DisqualificationReason"

Write-Tally $stageAll "CONTACT STAGE - all $($contacts.Count) assigned" $logPath $contacts.Count
Write-Tally $dispAll  "CALL DISPOSITION - all $($contacts.Count) assigned" $logPath $contacts.Count
$dqCount = @($contacts | Where-Object { $_.Stage -eq "Disqualified" }).Count
Write-Tally $dqAll "DISQUALIFICATION REASON - the $dqCount disqualified" $logPath $dqCount

$perRepDetail = New-Object System.Collections.Generic.List[object]
foreach ($rep in $reps) {
    $m = @($contacts | Where-Object { $_.Rep -eq $rep })
    if ($m.Count -eq 0) { continue }
    $connectedRows = @($m | Where-Object { $_.Connected })
    $dqRows = @($m | Where-Object { $_.Stage -eq "Disqualified" })
    $detail = [pscustomobject]@{
        Rep = $rep
        StageTally = Get-Tally $m "Stage"
        DispositionTally = Get-Tally $m "Disposition"
        ConnectedDispositionTally = Get-Tally $connectedRows "Disposition"
        DisqualificationTally = Get-Tally $dqRows "DisqualificationReason"
    }
    [void]$perRepDetail.Add($detail)
    Write-Tally $detail.StageTally "STAGE - $rep ($($m.Count))" $logPath $m.Count
    Write-Tally $detail.ConnectedDispositionTally "DISPOSITION OF CONNECTED - $rep ($($connectedRows.Count) connected)" $logPath $connectedRows.Count
    if ($dqRows.Count -gt 0) {
        Write-Tally $detail.DisqualificationTally "DISQUALIFICATION REASON - $rep ($($dqRows.Count) disqualified)" $logPath $dqRows.Count
    }
}

# --- Notes reality check ---
$anyCallNote = @($contacts | Where-Object { $_.HasCallNote }).Count
$notesFieldPresent = @($contacts | Where-Object { -not [string]::IsNullOrWhiteSpace($_.NotesField) }).Count
Write-LsqLog "" $logPath
Write-LsqLog "=== NOTES ===" $logPath
Write-LsqLog "  Contacts with an in-call CallNote (a real rep note): $anyCallNote / $($contacts.Count)" $logPath
Write-LsqLog "  Contacts with the lead-level Notes field populated:  $notesFieldPresent / $($contacts.Count)" $logPath
Write-LsqLog "  (the Notes field holds imported ICP business descriptions - presence does NOT mean a rep wrote one)" $logPath

# --- Output ---
$totals = [pscustomobject]@{
    Assigned = $contacts.Count
    Called = @($contacts | Where-Object { -not $_.NotCalled }).Count
    NotCalled = @($contacts | Where-Object { $_.NotCalled }).Count
    Connected = @($contacts | Where-Object { $_.Connected }).Count
    NotConnected = @($contacts | Where-Object { $_.CalledNotConnected }).Count
    Attempts = ($contacts | Measure-Object -Property OwnerAttempts -Sum).Sum
    TalkTimeMin = [Math]::Round((($contacts | Measure-Object -Property TalkTimeSec -Sum).Sum) / 60.0, 1)
    GapConnectedNoDisposition = @($contacts | Where-Object { $_.GapConnectedNoDisposition }).Count
    GapDisqualifiedNoReason = @($contacts | Where-Object { $_.GapDisqualifiedNoReason }).Count
    GapConnectedStillFresh = @($contacts | Where-Object { $_.GapConnectedStillFresh }).Count
    GapCalledNoNote = @($contacts | Where-Object { $_.GapCalledNoNote }).Count
    WithCallNote = $anyCallNote
}

$snapshot = [pscustomobject]@{
    RunAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    SourceValue = $SourceValue
    IsPartialRun = $isPartial
    TotalWithSource = $allLeads.Count
    HoldingOwner = $HoldingOwner
    Reps = $reps
    Totals = $totals
    ByRep = $repArr
    StageTallyAll = $stageAll
    DispositionTallyAll = $dispAll
    DisqualificationTallyAll = $dqAll
    PerRepDetail = $perRepDetail.ToArray()
    ActivityFetchOk = $ok
    ActivityFetchFailed = $failed
    Contacts = $contacts
}
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8
Write-LsqLog "" $logPath
Write-LsqLog "JSON snapshot written: $jsonPath" $logPath

# Per-contact CSV - the actionable worklist (who to chase, which record is incomplete).
$contacts | Select-Object Rep, Company, Contact, Phone, Stage, Disposition, DisqualificationReason, `
    OwnerAttempts, OwnerConnects, TalkTimeSec, LongestCallSec, FirstCall, LastCall, `
    CallsByOthers, AiDiallerCalls, InboundCalls, StageChanges, LastStageChange, HasCallNote, `
    NotCalled, CalledNotConnected, Connected, GapConnectedNoDisposition, GapDisqualifiedNoReason, `
    GapConnectedStillFresh, GapCalledNoNote, ProspectId |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-LsqLog "Per-contact CSV written: $csvPath" $logPath

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# ICP assigned-contact compliance audit (read-only)")
[void]$md.Add("")
if ($isPartial) {
    [void]$md.Add("> **PARTIAL RUN - limited to the first $MaxContacts assigned contacts. These are NOT real coverage numbers.**")
    [void]$md.Add("")
}
[void]$md.Add("Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm')) IST. Source = ``$SourceValue`` ($($allLeads.Count) contacts total, $($contacts.Count) assigned to $($reps.Count) reps).")
[void]$md.Add("")
[void]$md.Add("Outreach is measured from the native outbound call log (EventCode 22) attributed to the contact's current owner. AI-dialler calls and calls by other users are excluded from rep credit.")
[void]$md.Add("")
[void]$md.Add("## Coverage")
[void]$md.Add("")
[void]$md.Add("| Rep | Assigned | Called | Coverage | Not called | Attempts | Connected | Not connected | Connect % | Talk time | Avg/connect |")
[void]$md.Add("|---|---|---|---|---|---|---|---|---|---|---|")
foreach ($r in $repArr) {
    [void]$md.Add("| $($r.Rep) | $($r.Assigned) | $($r.Called) | $($r.CoveragePct)% | $($r.NotCalled) | $($r.Attempts) | $($r.Connected) | $($r.NotConnected) | $($r.ConnectPctOfCalled)% | $($r.TalkTimeMin) min | $($r.AvgConnectSec)s |")
}
[void]$md.Add("| **TOTAL** | **$($totals.Assigned)** | **$($totals.Called)** | **$([Math]::Round(100.0*$totals.Called/$totals.Assigned,1))%** | **$($totals.NotCalled)** | **$($totals.Attempts)** | **$($totals.Connected)** | **$($totals.NotConnected)** | | **$($totals.TalkTimeMin) min** | |")
[void]$md.Add("")
[void]$md.Add("## CRM hygiene gaps")
[void]$md.Add("")
[void]$md.Add("| Rep | Connected, no disposition | Disqualified, no reason | Connected, stage still Fresh | Called, no note |")
[void]$md.Add("|---|---|---|---|---|")
foreach ($r in $repArr) {
    [void]$md.Add("| $($r.Rep) | $($r.GapConnectedNoDisposition) | $($r.GapDisqualifiedNoReason) | $($r.GapConnectedStillFresh) | $($r.GapCalledNoNote) |")
}
[void]$md.Add("| **TOTAL** | **$($totals.GapConnectedNoDisposition)** | **$($totals.GapDisqualifiedNoReason)** | **$($totals.GapConnectedStillFresh)** | **$($totals.GapCalledNoNote)** |")
[void]$md.Add("")
[void]$md.Add("## Contact Stage - all assigned")
[void]$md.Add("")
[void]$md.Add("| Stage | Contacts |")
[void]$md.Add("|---|---|")
foreach ($t in $stageAll) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
[void]$md.Add("")
[void]$md.Add("## Call Disposition - all assigned")
[void]$md.Add("")
[void]$md.Add("| Disposition | Contacts |")
[void]$md.Add("|---|---|")
foreach ($t in $dispAll) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
[void]$md.Add("")
[void]$md.Add("## Disqualification Reason - the $dqCount disqualified")
[void]$md.Add("")
[void]$md.Add("| Reason | Contacts |")
[void]$md.Add("|---|---|")
foreach ($t in $dqAll) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
[void]$md.Add("")
[void]$md.Add("## Notes")
[void]$md.Add("")
[void]$md.Add("- Contacts with a real in-call note (CallNotes): **$anyCallNote / $($contacts.Count)**")
[void]$md.Add("- Contacts with the lead-level Notes field populated: $notesFieldPresent / $($contacts.Count) - this field holds imported ICP business descriptions, not rep notes.")
[void]$md.Add("")
foreach ($d in $perRepDetail.ToArray()) {
    [void]$md.Add("### $($d.Rep) - disposition of connected contacts")
    [void]$md.Add("")
    [void]$md.Add("| Disposition | Contacts |")
    [void]$md.Add("|---|---|")
    foreach ($t in $d.ConnectedDispositionTally) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
    [void]$md.Add("")
}
$md | Set-Content -Path $summaryPath -Encoding utf8
Write-LsqLog "Markdown summary written: $summaryPath" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "=== ICP rep compliance audit complete ===" $logPath
