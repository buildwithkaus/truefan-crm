<#
.SYNOPSIS
  READ-ONLY: SMB calling scorecard in the SalesOps sheet's layout - monthly Calling /
  Prospect targets, month-to-date progress, the target day's ("previous day") numbers,
  what is left, and the daily run-rate required - grouped by team, with an automatic
  reconciliation against the SalesOps figures.

.DESCRIPTION
  Extends 24-daily-calling-report.ps1 from a single-day view to the target-tracking view
  SalesOps actually circulates. Both windows are computed in ONE pass over the activity
  trail (month-to-date and the target day), because the per-lead activity pull is the
  expensive part - there is no bulk Activity read endpoint.

  THE CORRECTION THAT MOTIVATED THIS SCRIPT. 24-daily-calling-report.ps1 defaulted to
  pulling activity only for leads OWNED by the reported reps. Measured against SalesOps'
  2026-08-04 figures that undercounted the day by 446 calls (1,776 vs 2,222), because reps
  dial leads owned by someone else - above all the 4,135-lead "Kaustubh ICP" list, which
  still sits under Kaustubh Chauhan's ownership. Arjun Rathi was the extreme case: 7 calls
  by the owner-scoped read versus 152 in the SalesOps sheet. This script therefore scans
  EVERY candidate lead by default; -RepOwnedOnly restores the old (faster, wrong) behaviour.

  TWO ATTRIBUTION MODELS, BOTH REPORTED. It is genuinely ambiguous who should be credited
  when rep A works a lead owned by rep B, and the answer differs per metric, so this
  computes both rather than picking one silently:
    ByActor - who placed the call (EventCode 22 ActivityFields.CreatedBy) or who made the
              stage change (EventCode 3002 Data.CreatedBy). "Who did the work."
    ByOwner - the lead's OwnerIdName. "Whose book it counts against."
  The scorecard prints ByActor (it matches SalesOps most closely) and the reconciliation
  section reports both against the SalesOps numbers, so the gap identifies which model
  their report is really using.

  Everything else follows 24-daily-calling-report.ps1's verified mechanics: UTC/IST day
  windows (CLAUDE.md gotcha #5), negative controls before any filter is trusted, pagination
  sorted by the immutable CreatedOn, and Expand-LsqRows on every page.

  Read-only throughout. Do not run alongside another live-API script - account-wide rate limit.

.PARAMETER TargetDate
  The "previous day" column, local/IST. Default 2026-08-04.

.PARAMETER MonthStart
  First day of the target period, local/IST. Default 2026-08-01.

.PARAMETER WorkingDaysRemaining
  Divisor for the "Daily ... Required" columns. Taken from the SalesOps sheet (21), not
  derived - their working-day calendar is not encoded anywhere in this repo.

.NOTES
  pwsh ./scripts/leadsquared/migration/25-smb-calling-scorecard.ps1
#>

param(
    [string]$TargetDate = "2026-08-04",
    [string]$MonthStart = "2026-08-01",
    [int]$WorkingDaysRemaining = 21,
    [switch]$RepOwnedOnly
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath     = Join-Path $dataDir "smb_scorecard_log.txt"
$jsonPath    = Join-Path $dataDir "smb_scorecard_$stamp.json"
$summaryPath = Join-Path $dataDir "smb_scorecard_$stamp.md"

# ---------------------------------------------------------------------------------------
# Roster, teams and targets - transcribed from the SalesOps sheet. Verified 2026-08-05:
# the per-rep targets sum to 84,720 and 16 x 120 = 1,920, matching the sheet's own totals
# exactly, which confirms the transcription.
#
# LsqName is the OwnerIdName actually stored in LeadSquared. It differs from the SalesOps
# name in two places, both confirmed against live data: "Akshita Garg" does not exist in
# LSQ (the account holds "Akshita Sharma"), and "Adarsh Pandey" is stored lower-case.
# ---------------------------------------------------------------------------------------
$Roster = @(
    [pscustomobject]@{ Team="Team #ONE";       Lead=$true;  SheetName="Adarsh Pandey";     LsqName="adarsh pandey";     CallTarget=2880; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Nikhil Sharma";     LsqName="Nikhil Sharma";     CallTarget=4320; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Rishi Saraswat";    LsqName="Rishi Saraswat";    CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Subham Tak";        LsqName="Subham Tak";        CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Vikhyat Verma";     LsqName="Vikhyat Verma";     CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Rahul Madaan";      LsqName="Rahul Madaan";      CallTarget=4320; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Abhishek Tripathi"; LsqName="Abhishek Tripathi"; CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Akshita Garg";      LsqName="Akshita Sharma";    CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team #ONE";       Lead=$false; SheetName="Saurabh Sharma";    LsqName="Saurabh Sharma";    CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team Achievers";  Lead=$true;  SheetName="Mayank Arora";      LsqName="Mayank Arora";      CallTarget=2880; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team Achievers";  Lead=$false; SheetName="Ashutosh Ojha";     LsqName="Ashutosh Ojha";     CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team Achievers";  Lead=$false; SheetName="Twinkle Sutrakar";  LsqName="Twinkle Sutrakar";  CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team Achievers";  Lead=$false; SheetName="Kartikey Mishra";   LsqName="Kartikey Mishra";   CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team Achievers";  Lead=$false; SheetName="Prakhar Gupta";     LsqName="Prakhar Gupta";     CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team Achievers";  Lead=$false; SheetName="Arjun Rathi";       LsqName="Arjun Rathi";       CallTarget=6000; ProspectTarget=120 }
    [pscustomobject]@{ Team="Team Achievers";  Lead=$false; SheetName="Neha Advani";       LsqName="Neha Advani";       CallTarget=4320; ProspectTarget=120 }
)

# SalesOps' own published figures for the same period, for automatic reconciliation.
$SalesOps = @{
    "Adarsh Pandey"     = @{ CallsMTD=186; CallsDay=134; ProspMTD=2; ProspDay=2 }
    "Nikhil Sharma"     = @{ CallsMTD=464; CallsDay=182; ProspMTD=3; ProspDay=1 }
    "Rishi Saraswat"    = @{ CallsMTD=434; CallsDay=170; ProspMTD=7; ProspDay=4 }
    "Subham Tak"        = @{ CallsMTD=433; CallsDay=232; ProspMTD=6; ProspDay=4 }
    "Vikhyat Verma"     = @{ CallsMTD=581; CallsDay=209; ProspMTD=1; ProspDay=0 }
    "Rahul Madaan"      = @{ CallsMTD=169; CallsDay=34;  ProspMTD=1; ProspDay=0 }
    "Abhishek Tripathi" = @{ CallsMTD=469; CallsDay=183; ProspMTD=8; ProspDay=4 }
    "Akshita Garg"      = @{ CallsMTD=169; CallsDay=169; ProspMTD=1; ProspDay=1 }
    "Saurabh Sharma"    = @{ CallsMTD=387; CallsDay=0;   ProspMTD=4; ProspDay=0 }
    "Mayank Arora"      = @{ CallsMTD=122; CallsDay=36;  ProspMTD=1; ProspDay=1 }
    "Ashutosh Ojha"     = @{ CallsMTD=687; CallsDay=193; ProspMTD=4; ProspDay=2 }
    "Twinkle Sutrakar"  = @{ CallsMTD=535; CallsDay=172; ProspMTD=5; ProspDay=2 }
    "Kartikey Mishra"   = @{ CallsMTD=325; CallsDay=175; ProspMTD=4; ProspDay=1 }
    "Prakhar Gupta"     = @{ CallsMTD=362; CallsDay=181; ProspMTD=7; ProspDay=3 }
    "Arjun Rathi"       = @{ CallsMTD=469; CallsDay=152; ProspMTD=7; ProspDay=5 }
    "Neha Advani"       = @{ CallsMTD=0;   CallsDay=0;   ProspMTD=0; ProspDay=0 }
}

$ProspectStageName = "Prospect"

# ---------------------------------------------------------------------------------------
# Windows. Local machine is IST; storage is UTC.
# ---------------------------------------------------------------------------------------
# NOTE the local is $monthStartDt, not $monthStart: PowerShell variable names are
# case-INSENSITIVE, so a local $monthStart is the very same variable as the [string]
# parameter $MonthStart, and assigning a [datetime] to it silently coerces back to a string.
# That produced "[System.String] does not contain a method named 'ToUniversalTime'".
$dayStart     = [datetime]::ParseExact($TargetDate, "yyyy-MM-dd", $null)
$dayEnd       = $dayStart.AddDays(1)
$monthStartDt = [datetime]::ParseExact($MonthStart, "yyyy-MM-dd", $null)

$dayStartUtc   = $dayStart.ToUniversalTime()
$dayEndUtc     = $dayEnd.ToUniversalTime()
$monthStartUtc = $monthStartDt.ToUniversalTime()
# MTD is bounded by the END of the target day, so the scorecard reproduces the state
# SalesOps published rather than silently including everything since.
$mtdEndUtc     = $dayEndUtc
$floorStr      = Get-LsqTimestamp -LocalTime $monthStartDt

Write-LsqLog "=== SMB CALLING SCORECARD (READ-ONLY) ===" $logPath
Write-LsqLog "Target day : $($dayStart.ToString('yyyy-MM-dd dddd'))   UTC $($dayStartUtc.ToString('yyyy-MM-dd HH:mm')) -> $($dayEndUtc.ToString('yyyy-MM-dd HH:mm'))" $logPath
Write-LsqLog "MTD window : $($monthStartDt.ToString('yyyy-MM-dd')) -> end of target day   UTC $($monthStartUtc.ToString('yyyy-MM-dd HH:mm')) -> $($mtdEndUtc.ToString('yyyy-MM-dd HH:mm'))" $logPath
Write-LsqLog "Working days remaining (from SalesOps sheet): $WorkingDaysRemaining" $logPath

# ---------------------------------------------------------------------------------------
# Negative controls.
# ---------------------------------------------------------------------------------------
foreach ($f in @("ProspectActivityDate_Max", "ModifiedOn")) {
    $neg = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = $f; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID" -SortColumn "CreatedOn" -SortDirection "1" -PageIndex 1 -PageSize 10))
    if ($neg.Count -ne 0) { throw "Negative control FAILED: $f > 2099-01-01 returned $($neg.Count) rows, expected 0 - aborting." }
}
Write-LsqLog "Negative controls passed." $logPath

# ---------------------------------------------------------------------------------------
# Candidate leads since month start: union of both filters, paged on immutable CreatedOn.
# ---------------------------------------------------------------------------------------
$leadCols = "ProspectID,Source,OwnerId,OwnerIdName,ProspectStage,mx_Call_Disposition,ModifiedOn,ProspectActivityDate_Max"

function Get-LeadsSince {
    param([string]$LookupName, [string]$Floor, [string]$Cols)
    $all = New-Object System.Collections.Generic.List[object]
    $page = 1
    while ($true) {
        $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
            -Filter @{ LookupName = $LookupName; LookupValue = $Floor; SqlOperator = ">" } `
            -ColumnsCsv $Cols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
        if ($resp.Count -eq 0) { break }
        foreach ($r in $resp) { [void]$all.Add($r) }
        if ($resp.Count -lt 1000) { break }
        $page++
        Start-Sleep -Milliseconds 250
    }
    return $all.ToArray()
}

# Leg 1 - CALLS. ProspectActivityDate_Max alone is sufficient and complete for calls: a
# telephony call IS an activity, so it always moves the max-activity date. Confirmed
# empirically 2026-08-05 - of 150 randomly sampled leads that ONLY the ModifiedOn filter
# surfaced, exactly 0 carried any EventCode-22 call since month start. Dropping the
# ModifiedOn leg therefore removes 7,245 leads (~30 min of API time) with no loss.
$byActivity = Get-LeadsSince "ProspectActivityDate_Max" $floorStr $leadCols

# Leg 2 - PROSPECTS. Stage-change events are not safely covered by the same assumption, so
# rather than trusting that a 3002 moves the activity date, every lead at a deal-bearing
# contact stage is swept unconditionally. A contact marked Prospect during the window is
# sitting at Prospect (or has moved on to Customer) by definition, so this is complete for
# the metric being reported, and it is bounded (~1,168 leads).
$dealStage = New-Object System.Collections.Generic.List[object]
foreach ($stage in @("Prospect", "Customer")) {
    $page = 1
    while ($true) {
        $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
            -Filter @{ LookupName = "ProspectStage"; LookupValue = $stage; SqlOperator = "=" } `
            -ColumnsCsv $leadCols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
        if ($resp.Count -eq 0) { break }
        foreach ($r in $resp) { [void]$dealStage.Add($r) }
        if ($resp.Count -lt 1000) { break }
        $page++
        Start-Sleep -Milliseconds 250
    }
}
$byStage = $dealStage.ToArray()

$candidateMap = @{}
foreach ($l in $byActivity) { $candidateMap["$($l.ProspectID)"] = $l }
$addedByStage = 0
foreach ($l in $byStage) {
    $k = "$($l.ProspectID)"
    if (-not $candidateMap.ContainsKey($k)) { $candidateMap[$k] = $l; $addedByStage++ }
}
$candidates = @($candidateMap.Values)
Write-LsqLog "Candidates: activity-since-month-start=$($byActivity.Count) deal-stage=$($byStage.Count) UNION=$($candidates.Count) (+$addedByStage added by the deal-stage sweep)" $logPath
if ($candidates.Count -eq 0) { throw "0 candidate leads - aborting." }
if ($byActivity.Count -lt 5000) { throw "Only $($byActivity.Count) leads with activity since month start - implausibly low for a month of calling; refusing to publish off a possibly truncated scan." }

# ---------------------------------------------------------------------------------------
# Owner identities, from live data plus the stored roster.
# ---------------------------------------------------------------------------------------
$idByName = @{}; $nameById = @{}
foreach ($l in $candidates) {
    $n = "$($l.OwnerIdName)"; $i = "$($l.OwnerId)"
    if ([string]::IsNullOrWhiteSpace($n) -or [string]::IsNullOrWhiteSpace($i)) { continue }
    if (-not $idByName.ContainsKey($n)) { $idByName[$n] = $i }
    $nameById[$i] = $n
}
$rosterPath = Join-Path $dataDir "active_rep_ids_temp.json"
if (Test-Path $rosterPath) {
    foreach ($r in @(Expand-LsqRows (Get-Content $rosterPath -Raw | ConvertFrom-Json))) {
        if (-not $idByName.ContainsKey($r.Name)) { $idByName[$r.Name] = $r.OwnerId }
        if (-not $nameById.ContainsKey($r.OwnerId)) { $nameById[$r.OwnerId] = $r.Name }
    }
}
# Every rostered rep must resolve. A silent zero for a named rep is the failure this whole
# report exists to detect, so an unresolvable name is fatal.
foreach ($r in $Roster) {
    if (-not ($idByName.Keys | Where-Object { $_ -ieq $r.LsqName })) {
        throw "Rostered rep [$($r.SheetName)] -> LSQ name [$($r.LsqName)] did not resolve to any owner. Fix the roster's LsqName before trusting this report."
    }
}
Write-LsqLog "Owner identities resolved: $($idByName.Count); all $($Roster.Count) rostered reps matched." $logPath
$rosterIds = @{}
foreach ($r in $Roster) {
    $hit = $idByName.Keys | Where-Object { $_ -ieq $r.LsqName } | Select-Object -First 1
    $rosterIds[$idByName[$hit]] = $r.LsqName
}

# ---------------------------------------------------------------------------------------
# Activity scope. Default is EVERY candidate - see the header note on the 446-call undercount.
# ---------------------------------------------------------------------------------------
if ($RepOwnedOnly) {
    $toPull = @($candidates | Where-Object { $rosterIds.ContainsKey("$($_.OwnerId)") })
    Write-LsqLog "*** Activity scope: REP-OWNED ONLY - $($toPull.Count) leads. This is known to UNDERCOUNT (calls on leads owned by others are invisible). ***" $logPath
} else {
    $toPull = $candidates
    Write-LsqLog "Activity scope: ALL candidate owners - $($toPull.Count) leads." $logPath
}
if ($toPull.Count -eq 0) { throw "0 leads in activity scope - aborting." }

function Get-DataValue {
    param($Activity, [string]$Key)
    foreach ($d in @($Activity.Data)) { if ("$($d.Key)" -eq $Key) { return "$($d.Value)" } }
    return ""
}

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# Flat event rows; every aggregate below derives from one pass over these.
$events = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0; $done = 0
foreach ($c in $toPull) {
    $ownerName = "$($c.OwnerIdName)"
    $url = "$base/ProspectActivity.svc/Retrieve?accessKey=$ak&secretKey=$sk&leadId=$($c.ProspectID)"
    try {
        $r = Invoke-LsqWithRetry -What "activity $($c.ProspectID)" -Action {
            Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -ErrorAction Stop
        }
        $ok++
        foreach ($a in @($r.ProspectActivities)) {
            $ec = "$($a.EventCode)"
            if ($ec -ne "22" -and $ec -ne "3002") { continue }
            $when = [datetime]::MinValue
            if (-not [datetime]::TryParse("$($a.CreatedOn)", [ref]$when)) { continue }
            if ($when -lt $monthStartUtc -or $when -ge $mtdEndUtc) { continue }

            if ($ec -eq "22") {
                $dur = 0
                [void][int]::TryParse("$($a.ActivityFields.mx_Custom_3)", [ref]$dur)
                $actorId = "$($a.ActivityFields.CreatedBy)"
                $actorName = "<unknown>"
                if ($nameById.ContainsKey($actorId)) { $actorName = $nameById[$actorId] }
                [void]$events.Add([pscustomobject]@{
                    Kind = "Call"; ActorName = $actorName; OwnerName = $ownerName
                    InDay = ($when -ge $dayStartUtc -and $when -lt $dayEndUtc)
                    Connected = ($dur -gt 0)
                })
            } else {
                if ((Get-DataValue $a "CurrentStage") -ne $ProspectStageName) { continue }
                # 3002 records the actor as a display NAME, not a GUID.
                [void]$events.Add([pscustomobject]@{
                    Kind = "Prospect"; ActorName = (Get-DataValue $a "CreatedBy"); OwnerName = $ownerName
                    InDay = ($when -ge $dayStartUtc -and $when -lt $dayEndUtc)
                    Connected = $false
                })
            }
        }
    } catch {
        $failed++
        Write-LsqLog "  activity fetch failed for lead $($c.ProspectID) -> $($_.Exception.Message)" $logPath
    }
    $done++
    if ($done % 500 -eq 0) { Write-LsqLog "  activity pulled: $done/$($toPull.Count)  (events so far: $($events.Count))" $logPath }
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Activity pull complete: $ok ok, $failed failed, of $($toPull.Count)." $logPath
if ($failed -gt ($toPull.Count * 0.02)) {
    Write-LsqLog "*** WARNING: $failed activity fetches failed (>2%) - every number below is an UNDERCOUNT. ***" $logPath
}
$allEvents = $events.ToArray()
if ($allEvents.Count -eq 0) { throw "0 call/stage events found in the window - refusing to publish an empty scorecard." }

# ---------------------------------------------------------------------------------------
# Aggregation. Pure functions - no logging inside (CLAUDE.md gotcha #11 corollary).
# ---------------------------------------------------------------------------------------
function Measure-Rep {
    param($Events, [string]$RepName, [string]$Field)   # Field = ActorName | OwnerName
    $mine = @($Events | Where-Object { $_.$Field -eq $RepName })
    $calls = @($mine | Where-Object { $_.Kind -eq "Call" })
    $prosp = @($mine | Where-Object { $_.Kind -eq "Prospect" })
    return [pscustomobject]@{
        CallsMTD    = $calls.Count
        CallsDay    = @($calls | Where-Object { $_.InDay }).Count
        ConnMTD     = @($calls | Where-Object { $_.Connected }).Count
        ConnDay     = @($calls | Where-Object { $_.InDay -and $_.Connected }).Count
        ProspMTD    = $prosp.Count
        ProspDay    = @($prosp | Where-Object { $_.InDay }).Count
    }
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($r in $Roster) {
    $byActor = Measure-Rep $allEvents $r.LsqName "ActorName"
    $byOwner = Measure-Rep $allEvents $r.LsqName "OwnerName"
    $so = $SalesOps[$r.SheetName]

    $callsLeft = [Math]::Max(0, $r.CallTarget - $byActor.CallsMTD)
    $prospLeft = [Math]::Max(0, $r.ProspectTarget - $byActor.ProspMTD)
    $dailyCalls = 0; $dailyProsp = 0
    if ($WorkingDaysRemaining -gt 0) {
        $dailyCalls = [Math]::Ceiling($callsLeft / $WorkingDaysRemaining)
        $dailyProsp = [Math]::Ceiling($prospLeft / $WorkingDaysRemaining)
    }
    [void]$rows.Add([pscustomobject]@{
        Team = $r.Team; Lead = $r.Lead; Rep = $r.SheetName; LsqName = $r.LsqName
        CallTarget = $r.CallTarget; ProspectTarget = $r.ProspectTarget
        CallsMTD = $byActor.CallsMTD; CallsDay = $byActor.CallsDay
        ConnMTD  = $byActor.ConnMTD;  ConnDay  = $byActor.ConnDay
        CallsLeft = $callsLeft; DailyCallsRequired = $dailyCalls
        ProspMTD = $byActor.ProspMTD; ProspDay = $byActor.ProspDay
        ProspLeft = $prospLeft; DailyProspectsRequired = $dailyProsp
        CallsMTD_ByOwner = $byOwner.CallsMTD; CallsDay_ByOwner = $byOwner.CallsDay
        ProspMTD_ByOwner = $byOwner.ProspMTD; ProspDay_ByOwner = $byOwner.ProspDay
        SO_CallsMTD = $so.CallsMTD; SO_CallsDay = $so.CallsDay
        SO_ProspMTD = $so.ProspMTD; SO_ProspDay = $so.ProspDay
        DiffCallsDay = $byActor.CallsDay - $so.CallsDay
        DiffCallsMTD = $byActor.CallsMTD - $so.CallsMTD
        DiffProspDay = $byActor.ProspDay - $so.ProspDay
    })
}
$scorecard = $rows.ToArray()

function Write-Scorecard {
    param($Rows, [string]$LogPath)
    Write-LsqLog "" $LogPath
    Write-LsqLog "=== SMB CALLING SCORECARD (attribution: BY ACTOR - who placed the call / made the change) ===" $LogPath
    Write-LsqLog ("  {0,-20} {1,7} {2,6} {3,6} {4,8} {5,7} | {6,6} {7,6} {8,6} {9,6} {10,6}" -f `
        "Rep","CallTgt","MTD","PrevDay","CallsLeft","Daily","PrTgt","PrMTD","PrDay","PrLeft","Daily") $LogPath
    foreach ($team in ($Rows | Select-Object -ExpandProperty Team -Unique)) {
        Write-LsqLog "  --- $team ---" $LogPath
        foreach ($x in ($Rows | Where-Object { $_.Team -eq $team })) {
            $tag = if ($x.Lead) { "*" } else { " " }
            Write-LsqLog ("  {0}{1,-19} {2,7} {3,6} {4,6} {5,8} {6,7} | {7,6} {8,6} {9,6} {10,6} {11,6}" -f `
                $tag, $x.Rep, $x.CallTarget, $x.CallsMTD, $x.CallsDay, $x.CallsLeft, $x.DailyCallsRequired, `
                $x.ProspectTarget, $x.ProspMTD, $x.ProspDay, $x.ProspLeft, $x.DailyProspectsRequired) $LogPath
        }
    }
}
Write-Scorecard $scorecard $logPath

$tCallTgt  = ($scorecard | Measure-Object -Property CallTarget -Sum).Sum
$tCallsMTD = ($scorecard | Measure-Object -Property CallsMTD -Sum).Sum
$tCallsDay = ($scorecard | Measure-Object -Property CallsDay -Sum).Sum
$tCallsLeft= ($scorecard | Measure-Object -Property CallsLeft -Sum).Sum
$tProspTgt = ($scorecard | Measure-Object -Property ProspectTarget -Sum).Sum
$tProspMTD = ($scorecard | Measure-Object -Property ProspMTD -Sum).Sum
$tProspDay = ($scorecard | Measure-Object -Property ProspDay -Sum).Sum
$tProspLeft= ($scorecard | Measure-Object -Property ProspLeft -Sum).Sum
Write-LsqLog "" $logPath
Write-LsqLog ("  SMB TOTAL            {0,7} {1,6} {2,6} {3,8}         | {4,6} {5,6} {6,6} {7,6}" -f `
    $tCallTgt, $tCallsMTD, $tCallsDay, $tCallsLeft, $tProspTgt, $tProspMTD, $tProspDay, $tProspLeft) $logPath

# ---------------------------------------------------------------------------------------
# Reconciliation against SalesOps - the point of the exercise.
# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "=== RECONCILIATION vs SalesOps ($($dayStart.ToString('yyyy-MM-dd')) 'previous day' column) ===" $logPath
Write-LsqLog ("  {0,-20} {1,8} {2,8} {3,8} | {4,8} {5,8} {6,8} | {7,8} {8,8}" -f `
    "Rep","CallsSO","CallsAct","CallsOwn","MtdSO","MtdActor","MtdOwner","PrspSO","PrspActor") $logPath
foreach ($x in $scorecard) {
    Write-LsqLog ("  {0,-20} {1,8} {2,8} {3,8} | {4,8} {5,8} {6,8} | {7,8} {8,8}" -f `
        $x.Rep, $x.SO_CallsDay, $x.CallsDay, $x.CallsDay_ByOwner, `
        $x.SO_CallsMTD, $x.CallsMTD, $x.CallsMTD_ByOwner, `
        $x.SO_ProspDay, $x.ProspDay) $logPath
}
$soCallsDay = 0; $soCallsMTD = 0; $soProspDay = 0
foreach ($k in $SalesOps.Keys) { $soCallsDay += $SalesOps[$k].CallsDay; $soCallsMTD += $SalesOps[$k].CallsMTD; $soProspDay += $SalesOps[$k].ProspDay }
$ownCallsDay = ($scorecard | Measure-Object -Property CallsDay_ByOwner -Sum).Sum
$ownCallsMTD = ($scorecard | Measure-Object -Property CallsMTD_ByOwner -Sum).Sum
Write-LsqLog "" $logPath
Write-LsqLog ("  TOTALS  calls day: SalesOps={0}  byActor={1}  byOwner={2}" -f $soCallsDay, $tCallsDay, $ownCallsDay) $logPath
Write-LsqLog ("  TOTALS  calls MTD: SalesOps={0}  byActor={1}  byOwner={2}" -f $soCallsMTD, $tCallsMTD, $ownCallsMTD) $logPath
Write-LsqLog ("  TOTALS  prospects day: SalesOps={0}  byActor={1}" -f $soProspDay, $tProspDay) $logPath

# Calls placed by someone outside the roster, and calls on leads owned outside it - the two
# ways the owner-scoped and actor-scoped reads diverge.
$dayCalls = @($allEvents | Where-Object { $_.Kind -eq "Call" -and $_.InDay })
$offRosterActor = @($dayCalls | Where-Object { -not ($Roster.LsqName -contains $_.ActorName) })
$offRosterOwner = @($dayCalls | Where-Object { -not ($Roster.LsqName -contains $_.OwnerName) })
Write-LsqLog "" $logPath
Write-LsqLog "=== WHERE THE TWO ATTRIBUTION MODELS DIVERGE (target day) ===" $logPath
Write-LsqLog "  Total EventCode-22 calls on the target day (all actors): $($dayCalls.Count)" $logPath
Write-LsqLog "  ... placed by someone NOT on the roster: $($offRosterActor.Count)" $logPath
Write-LsqLog "  ... on a lead OWNED by someone NOT on the roster: $($offRosterOwner.Count)" $logPath
Write-LsqLog "  Top owners of leads dialled on the target day:" $logPath
foreach ($g in (@($dayCalls | Group-Object OwnerName | Sort-Object Count -Descending | Select-Object -First 10))) {
    Write-LsqLog ("     {0,6}  [{1}]" -f $g.Count, $g.Name) $logPath
}
Write-LsqLog "  Top actors placing calls on the target day:" $logPath
foreach ($g in (@($dayCalls | Group-Object ActorName | Sort-Object Count -Descending | Select-Object -First 20))) {
    Write-LsqLog ("     {0,6}  [{1}]" -f $g.Count, $g.Name) $logPath
}

# ---------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------
$snapshot = [pscustomobject]@{
    RunAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TargetDate = $dayStart.ToString("yyyy-MM-dd")
    MonthStart = $monthStartDt.ToString("yyyy-MM-dd")
    WorkingDaysRemaining = $WorkingDaysRemaining
    CandidateLeads = $candidates.Count
    ActivityScope = $toPull.Count
    ActivityOk = $ok
    ActivityFailed = $failed
    Scorecard = $scorecard
    Totals = [pscustomobject]@{
        CallTarget=$tCallTgt; CallsMTD=$tCallsMTD; CallsDay=$tCallsDay; CallsLeft=$tCallsLeft
        ProspectTarget=$tProspTgt; ProspMTD=$tProspMTD; ProspDay=$tProspDay; ProspLeft=$tProspLeft
        SalesOpsCallsDay=$soCallsDay; SalesOpsCallsMTD=$soCallsMTD; SalesOpsProspDay=$soProspDay
        CallsDayByOwner=$ownCallsDay; CallsMTDByOwner=$ownCallsMTD
    }
    DayCallsTotal = $dayCalls.Count
    DayCallsOffRosterActor = $offRosterActor.Count
    DayCallsOffRosterOwner = $offRosterOwner.Count
}
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8
Write-LsqLog "" $logPath
Write-LsqLog "JSON snapshot written: $jsonPath" $logPath

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# SMB Calling Scorecard - previous day $($dayStart.ToString('yyyy-MM-dd dddd'))")
[void]$md.Add("")
[void]$md.Add("MTD window $($monthStartDt.ToString('yyyy-MM-dd')) to end of $($dayStart.ToString('yyyy-MM-dd')). Working days remaining: $WorkingDaysRemaining. Candidate leads $($candidates.Count); activity pulled for $($toPull.Count) ($ok ok / $failed failed).")
[void]$md.Add("")
[void]$md.Add("Attribution: **by actor** (who placed the call / made the stage change).")
[void]$md.Add("")
[void]$md.Add("| Team | Rep | Calling Target | Calls Done | Calls Done on Previous Day | Calls Left | Daily Calls Required | Prospect Target | Prospects made | Prospects made On Previous Day | Prospects left | Daily Prospects Required |")
[void]$md.Add("|---|---|---|---|---|---|---|---|---|---|---|---|")
foreach ($x in $scorecard) {
    $nm = $x.Rep
    if ($x.Lead) { $nm = "**Team Lead: $($x.Rep)**" }
    [void]$md.Add("| $($x.Team) | $nm | $($x.CallTarget) | $($x.CallsMTD) | $($x.CallsDay) | $($x.CallsLeft) | $($x.DailyCallsRequired) | $($x.ProspectTarget) | $($x.ProspMTD) | $($x.ProspDay) | $($x.ProspLeft) | $($x.DailyProspectsRequired) |")
}
[void]$md.Add("| | **SMB Total** | **$tCallTgt** | **$tCallsMTD** | **$tCallsDay** | **$tCallsLeft** | | **$tProspTgt** | **$tProspMTD** | **$tProspDay** | **$tProspLeft** | |")
[void]$md.Add("")
[void]$md.Add("## Reconciliation vs SalesOps")
[void]$md.Add("")
[void]$md.Add("| Rep | Calls prev day (SalesOps) | by actor | by owner | Calls MTD (SalesOps) | by actor | by owner | Prospects prev day (SalesOps) | by actor |")
[void]$md.Add("|---|---|---|---|---|---|---|---|---|")
foreach ($x in $scorecard) {
    [void]$md.Add("| $($x.Rep) | $($x.SO_CallsDay) | $($x.CallsDay) | $($x.CallsDay_ByOwner) | $($x.SO_CallsMTD) | $($x.CallsMTD) | $($x.CallsMTD_ByOwner) | $($x.SO_ProspDay) | $($x.ProspDay) |")
}
[void]$md.Add("| **Total** | **$soCallsDay** | **$tCallsDay** | **$ownCallsDay** | **$soCallsMTD** | **$tCallsMTD** | **$ownCallsMTD** | **$soProspDay** | **$tProspDay** |")
[void]$md.Add("")
[void]$md.Add("## Attribution divergence on the target day")
[void]$md.Add("")
[void]$md.Add("- Total telephony calls logged that day (all actors): **$($dayCalls.Count)**")
[void]$md.Add("- Placed by someone not on the roster: **$($offRosterActor.Count)**")
[void]$md.Add("- On a lead owned by someone not on the roster: **$($offRosterOwner.Count)**")
$md | Set-Content -Path $summaryPath -Encoding utf8
Write-LsqLog "Markdown summary written: $summaryPath" $logPath
Write-LsqLog "" $logPath
Write-LsqLog "=== Scorecard complete ===" $logPath
