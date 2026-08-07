<#
.SYNOPSIS
  READ-ONLY: current Lead distribution (Contact Stage, Call Disposition, Source,
  Disqualification Reason) plus a sampled audit of REP ACTIVITY LOGGING - what is actually
  in the Activity trail behind a Call Disposition, not just the stage/disposition field
  values themselves.

.DESCRIPTION
  Two passes:
    A. Leads - one full paginated scan. Contact Stage / Call Disposition / Source /
       Disqualification Reason distributions. Builds, per active rep, the pool of their
       owned leads that currently carry a Call Disposition (the "claimed as worked" set)
       for pass B to sample from.
    B. Activity sampling - no bulk Activity read endpoint exists
       (ProspectActivity.svc/Retrieve is one call per lead, per AUTOMATION_CAPABILITIES.md),
       so this SAMPLES up to $SamplePerRep "worked" leads per active rep and pulls each
       one's full activity trail. Tallies EventCode/EventName composition - the manually
       filled "01. Phone Call/ Follow Up" activity (event 203, the one meant to carry
       Status/Outcome/Next Step) versus auto-generated events (StageChange, LeadAssigned,
       telephony "Outbound Phone Call Activity", the Callkaro AI dialler's "AI Phone Call/
       Follow Up") - and asks two direct questions per sampled lead:
         - has this lead EVER had a real rep-filled 01. Phone Call/Follow Up activity?
         - is the MOST RECENT activity of any kind actually one of those, or did the
           current disposition get set some other way (direct field edit, bulk update,
           reading the telephony log alone without filling the form)?
       Also checks whether the 203 activities that do exist have Status actually filled -
       every field on that activity type is optional (confirmed live against
       LeadManagement.svc/LeadActivityMetaData for event 203, 2026-08-03), so the field
       existing does not mean reps fill it in.

  Read-only throughout - no CRM writes. The full lead scan reconciles against an absolute
  floor before any tally is trusted, per CLAUDE.md's enumerate-don't-guess corollary. Do
  not run alongside another live-API script - shared account-wide rate limit.

.NOTES
  pwsh ./scripts/leadsquared/migration/19-rep-activity-audit.ps1
#>

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "rep_activity_audit_log.txt"
$jsonPath = Join-Path $dataDir "rep_activity_audit_$stamp.json"
$summaryPath = Join-Path $dataDir "rep_activity_audit_summary_$stamp.md"

Write-LsqLog "=== Rep activity + lead distribution audit (READ-ONLY) ===" $logPath

# Active reps reference. Expand-LsqRows is required even for this local JSON array read,
# not just API responses - see CLAUDE.md eleventh gotcha (2026-07-31): once common.ps1 and
# 00-schema.ps1 are dot-sourced, plain ConvertFrom-Json on this file returns a 1-element
# array wrapping the real 18-element array in this process.
$activeRepPath = Join-Path $dataDir "active_rep_ids_temp.json"
if (-not (Test-Path $activeRepPath)) { throw "Missing $activeRepPath" }
$activeReps = @(Expand-LsqRows (Get-Content $activeRepPath -Raw | ConvertFrom-Json))
if ($activeReps.Count -lt 15) { throw "Only $($activeReps.Count) active reps loaded - refusing to sample activity by rep from suspect reference data." }
Write-LsqLog "Active reps loaded: $($activeReps.Count)" $logPath

# -----------------------------------------------------------------------------------------
# PASS A - Leads (one full paginated scan)
# -----------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- PASS A: leads ---" $logPath

# 89,852 confirmed live 2026-07-31 (data/full_account_audit_20260731-152509.json). Floor
# kept below that to tolerate ordinary lead creation since then, not to paper over a
# truncated scan.
$MinExpectedLeads = 88000

$leadCols = "ProspectID,ProspectStage,mx_Call_Disposition,Source,mx_Disqualification_Reason,OwnerId,OwnerIdName"

$leads = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv $leadCols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$leads.Add($l) }
    if ($page % 20 -eq 0) { Write-LsqLog "  leads scanned: $($leads.Count)..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Total leads scanned: $($leads.Count)" $logPath
if ($leads.Count -lt $MinExpectedLeads) { throw "Only $($leads.Count) leads enumerated (floor $MinExpectedLeads) - refusing to audit from an incomplete scan." }

function Get-Tally {
    param([System.Collections.Generic.List[object]]$Items, [string]$Field)
    $t = @{}
    foreach ($it in $Items) {
        $v = "$($it.$Field)"
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        if ($t.ContainsKey($v)) { $t[$v]++ } else { $t[$v] = 1 }
    }
    return $t
}
function Write-Tally {
    param([string]$Title, [hashtable]$T, [int]$Total, [string]$LogPath, [int]$TopN = 0)
    $counted = 0
    foreach ($k in $T.Keys) { $counted += $T[$k] }
    Write-LsqLog "" $LogPath
    Write-LsqLog "=== $Title ===" $LogPath
    Write-LsqLog ("   (set: {0}   blank/unset: {1})" -f $counted, ($Total - $counted)) $LogPath
    $keys = $T.Keys | Sort-Object { -$T[$_] }
    if ($TopN -gt 0) { $keys = $keys | Select-Object -First $TopN }
    foreach ($k in $keys) { Write-LsqLog ("   {0,-42} {1,-8}" -f $k, $T[$k]) $LogPath }
}

$stageT      = Get-Tally $leads "ProspectStage"
$dispT       = Get-Tally $leads "mx_Call_Disposition"
$sourceT     = Get-Tally $leads "Source"
$reasonT     = Get-Tally $leads "mx_Disqualification_Reason"
$ownerTotalT = Get-Tally $leads "OwnerId"

Write-Tally "CONTACT STAGE"           $stageT  $leads.Count $logPath
Write-Tally "CALL DISPOSITION"        $dispT   $leads.Count $logPath
Write-Tally "SOURCE (top 25 of $($sourceT.Count) distinct values)" $sourceT $leads.Count $logPath 25
Write-Tally "DISQUALIFICATION REASON" $reasonT $leads.Count $logPath

# -----------------------------------------------------------------------------------------
# PASS B - Rep activity sampling
# -----------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- PASS B: rep activity sampling ---" $logPath

$SamplePerRep = 25

# "Worked" pool per active rep: their owned leads that currently carry a Call Disposition.
$leadsByOwner = @{}
foreach ($l in $leads) {
    if ([string]::IsNullOrWhiteSpace("$($l.mx_Call_Disposition)")) { continue }
    $oid = "$($l.OwnerId)"
    if (-not $leadsByOwner.ContainsKey($oid)) { $leadsByOwner[$oid] = New-Object System.Collections.Generic.List[object] }
    [void]$leadsByOwner[$oid].Add($l)
}

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# Global event-type tally across the whole sample - the actual composition of the "activity trail".
$eventTally = @{}
$repResults = New-Object System.Collections.Generic.List[object]
$totalSampled = 0
$totalActivityCalls = 0

foreach ($rep in $activeReps) {
    $ownerId = $rep.OwnerId
    $totalOwned = 0
    if ($ownerTotalT.ContainsKey($ownerId)) { $totalOwned = $ownerTotalT[$ownerId] }
    $pool = @()
    if ($leadsByOwner.ContainsKey($ownerId)) { $pool = $leadsByOwner[$ownerId].ToArray() }
    if ($pool.Count -eq 0) {
        Write-LsqLog "  $($rep.Name): no leads with a disposition set (owns $totalOwned total) - skipping" $logPath
        continue
    }
    $n = [Math]::Min($SamplePerRep, $pool.Count)
    $sample = @($pool | Get-Random -Count $n)

    $has203 = 0; $mostRecentIs203 = 0; $totalActivities = 0; $count203 = 0; $statusFilled203 = 0
    $callkaroCount = 0
    foreach ($l in $sample) {
        $url = "$base/ProspectActivity.svc/Retrieve?accessKey=$ak&secretKey=$sk&leadId=$($l.ProspectID)"
        try {
            $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
            $totalActivityCalls++
            $acts = @($r.ProspectActivities)
            $totalActivities += $acts.Count
            if ($acts.Count -gt 0) {
                foreach ($a in $acts) {
                    $ec = "$($a.EventCode)"
                    $key = "$ec - $($a.EventName)"
                    if ($eventTally.ContainsKey($key)) { $eventTally[$key]++ } else { $eventTally[$key] = 1 }
                    if ($ec -eq "203") {
                        $count203++
                        if ($a.ActivityFields -and -not [string]::IsNullOrWhiteSpace("$($a.ActivityFields.Status)")) { $statusFilled203++ }
                    }
                    if ($ec -eq "208") { $callkaroCount++ }
                }
                $anyHas203 = @($acts | Where-Object { "$($_.EventCode)" -eq "203" }).Count -gt 0
                if ($anyHas203) { $has203++ }
                $sorted = $acts | Sort-Object { [datetime]$_.CreatedOn } -Descending
                if ("$($sorted[0].EventCode)" -eq "203") { $mostRecentIs203++ }
            }
        } catch {
            Write-LsqLog "  activity fetch failed for lead $($l.ProspectID) (rep $($rep.Name)) -> $($_.Exception.Message)" $logPath
        }
        Start-Sleep -Milliseconds 300
    }
    $totalSampled += $sample.Count
    $pctAny203 = if ($sample.Count -gt 0) { [Math]::Round(100.0 * $has203 / $sample.Count, 0) } else { 0 }
    $pctMostRecent203 = if ($sample.Count -gt 0) { [Math]::Round(100.0 * $mostRecentIs203 / $sample.Count, 0) } else { 0 }
    $avgActs = if ($sample.Count -gt 0) { [Math]::Round($totalActivities / $sample.Count, 1) } else { 0 }
    $statusPct = if ($count203 -gt 0) { [Math]::Round(100.0 * $statusFilled203 / $count203, 0) } else { $null }
    [void]$repResults.Add([pscustomobject]@{
        Rep = $rep.Name
        OwnerId = $ownerId
        TotalOwned = $totalOwned
        WorkedPoolSize = $pool.Count
        Sampled = $sample.Count
        AvgActivitiesPerLead = $avgActs
        PctWithAny203 = $pctAny203
        PctMostRecentIs203 = $pctMostRecent203
        Count203Total = $count203
        Status203FilledPct = $statusPct
        CallkaroActivities = $callkaroCount
    })
    Write-LsqLog ("  {0,-20} owned={1,-6} worked-pool={2,-6} sampled={3,-4} any203={4,3}%  mostRecent203={5,3}%  avgActs/lead={6}" -f $rep.Name, $totalOwned, $pool.Count, $sample.Count, $pctAny203, $pctMostRecent203, $avgActs) $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "=== ACTIVITY EVENT-TYPE COMPOSITION (across $totalSampled sampled leads, $totalActivityCalls activity calls) ===" $logPath
foreach ($k in ($eventTally.Keys | Sort-Object { -$eventTally[$_] })) { Write-LsqLog ("   {0,-45} {1}" -f $k, $eventTally[$k]) $logPath }

$overallHas203 = 0; $overallMostRecent203 = 0
if ($repResults.Count -gt 0) {
    $overallHas203 = ($repResults | Measure-Object -Property PctWithAny203 -Average).Average
    $overallMostRecent203 = ($repResults | Measure-Object -Property PctMostRecentIs203 -Average).Average
}
Write-LsqLog "" $logPath
Write-LsqLog ("OVERALL (rep-averaged, unweighted): {0}% of worked leads have ANY 01. Phone Call/ Follow Up activity ever logged; {1}% have that as their MOST RECENT activity" -f [Math]::Round($overallHas203, 0), [Math]::Round($overallMostRecent203, 0)) $logPath

# -----------------------------------------------------------------------------------------
# Output: JSON snapshot + markdown summary
# -----------------------------------------------------------------------------------------
$snapshot = [pscustomobject]@{
    RunAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Leads = [pscustomobject]@{
        Total = $leads.Count
        ContactStage = $stageT
        CallDisposition = $dispT
        Source = $sourceT
        DisqualificationReason = $reasonT
    }
    ActivitySampling = [pscustomobject]@{
        SamplePerRep = $SamplePerRep
        TotalSampled = $totalSampled
        TotalActivityCalls = $totalActivityCalls
        EventTypeComposition = $eventTally
        OverallPctAny203 = [Math]::Round($overallHas203, 0)
        OverallPctMostRecent203 = [Math]::Round($overallMostRecent203, 0)
        ByRep = $repResults.ToArray()
    }
}
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath
Write-LsqLog "" $logPath
Write-LsqLog "JSON snapshot written: $jsonPath" $logPath

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# Rep activity + lead distribution audit - $stamp")
[void]$md.Add("")
[void]$md.Add("Leads scanned: $($leads.Count)   Reps sampled: $($repResults.Count)   Leads sampled: $totalSampled")
[void]$md.Add("")
[void]$md.Add("## Contact Stage")
[void]$md.Add("")
[void]$md.Add("| Value | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($stageT.Keys | Sort-Object { -$stageT[$_] })) { [void]$md.Add("| $k | $($stageT[$k]) |") }
[void]$md.Add("")
[void]$md.Add("## Call Disposition")
[void]$md.Add("")
[void]$md.Add("| Value | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($dispT.Keys | Sort-Object { -$dispT[$_] })) { [void]$md.Add("| $k | $($dispT[$k]) |") }
[void]$md.Add("")
[void]$md.Add("## Disqualification Reason")
[void]$md.Add("")
[void]$md.Add("| Value | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($reasonT.Keys | Sort-Object { -$reasonT[$_] })) { [void]$md.Add("| $k | $($reasonT[$k]) |") }
[void]$md.Add("")
[void]$md.Add("## Source (top 25 of $($sourceT.Count) distinct values)")
[void]$md.Add("")
[void]$md.Add("| Value | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($sourceT.Keys | Sort-Object { -$sourceT[$_] } | Select-Object -First 25)) { [void]$md.Add("| $k | $($sourceT[$k]) |") }
[void]$md.Add("")
[void]$md.Add("## Activity event-type composition (across the sample)")
[void]$md.Add("")
[void]$md.Add("| EventCode - EventName | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($eventTally.Keys | Sort-Object { -$eventTally[$_] })) { [void]$md.Add("| $k | $($eventTally[$k]) |") }
[void]$md.Add("")
[void]$md.Add("## Rep activity logging, by rep")
[void]$md.Add("")
[void]$md.Add("| Rep | Owned | Worked pool | Sampled | Avg activities/lead | Any 203 ever | Most recent is 203 | 203 count | Status filled on 203 |")
[void]$md.Add("|---|---|---|---|---|---|---|---|---|")
foreach ($r in ($repResults | Sort-Object -Property PctMostRecentIs203)) {
    $statusStr = if ($null -eq $r.Status203FilledPct) { "n/a" } else { "$($r.Status203FilledPct)%" }
    [void]$md.Add("| $($r.Rep) | $($r.TotalOwned) | $($r.WorkedPoolSize) | $($r.Sampled) | $($r.AvgActivitiesPerLead) | $($r.PctWithAny203)% | $($r.PctMostRecentIs203)% | $($r.Count203Total) | $statusStr |")
}
[void]$md.Add("")
[void]$md.Add("**Overall: $([Math]::Round($overallHas203,0))% of worked leads have ANY 01. Phone Call/ Follow Up activity ever logged; $([Math]::Round($overallMostRecent203,0))% have that as their MOST RECENT activity** (rep-averaged, unweighted).")
$md | Set-Content -Path $summaryPath
Write-LsqLog "Markdown summary written: $summaryPath" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "=== Audit complete ===" $logPath
