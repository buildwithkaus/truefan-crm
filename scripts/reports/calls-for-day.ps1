<#
.SYNOPSIS
  READ-ONLY: native LSQ outbound calling activity (EventCode 22, "Outbound Phone Call
  Activity" - the telephony-integration call log, auto-created whenever a call is placed
  through the system) for a specific calendar day, per rep: contacts called, call attempts,
  Answered vs NotAnswered, call duration.

.DESCRIPTION
  No bulk Activity read endpoint exists (ProspectActivity.svc/Retrieve is one call per lead
  - AUTOMATION_CAPABILITIES.md), so this cannot sweep the whole account for one day's calls.
  Instead:
    1. Find CANDIDATE leads via Leads.Get filtered on ProspectActivityDate_Max > (the day
       before TargetDate, at local midnight, converted to UTC) - a bounded superset of
       "anyone touched on/after the target day", far smaller than the full 90K-lead base.
       A negative-control filter (a date far in the future) must return 0 rows before the
       real filter's result is trusted, per CLAUDE.md's enumerate-don't-guess corollary.
    2. For each candidate, pull its full activity trail and keep only EventCode 22 events
       whose CreatedOn falls inside the target day's UTC window - the account is IST,
       storage is UTC (CLAUDE.md gotcha #5), so the day boundary is computed from local
       midnight -> UTC, not by string-matching a date.
    3. Tally per rep (ActivityFields.CreatedBy, resolved against the active-rep reference
       file): distinct contacts called, total call attempts, Answered/NotAnswered counts,
       and duration (ActivityFields.mx_Custom_3, confirmed live 2026-08-03 to hold the
       call's duration in seconds - cross-checked against the duration embedded in
       ActivityEvent_Note across 116 real calls, exact match every time).

  Read-only throughout - no CRM writes.

.PARAMETER TargetDate
  The calendar day (local/IST) to report on. Defaults to the most recent Friday.

.NOTES
  pwsh ./scripts/leadsquared/migration/22-friday-calls-audit.ps1
  pwsh ./scripts/leadsquared/migration/22-friday-calls-audit.ps1 -TargetDate "2026-07-31"
#>

param(
    [string]$TargetDate = ""
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "friday_calls_audit_log.txt"
$jsonPath = Join-Path $dataDir "friday_calls_audit_$stamp.json"
$summaryPath = Join-Path $dataDir "friday_calls_audit_summary_$stamp.md"

if ([string]::IsNullOrWhiteSpace($TargetDate)) {
    $d = Get-Date
    while ($d.DayOfWeek -ne "Friday") { $d = $d.AddDays(-1) }
    $dayStart = Get-Date -Year $d.Year -Month $d.Month -Day $d.Day -Hour 0 -Minute 0 -Second 0
} else {
    $dayStart = [datetime]::ParseExact($TargetDate, "yyyy-MM-dd", $null)
}
$dayEnd = $dayStart.AddDays(1)
$dayBeforeStart = $dayStart.AddDays(-1)

# Local machine is confirmed India Standard Time (2026-08-03) - .ToUniversalTime() converts
# correctly. Storage is UTC (CLAUDE.md gotcha #5).
$dayStartUtc = $dayStart.ToUniversalTime()
$dayEndUtc = $dayEnd.ToUniversalTime()
$candidateFloorUtc = $dayBeforeStart.ToUniversalTime()
$candidateFloorStr = Get-LsqTimestamp -LocalTime $dayBeforeStart

Write-LsqLog "=== Calling activity audit for $($dayStart.ToString('yyyy-MM-dd dddd')) (READ-ONLY) ===" $logPath
Write-LsqLog "Day window (UTC): $($dayStartUtc.ToString('yyyy-MM-dd HH:mm:ss')) to $($dayEndUtc.ToString('yyyy-MM-dd HH:mm:ss'))" $logPath
Write-LsqLog "Candidate floor (ProspectActivityDate_Max >, UTC): $candidateFloorStr" $logPath

# --- Negative control: a floor far in the future must return 0 rows before trusting the real filter ---
$negControl = @(Expand-LsqRows (Invoke-LsqLeadSearch `
    -Filter @{ LookupName = "ProspectActivityDate_Max"; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">" } `
    -ColumnsCsv "ProspectID" -PageIndex 1 -PageSize 10))
if ($negControl.Count -ne 0) { throw "Negative control failed: filtering ProspectActivityDate_Max > 2099-01-01 returned $($negControl.Count) rows, expected 0. Do not trust this filter shape - aborting." }
Write-LsqLog "Negative control passed (0 rows for a future-dated floor)." $logPath

# --- Candidate leads: touched on/after the day before the target day ---
$candidates = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "ProspectActivityDate_Max"; LookupValue = $candidateFloorStr; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,OwnerId,OwnerIdName" -SortColumn "ProspectActivityDate_Max" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$candidates.Add($l) }
    if ($page % 10 -eq 0) { Write-LsqLog "  candidates scanned: $($candidates.Count)..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Candidate leads (touched on/after $($dayBeforeStart.ToString('yyyy-MM-dd'))): $($candidates.Count)" $logPath
if ($candidates.Count -eq 0) { throw "0 candidate leads found - refusing to report an empty day as a real finding without investigating the filter." }

# --- Active rep reference (for resolving CreatedBy GUID -> name) ---
$activeRepPath = Join-Path $dataDir "active_rep_ids_temp.json"
$activeReps = @(Expand-LsqRows (Get-Content $activeRepPath -Raw | ConvertFrom-Json))
if ($activeReps.Count -lt 15) { throw "Only $($activeReps.Count) active reps loaded - refusing to attribute calls from suspect reference data." }
$nameById = @{}
foreach ($r in $activeReps) { $nameById[$r.OwnerId] = $r.Name }

# --- Per-candidate activity pull, filtered to EventCode 22 within the target day ---
$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$byRep = @{}   # ownerId -> pscustomobject accumulator
$checked = 0
$totalCallsFound = 0
foreach ($c in $candidates) {
    $url = "$base/ProspectActivity.svc/Retrieve?accessKey=$ak&secretKey=$sk&leadId=$($c.ProspectID)"
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
        $checked++
        $calls = @($r.ProspectActivities) | Where-Object {
            "$($_.EventCode)" -eq "22" -and
            [datetime]$_.CreatedOn -ge $dayStartUtc -and
            [datetime]$_.CreatedOn -lt $dayEndUtc
        }
        foreach ($call in $calls) {
            $totalCallsFound++
            $repId = "$($call.ActivityFields.CreatedBy)"
            if ([string]::IsNullOrWhiteSpace($repId)) { $repId = "<BLANK>" }
            if (-not $byRep.ContainsKey($repId)) {
                $repName = if ($nameById.ContainsKey($repId)) { $nameById[$repId] } else { $repId }
                $byRep[$repId] = [pscustomobject]@{
                    RepId = $repId
                    RepName = $repName
                    ContactsCalled = New-Object System.Collections.Generic.HashSet[string]
                    TotalAttempts = 0
                    Answered = 0
                    NotAnswered = 0
                    OtherStatus = 0
                    TotalDurationSec = 0
                    AnsweredDurations = New-Object System.Collections.Generic.List[int]
                }
            }
            $acc = $byRep[$repId]
            [void]$acc.ContactsCalled.Add("$($c.ProspectID)")
            $acc.TotalAttempts++
            $status = "$($call.ActivityFields.Status)"
            $dur = 0
            [void][int]::TryParse("$($call.ActivityFields.mx_Custom_3)", [ref]$dur)
            if ($status -eq "Answered") { $acc.Answered++; $acc.TotalDurationSec += $dur; [void]$acc.AnsweredDurations.Add($dur) }
            elseif ($status -eq "NotAnswered") { $acc.NotAnswered++ }
            else { $acc.OtherStatus++ }
        }
    } catch {
        Write-LsqLog "  activity fetch failed for lead $($c.ProspectID) -> $($_.Exception.Message)" $logPath
    }
    if ($checked % 500 -eq 0) { Write-LsqLog "  candidates checked: $checked/$($candidates.Count)   calls found so far: $totalCallsFound" $logPath }
    Start-Sleep -Milliseconds 300
}
Write-LsqLog "Candidates checked: $checked/$($candidates.Count)   total EventCode-22 calls found on $($dayStart.ToString('yyyy-MM-dd')): $totalCallsFound" $logPath

# --- Report ---
Write-LsqLog "" $logPath
Write-LsqLog "=== CALLS BY REP - $($dayStart.ToString('yyyy-MM-dd dddd')) ===" $logPath
$rows = New-Object System.Collections.Generic.List[object]
foreach ($k in $byRep.Keys) {
    $a = $byRep[$k]
    $avgDur = if ($a.AnsweredDurations.Count -gt 0) { [Math]::Round(($a.AnsweredDurations | Measure-Object -Average).Average, 0) } else { 0 }
    [void]$rows.Add([pscustomobject]@{
        Rep = $a.RepName
        ContactsCalled = $a.ContactsCalled.Count
        TotalAttempts = $a.TotalAttempts
        Answered = $a.Answered
        NotAnswered = $a.NotAnswered
        OtherStatus = $a.OtherStatus
        AvgDurationSecAnswered = $avgDur
        TotalTalkTimeMin = [Math]::Round($a.TotalDurationSec / 60.0, 1)
    })
}
$rows = $rows | Sort-Object -Property TotalAttempts -Descending
foreach ($row in $rows) {
    Write-LsqLog ("  {0,-20} contacts={1,-5} attempts={2,-5} answered={3,-5} notAnswered={4,-5} avgDurAnswered={5,4}s  talkTime={6,6}min" -f $row.Rep, $row.ContactsCalled, $row.TotalAttempts, $row.Answered, $row.NotAnswered, $row.AvgDurationSecAnswered, $row.TotalTalkTimeMin) $logPath
}

$grandContacts = ($rows | Measure-Object -Property ContactsCalled -Sum).Sum
$grandAttempts = ($rows | Measure-Object -Property TotalAttempts -Sum).Sum
$grandAnswered = ($rows | Measure-Object -Property Answered -Sum).Sum
Write-LsqLog "" $logPath
Write-LsqLog "TOTALS: $grandContacts distinct contacts called, $grandAttempts call attempts, $grandAnswered answered ($([Math]::Round(100.0*$grandAnswered/[Math]::Max($grandAttempts,1),1))%)" $logPath

# --- Output ---
$snapshot = [pscustomobject]@{
    TargetDate = $dayStart.ToString("yyyy-MM-dd")
    CandidateLeadsScanned = $candidates.Count
    CandidatesChecked = $checked
    TotalCallsFound = $totalCallsFound
    ByRep = $rows
}
$snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath
Write-LsqLog "" $logPath
Write-LsqLog "JSON snapshot written: $jsonPath" $logPath

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# Outbound calling activity - $($dayStart.ToString('yyyy-MM-dd dddd'))")
[void]$md.Add("")
[void]$md.Add("Candidate leads scanned: $($candidates.Count)   Total EventCode-22 calls found: $totalCallsFound")
[void]$md.Add("")
[void]$md.Add("| Rep | Contacts called | Attempts | Answered | Not Answered | Avg duration (answered) | Total talk time |")
[void]$md.Add("|---|---|---|---|---|---|---|")
foreach ($row in $rows) {
    [void]$md.Add("| $($row.Rep) | $($row.ContactsCalled) | $($row.TotalAttempts) | $($row.Answered) | $($row.NotAnswered) | $($row.AvgDurationSecAnswered)s | $($row.TotalTalkTimeMin) min |")
}
[void]$md.Add("")
[void]$md.Add("**Totals: $grandContacts distinct contacts called, $grandAttempts call attempts, $grandAnswered answered.**")
$md | Set-Content -Path $summaryPath
Write-LsqLog "Markdown summary written: $summaryPath" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "=== Calling activity audit complete ===" $logPath
