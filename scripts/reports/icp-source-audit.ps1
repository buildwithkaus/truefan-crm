<#
.SYNOPSIS
  READ-ONLY: audit of every Contact with Source = "Kaustubh ICP" - breakdown by Contact
  Owner, Contact Stage (ProspectStage) and Call Disposition (mx_Call_Disposition), plus
  real outbound calling activity for the reps the list was distributed to.

.DESCRIPTION
  Context: ~200 ICP contacts each were assigned to Abhishek, Ashutosh and Rishi on
  2026-08-04. This answers, for that assigned population: how many were actually dialled,
  how many connected, and what disposition was logged.

  Two independent data sources are combined:
    1. Lead fields (Leads.Get, Source = "Kaustubh ICP") - owner / stage / disposition.
       The exact stored string was enumerated live 2026-08-04 (tallied from all leads
       modified today) rather than guessed, per CLAUDE.md's enumerate-don't-probe rule,
       and a negative control runs before the real filter is trusted.
    2. Native calling activity (EventCode 22, "Outbound Phone Call Activity") pulled per
       lead via ProspectActivity.svc/Retrieve - the only way to see real dials, since no
       bulk Activity read endpoint exists. Only the assigned reps' contacts are pulled,
       to keep the per-lead call count bounded.

  "Connected" is counted two ways because they do not always agree:
    - Duration > 0 (ActivityFields.mx_Custom_3, seconds - the user's definition)
    - Status = "Answered" (the telephony integration's own verdict)

  Timestamps are UTC in storage, IST locally (CLAUDE.md gotcha #5) - the "today" window
  is computed from local midnight converted to UTC, never by string-matching a date.

  Read-only throughout - no CRM writes.

.PARAMETER SourceValue
  The exact Source string to audit. Default "Kaustubh ICP".

.PARAMETER ExpectedTotal
  Absolute expected row count for the Source filter, used as a guard against a silently
  truncated scan (CLAUDE.md gotcha #8 - a nested page reads .Count = 1 and a paginating
  loop then reports a complete scan after one page). 4,135 enumerated live 2026-08-04.
  Set to 0 to skip the guard.

.NOTES
  pwsh ./scripts/leadsquared/migration/23-icp-source-audit.ps1
#>

param(
    [string]$SourceValue = "Kaustubh ICP",
    [int]$ExpectedTotal = 4135,
    [string[]]$AssignedReps = @("Abhishek Tripathi", "Ashutosh Ojha", "Rishi Saraswat")
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "icp_source_audit_log.txt"
$jsonPath = Join-Path $dataDir "icp_source_audit_$stamp.json"
$summaryPath = Join-Path $dataDir "icp_source_audit_summary_$stamp.md"

$todayStart = (Get-Date).Date
$todayStartUtc = $todayStart.ToUniversalTime()

Write-LsqLog "=== ICP Source audit: Source = [$SourceValue] (READ-ONLY) ===" $logPath
Write-LsqLog "Today window starts (UTC): $($todayStartUtc.ToString('yyyy-MM-dd HH:mm:ss'))" $logPath

# --- Negative control before trusting the Source filter ---
$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch `
    -Filter @{ LookupName = "Source"; LookupValue = "__NO_SUCH_SOURCE_ZZZ__"; SqlOperator = "=" } `
    -ColumnsCsv "ProspectID" -SortColumn "CreatedOn" -SortDirection "1" -PageIndex 1 -PageSize 10))
if ($neg.Count -ne 0) { throw "Negative control FAILED: a nonsense Source returned $($neg.Count) rows. The filter is not filtering - aborting." }
Write-LsqLog "Negative control passed (0 rows for a nonsense Source value)." $logPath

# --- Pull every lead with this Source ---
$leadCols = "ProspectID,Source,OwnerId,OwnerIdName,ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason,ProspectActivityDate_Max,ModifiedOn"
$leads = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "Source"; LookupValue = $SourceValue; SqlOperator = "=" } `
        -ColumnsCsv $leadCols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$leads.Add($l) }
    Write-LsqLog "  page $page -> $($resp.Count) rows (running total $($leads.Count))" $logPath
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Total leads with Source = [$SourceValue]: $($leads.Count)" $logPath

# Absolute guard - compare against an independently known size, not against another number
# derived from the same read (CLAUDE.md: an internal-consistency check is not a reconciliation).
if ($ExpectedTotal -gt 0) {
    $drift = [Math]::Abs($leads.Count - $ExpectedTotal)
    if ($drift -gt ($ExpectedTotal * 0.05)) {
        throw "Scan size $($leads.Count) differs from expected $ExpectedTotal by more than 5% - refusing to report a possibly truncated scan."
    }
    Write-LsqLog "Absolute size guard OK ($($leads.Count) vs expected ~$ExpectedTotal)." $logPath
}

# --- Pure tally helpers (compute only - no logging inside, per CLAUDE.md gotcha #11 corollary) ---
function Get-Tally {
    param($Rows, [string]$Field)
    $out = New-Object System.Collections.Generic.List[object]
    $Rows | Group-Object -Property $Field | Sort-Object Count -Descending | ForEach-Object {
        $name = if ([string]::IsNullOrWhiteSpace($_.Name)) { "<BLANK>" } else { $_.Name }
        [void]$out.Add([pscustomobject]@{ Value = $name; Count = $_.Count })
    }
    return $out.ToArray()
}

function Write-Tally {
    param($Tally, [string]$Title, [string]$LogPath, [int]$Total)
    Write-LsqLog "" $LogPath
    Write-LsqLog "--- $Title ---" $LogPath
    foreach ($t in $Tally) {
        $pct = if ($Total -gt 0) { [Math]::Round(100.0 * $t.Count / $Total, 1) } else { 0 }
        Write-LsqLog ("  {0,6}  {1,5}%  [{2}]" -f $t.Count, $pct, $t.Value) $LogPath
    }
}

$allLeads = $leads.ToArray()
$total = $allLeads.Count

$ownerTally = Get-Tally $allLeads "OwnerIdName"
$stageTally = Get-Tally $allLeads "ProspectStage"
$dispTally  = Get-Tally $allLeads "mx_Call_Disposition"

Write-Tally $ownerTally "CONTACT OWNER (all $total ICP contacts)" $logPath $total
Write-Tally $stageTally "CONTACT STAGE (all $total ICP contacts)" $logPath $total
Write-Tally $dispTally  "CALL DISPOSITION (all $total ICP contacts)" $logPath $total

# --- Per-rep cross-tabs for the assigned reps ---
$repLeads = @($allLeads | Where-Object { $AssignedReps -contains $_.OwnerIdName })
Write-LsqLog "" $logPath
Write-LsqLog "Assigned-rep contacts (owner in: $($AssignedReps -join ', ')): $($repLeads.Count)" $logPath
if ($repLeads.Count -eq 0) { throw "0 contacts found for the named reps - refusing to report an empty result without investigating owner-name spelling." }

$perRep = @{}
foreach ($rep in $AssignedReps) {
    $mine = @($repLeads | Where-Object { $_.OwnerIdName -eq $rep })
    $perRep[$rep] = [pscustomobject]@{
        Rep = $rep
        Contacts = $mine.Count
        StageTally = Get-Tally $mine "ProspectStage"
        DispositionTally = Get-Tally $mine "mx_Call_Disposition"
    }
    Write-Tally $perRep[$rep].StageTally "STAGE - $rep ($($mine.Count) contacts)" $logPath $mine.Count
    Write-Tally $perRep[$rep].DispositionTally "DISPOSITION - $rep ($($mine.Count) contacts)" $logPath $mine.Count
}

# --- Real calling activity for the assigned reps' contacts ---
$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

Write-LsqLog "" $logPath
Write-LsqLog "Pulling EventCode-22 call activity for $($repLeads.Count) contacts (1 API call each)..." $logPath

$callRows = New-Object System.Collections.Generic.List[object]
$checked = 0
$failed = 0
foreach ($c in $repLeads) {
    $url = "$base/ProspectActivity.svc/Retrieve?accessKey=$ak&secretKey=$sk&leadId=$($c.ProspectID)"
    try {
        $r = Invoke-LsqWithRetry -What "activity $($c.ProspectID)" -Action {
            Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -ErrorAction Stop
        }
        $checked++
        $calls = @($r.ProspectActivities) | Where-Object { "$($_.EventCode)" -eq "22" }

        $attemptsToday = 0; $attemptsAll = 0
        $connectedToday = 0; $answeredToday = 0
        $durToday = 0; $maxDurToday = 0
        foreach ($call in $calls) {
            $attemptsAll++
            $when = [datetime]$call.CreatedOn
            if ($when -lt $todayStartUtc) { continue }
            $attemptsToday++
            $dur = 0
            [void][int]::TryParse("$($call.ActivityFields.mx_Custom_3)", [ref]$dur)
            if ($dur -gt 0) { $connectedToday++; $durToday += $dur; if ($dur -gt $maxDurToday) { $maxDurToday = $dur } }
            if ("$($call.ActivityFields.Status)" -eq "Answered") { $answeredToday++ }
        }

        [void]$callRows.Add([pscustomobject]@{
            ProspectId = $c.ProspectID
            Rep = $c.OwnerIdName
            Stage = $c.ProspectStage
            Disposition = $c.mx_Call_Disposition
            AttemptsToday = $attemptsToday
            AttemptsAllTime = $attemptsAll
            ConnectedToday = $connectedToday
            AnsweredToday = $answeredToday
            TalkTimeSecToday = $durToday
            LongestCallSecToday = $maxDurToday
        })
    } catch {
        $failed++
        Write-LsqLog "  activity fetch failed for lead $($c.ProspectID) -> $($_.Exception.Message)" $logPath
    }
    if (($checked + $failed) % 100 -eq 0) { Write-LsqLog "  activity checked: $($checked + $failed)/$($repLeads.Count)" $logPath }
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Activity pull complete: $checked ok, $failed failed, of $($repLeads.Count)." $logPath
if ($failed -gt ($repLeads.Count * 0.02)) {
    Write-LsqLog "*** WARNING: $failed activity fetches failed (>2%) - call numbers below are an UNDERCOUNT. ***" $logPath
}

# --- Per-rep calling summary ---
$callArr = $callRows.ToArray()
$repCallRows = New-Object System.Collections.Generic.List[object]
foreach ($rep in $AssignedReps) {
    $mine = @($callArr | Where-Object { $_.Rep -eq $rep })
    if ($mine.Count -eq 0) { continue }
    $dialled   = @($mine | Where-Object { $_.AttemptsToday -gt 0 })
    $connected = @($mine | Where-Object { $_.ConnectedToday -gt 0 })
    $answered  = @($mine | Where-Object { $_.AnsweredToday -gt 0 })
    $talk = ($mine | Measure-Object -Property TalkTimeSecToday -Sum).Sum
    $attempts = ($mine | Measure-Object -Property AttemptsToday -Sum).Sum
    # Precomputed rather than inlined: PowerShell 5.1 will not parse an `if` expression as a
    # value inside a [pscustomobject]@{...} literal.
    $avgTalk = 0
    if ($connected.Count -gt 0) { $avgTalk = [Math]::Round($talk / $connected.Count, 0) }
    $connectPct = 0
    if ($dialled.Count -gt 0) { $connectPct = [Math]::Round(100.0 * $connected.Count / $dialled.Count, 1) }
    [void]$repCallRows.Add([pscustomobject]@{
        Rep = $rep
        ContactsAssigned = $mine.Count
        ContactsDialled = $dialled.Count
        ContactsNotDialled = $mine.Count - $dialled.Count
        TotalAttempts = $attempts
        ContactsConnectedByDuration = $connected.Count
        ContactsConnectedByStatus = $answered.Count
        TotalTalkTimeMin = [Math]::Round($talk / 60.0, 1)
        AvgTalkTimeSecPerConnect = $avgTalk
        DialledPct = [Math]::Round(100.0 * $dialled.Count / [Math]::Max($mine.Count, 1), 1)
        ConnectPctOfDialled = $connectPct
    })
}
$repCallArr = $repCallRows.ToArray()

Write-LsqLog "" $logPath
Write-LsqLog "=== CALLING ACTIVITY TODAY ($($todayStart.ToString('yyyy-MM-dd'))) - ASSIGNED ICP CONTACTS ===" $logPath
foreach ($row in $repCallArr) {
    Write-LsqLog ("  {0,-20} assigned={1,-5} dialled={2,-5} ({3,5}%)  attempts={4,-5} connected(dur>0)={5,-5} answered={6,-5} talk={7,6}min" -f `
        $row.Rep, $row.ContactsAssigned, $row.ContactsDialled, $row.DialledPct, $row.TotalAttempts, `
        $row.ContactsConnectedByDuration, $row.ContactsConnectedByStatus, $row.TotalTalkTimeMin) $logPath
}

# --- Disposition of the contacts that were actually dialled ---
Write-LsqLog "" $logPath
Write-LsqLog "=== DISPOSITION OF DIALLED CONTACTS (per rep) ===" $logPath
$dialledDispByRep = @{}
foreach ($rep in $AssignedReps) {
    $mine = @($callArr | Where-Object { $_.Rep -eq $rep -and $_.AttemptsToday -gt 0 })
    if ($mine.Count -eq 0) { continue }
    $t = Get-Tally $mine "Disposition"
    $dialledDispByRep[$rep] = $t
    Write-Tally $t "DIALLED-ONLY DISPOSITION - $rep ($($mine.Count) dialled)" $logPath $mine.Count
}

# --- Output ---
$snapshot = [pscustomobject]@{
    RunAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    SourceValue = $SourceValue
    TotalIcpContacts = $total
    OwnerTally = $ownerTally
    StageTally = $stageTally
    DispositionTally = $dispTally
    AssignedReps = $AssignedReps
    AssignedRepContacts = $repLeads.Count
    PerRepFieldTallies = ($AssignedReps | ForEach-Object { $perRep[$_] })
    CallingSummary = $repCallArr
    DialledDispositionByRep = ($AssignedReps | Where-Object { $dialledDispByRep.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ Rep = $_; Tally = $dialledDispByRep[$_] } })
    ActivityFetchOk = $checked
    ActivityFetchFailed = $failed
    PerContact = $callArr
}
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8
Write-LsqLog "" $logPath
Write-LsqLog "JSON snapshot written: $jsonPath" $logPath

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# ICP Source audit - Source = ``$SourceValue`` (read-only)")
[void]$md.Add("")
[void]$md.Add("Run: $((Get-Date).ToString('yyyy-MM-dd HH:mm')) IST. Total contacts with this Source: **$total**.")
[void]$md.Add("")
[void]$md.Add("## Contact Owner")
[void]$md.Add("")
[void]$md.Add("| Owner | Contacts |")
[void]$md.Add("|---|---|")
foreach ($t in $ownerTally) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
[void]$md.Add("")
[void]$md.Add("## Contact Stage")
[void]$md.Add("")
[void]$md.Add("| Stage | Contacts |")
[void]$md.Add("|---|---|")
foreach ($t in $stageTally) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
[void]$md.Add("")
[void]$md.Add("## Call Disposition")
[void]$md.Add("")
[void]$md.Add("| Disposition | Contacts |")
[void]$md.Add("|---|---|")
foreach ($t in $dispTally) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
[void]$md.Add("")
[void]$md.Add("## Calling activity today - assigned reps")
[void]$md.Add("")
[void]$md.Add("| Rep | Assigned | Dialled | Dial % | Attempts | Connected (dur>0) | Answered (status) | Connect % of dialled | Talk time |")
[void]$md.Add("|---|---|---|---|---|---|---|---|---|")
foreach ($row in $repCallArr) {
    [void]$md.Add("| $($row.Rep) | $($row.ContactsAssigned) | $($row.ContactsDialled) | $($row.DialledPct)% | $($row.TotalAttempts) | $($row.ContactsConnectedByDuration) | $($row.ContactsConnectedByStatus) | $($row.ConnectPctOfDialled)% | $($row.TotalTalkTimeMin) min |")
}
[void]$md.Add("")
foreach ($rep in $AssignedReps) {
    if (-not $dialledDispByRep.ContainsKey($rep)) { continue }
    [void]$md.Add("### Disposition of dialled contacts - $rep")
    [void]$md.Add("")
    [void]$md.Add("| Disposition | Contacts |")
    [void]$md.Add("|---|---|")
    foreach ($t in $dialledDispByRep[$rep]) { [void]$md.Add("| $($t.Value) | $($t.Count) |") }
    [void]$md.Add("")
}
$md | Set-Content -Path $summaryPath -Encoding utf8
Write-LsqLog "Markdown summary written: $summaryPath" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "=== ICP Source audit complete ===" $logPath
