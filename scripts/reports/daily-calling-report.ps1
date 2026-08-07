<#
.SYNOPSIS
  READ-ONLY: Daily Calling Report per rep - total dials, connects, contacts moved to
  Prospect, and Opportunities moved to In Discussion, for one calendar day (IST), split
  by Cold Call sources vs FB Leads, with Call me Later / Follow Up disposition counts.

.DESCRIPTION
  Four different signals, pulled from three different places, because no single LSQ object
  carries them all:

    Total Calls / Total Connected
      Native telephony log, EventCode 22 "Outbound Phone Call Activity" - auto-created
      whenever a call is placed through the system, so it cannot be gamed by a rep not
      filling in a form. Attributed to ActivityFields.CreatedBy (who dialled), NOT to the
      lead owner. Duration is ActivityFields.mx_Custom_3 in seconds (confirmed live
      2026-08-03 against 116 real calls). "Connected" is reported BOTH ways - duration > 0
      and Status = "Answered" - because they do not always agree.

    Total Prospects
      EventCode 3002 "StageChange" activities whose Data.CurrentStage = "Prospect" and whose
      CreatedOn falls inside the target day. Verified live 2026-08-04: a 3002 carries
      PreviousStage / CurrentStage / CreatedBy (a display NAME, not a GUID) in its Data
      array. This counts the ACT of marking a contact Prospect today, which is what was
      asked for - not the standing count of contacts sitting at Prospect.

    Total In Discussion
      EventCode 12000 "Opportunity" activities where ActivityFields.mx_Custom_2 (the
      Opportunity Stage - see 06-create-opportunities.ps1) = "In Discussion" and the
      activity's ModifiedOn falls inside the target day. CAVEAT: ModifiedOn moves on ANY
      opportunity edit, not only a stage change, so this is "opportunities sitting at In
      Discussion that were touched today". LSQ emits no per-field opportunity change event
      that would allow a tighter reading.

    Call me Later / Follow Up
      Lead field mx_Call_Disposition, current value, for leads modified today. Also a
      standing-value-plus-touched-today reading rather than a change event, for the same
      reason. Attributed to the lead OWNER (there is no per-change actor recorded).

  Source bucketing uses the lead's Source field. Cold Call and FB sets are parameters, and
  their exact stored spellings were enumerated live 2026-08-04 rather than guessed - e.g.
  the disposition is stored "Call me Later" (lowercase m), and both "FB Lead Ads" and
  "Fb leads ad" exist as separate values. The FB Leads figure is reported BOTH ways the
  request allowed: as (Total - Cold Call) and as a direct Source filter. Where they
  disagree, the gap is leads on neither set of sources (Website, Inbound, LinkedIn, ...),
  which is a source-hygiene finding rather than an error.

  Candidate set is the UNION of two filters, deduped by ProspectID:
    ProspectActivityDate_Max >= day start   (caught the calls)
    ModifiedOn               >= day start   (catches stage/disposition edits, which do not
                                             always move the activity date)
  Measured live 2026-08-04: activity-date alone found 2,511 leads, ModifiedOn added 3,576
  more. Using either filter alone would have undercounted badly.

  Both scans page sorted by CreatedOn, which is IMMUTABLE. Paging sorted by ModifiedOn was
  measured returning 336 duplicate rows in a single scan (2026-08-04) because rows shift
  between pages while records are being edited underneath the scan - duplicates are visible
  and dedupable, but the same drift silently DROPS rows, which is not.

  Timestamps are UTC in storage while the account is IST (CLAUDE.md gotcha #5) - the day
  window is computed from local midnight converted to UTC, never by string-matching a date.

  Read-only throughout - no CRM writes. Do not run alongside another live-API script; the
  rate limit (20 calls / 5 sec) is account-wide.

.PARAMETER TargetDate
  Calendar day (local/IST) to report on, "yyyy-MM-dd". Defaults to today.

.PARAMETER Reps
  Display names (LSQ OwnerIdName) to report on. Names are resolved against live data; an
  unresolvable name is a hard error, because a rep silently reporting zero is exactly the
  failure this report exists to detect.

.PARAMETER AllOwners
  Pull activity for every candidate lead regardless of owner. Default (off) pulls only
  leads owned by the requested reps, which is ~3x faster. With it off, a call placed by a
  listed rep on a lead owned by someone NOT listed is not counted; the log reports how many
  leads were skipped so the trade-off is visible.

.NOTES
  pwsh ./scripts/leadsquared/migration/24-daily-calling-report.ps1
  pwsh ./scripts/leadsquared/migration/24-daily-calling-report.ps1 -TargetDate "2026-08-03" -AllOwners
#>

param(
    [string]$TargetDate = "",
    [string[]]$Reps = @(
        "Twinkle Sutrakar", "Mayank Arora", "Rahul Madaan", "Nikhil Sharma",
        "adarsh pandey", "Neha Advani", "Subham Tak", "Prakhar Gupta",
        "Abhishek Tripathi", "Arjun Rathi", "Ashutosh Ojha", "Rishi Saraswat",
        "Saurabh Sharma", "Vikhyat Verma", "Kartikey Mishra", "Akshita Sharma"
    ),
    [string[]]$ColdCallSources = @("QA_AGENT", "QA AGENT_FUNDING", "FB_Lead_QA_Agent_Team", "AGENT", "SHEET"),
    [string[]]$FbSources       = @("FB Lead Ads", "Fb leads ad"),
    [string[]]$Dispositions    = @("Call me Later", "Follow Up"),
    [string]$ProspectStageName = "Prospect",
    [string]$InDiscussionStage = "In Discussion",
    # Contact stages whose leads can own an Opportunity. Swept in full for the opportunity
    # pass, because opportunity edits do not touch the lead's timestamps (see below).
    [string[]]$OpportunityStages = @("Prospect", "Customer"),
    [switch]$AllOwners
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath     = Join-Path $dataDir "daily_calling_report_log.txt"
$jsonPath    = Join-Path $dataDir "daily_calling_report_$stamp.json"
$summaryPath = Join-Path $dataDir "daily_calling_report_$stamp.md"

# ---------------------------------------------------------------------------------------
# Day window. Local machine is IST (confirmed 2026-08-03); storage is UTC.
# ---------------------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TargetDate)) {
    $dayStart = (Get-Date).Date
} else {
    $dayStart = [datetime]::ParseExact($TargetDate, "yyyy-MM-dd", $null)
}
$dayEnd = $dayStart.AddDays(1)
$dayStartUtc = $dayStart.ToUniversalTime()
$dayEndUtc   = $dayEnd.ToUniversalTime()
$floorStr    = Get-LsqTimestamp -LocalTime $dayStart

Write-LsqLog "=== DAILY CALLING REPORT - $($dayStart.ToString('yyyy-MM-dd dddd')) (READ-ONLY) ===" $logPath
Write-LsqLog "Day window (UTC): $($dayStartUtc.ToString('yyyy-MM-dd HH:mm:ss')) to $($dayEndUtc.ToString('yyyy-MM-dd HH:mm:ss'))" $logPath
Write-LsqLog "Reps requested: $($Reps.Count)" $logPath
Write-LsqLog "Cold Call sources: $($ColdCallSources -join ' | ')" $logPath
Write-LsqLog "FB sources:        $($FbSources -join ' | ')" $logPath

# ---------------------------------------------------------------------------------------
# Negative controls. A filter that returns zero must be distrusted as much as one that
# returns a suspicious non-zero (CLAUDE.md) - so prove each filter actually filters first.
# ---------------------------------------------------------------------------------------
foreach ($f in @("ProspectActivityDate_Max", "ModifiedOn")) {
    $neg = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = $f; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID" -SortColumn "CreatedOn" -SortDirection "1" -PageIndex 1 -PageSize 10))
    if ($neg.Count -ne 0) { throw "Negative control FAILED: $f > 2099-01-01 returned $($neg.Count) rows, expected 0. The filter is not filtering - aborting." }
}
Write-LsqLog "Negative controls passed (0 rows for a future-dated floor on both filters)." $logPath

# ---------------------------------------------------------------------------------------
# Candidate leads: union of "had activity today" and "was edited today".
# Sorted by CreatedOn (immutable) - see the header note on ModifiedOn paging drift.
# ---------------------------------------------------------------------------------------
$leadCols = "ProspectID,Source,OwnerId,OwnerIdName,ProspectStage,mx_Call_Disposition,ModifiedOn,ProspectActivityDate_Max"

function Get-LeadsSince {
    param([string]$LookupName, [string]$Floor, [string]$Cols, [string]$LogPath)
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

$byActivity = Get-LeadsSince "ProspectActivityDate_Max" $floorStr $leadCols $logPath
$byModified = Get-LeadsSince "ModifiedOn" $floorStr $leadCols $logPath
Write-LsqLog "Leads with activity since day start: $($byActivity.Count)" $logPath
Write-LsqLog "Leads modified since day start:      $($byModified.Count)" $logPath

$candidateMap = @{}
foreach ($l in $byActivity) { $candidateMap["$($l.ProspectID)"] = $l }
$addedByModified = 0
foreach ($l in $byModified) {
    $k = "$($l.ProspectID)"
    if (-not $candidateMap.ContainsKey($k)) { $candidateMap[$k] = $l; $addedByModified++ }
}
$candidates = @($candidateMap.Values)
Write-LsqLog "UNION candidate set: $($candidates.Count) leads (+$addedByModified that the activity-date filter alone would have missed)" $logPath
if ($candidates.Count -eq 0) { throw "0 candidate leads for $($dayStart.ToString('yyyy-MM-dd')) - refusing to report an empty day as a real finding without investigating the filter." }
if ($candidates.Count -lt 200) { Write-LsqLog "*** WARNING: only $($candidates.Count) candidates - unusually small for a working day. Verify before circulating. ***" $logPath }

# ---------------------------------------------------------------------------------------
# Owner map, built from LIVE data (OwnerId <-> OwnerIdName pairs seen in the scan) and
# cross-checked against the stored roster. The roster file is stale - it has 18 reps and
# does not contain Akshita Sharma - so live data is the authority, not the file.
# ---------------------------------------------------------------------------------------
$idByName = @{}
$nameById = @{}
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
Write-LsqLog "Owner identities resolved: $($idByName.Count)" $logPath

# Resolve each requested rep name. Exact (case-insensitive) first, then a first-name match
# as a fallback that is ALWAYS logged - "Akshita Garg" was requested but the account holds
# "Akshita Sharma", and a silent zero row for a rep is the exact failure this report exists
# to catch, so an unresolvable name is fatal rather than skipped.
$resolved = New-Object System.Collections.Generic.List[object]
foreach ($want in $Reps) {
    $hit = $idByName.Keys | Where-Object { $_ -ieq $want } | Select-Object -First 1
    if (-not $hit) {
        $first = ($want -split '\s+')[0]
        $cands = @($idByName.Keys | Where-Object { $_ -imatch "^$([regex]::Escape($first))\b" })
        if ($cands.Count -eq 1) {
            $hit = $cands[0]
            Write-LsqLog "*** NAME MISMATCH: requested [$want] does not exist in LSQ; matched on first name to [$hit]. Confirm this is the same person. ***" $logPath
        } elseif ($cands.Count -gt 1) {
            throw "Requested rep [$want] is ambiguous - first-name matches: $($cands -join ', '). Pass the exact OwnerIdName."
        } else {
            throw "Requested rep [$want] could not be resolved to any LSQ owner. Refusing to report a silent zero for a named rep."
        }
    }
    [void]$resolved.Add([pscustomobject]@{ Requested = $want; OwnerIdName = $hit; OwnerId = $idByName[$hit] })
}
$repIds = @{}
foreach ($r in $resolved) { $repIds[$r.OwnerId] = $r.OwnerIdName }
Write-LsqLog "Reps resolved: $($resolved.Count)" $logPath

# ---------------------------------------------------------------------------------------
# Scope the (expensive) per-lead activity pull. One API call per lead - there is no bulk
# Activity read endpoint (AUTOMATION_CAPABILITIES.md).
# ---------------------------------------------------------------------------------------
if ($AllOwners) {
    $callScope = $candidates
    Write-LsqLog "Call scope: ALL owners - $($callScope.Count) leads." $logPath
} else {
    $callScope = @($candidates | Where-Object { $repIds.ContainsKey("$($_.OwnerId)") })
    $skipped = $candidates.Count - $callScope.Count
    Write-LsqLog "Call scope: requested reps only - $($callScope.Count) leads ($skipped candidate leads owned by others SKIPPED; a listed rep's call on one of those is NOT counted. Re-run with -AllOwners to include them)." $logPath
}
if ($callScope.Count -eq 0) { throw "0 leads in call scope - aborting rather than reporting zeros." }

# ---------------------------------------------------------------------------------------
# Opportunity scope - a SEPARATE sweep, deliberately NOT watermarked off the Lead.
#
# Proven live 2026-08-04: editing an Opportunity does NOT move the parent Lead's ModifiedOn
# or ProspectActivityDate_Max. Of 21 opportunities modified that day, 3 belonged to leads
# that neither lead-level filter surfaced - including the ONLY one at "In Discussion", whose
# lead read ModifiedOn 2026-07-30 / activity 2026-08-03. The first version of this report
# derived opportunities from the candidate set and therefore reported "In Discussion = 0"
# for every rep, which looked like an unused pipeline stage rather than a bug.
#
# So opportunities are swept over every lead at a deal-bearing CONTACT stage instead. That
# set is bounded (1,164 live on 2026-08-04) and does not depend on any timestamp.
# ---------------------------------------------------------------------------------------
$oppScope = New-Object System.Collections.Generic.List[object]
foreach ($stage in $OpportunityStages) {
    $page = 1
    while ($true) {
        $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
            -Filter @{ LookupName = "ProspectStage"; LookupValue = $stage; SqlOperator = "=" } `
            -ColumnsCsv $leadCols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
        if ($resp.Count -eq 0) { break }
        foreach ($r in $resp) { [void]$oppScope.Add($r) }
        if ($resp.Count -lt 1000) { break }
        $page++
        Start-Sleep -Milliseconds 250
    }
}
$oppLeads = $oppScope.ToArray()
if (-not $AllOwners) { $oppLeads = @($oppLeads | Where-Object { $repIds.ContainsKey("$($_.OwnerId)") }) }
Write-LsqLog "Opportunity scope: $($oppLeads.Count) leads at contact stage [$($OpportunityStages -join ', ')] (swept independently of any timestamp)." $logPath
if ($oppLeads.Count -eq 0) { throw "0 leads at a deal-bearing contact stage - refusing to report In Discussion = 0 off an empty sweep." }

# One API call per unique lead across BOTH scopes - the two overlap, and the per-lead
# activity pull is the expensive part (no bulk Activity read endpoint exists).
$scopeById = @{}
foreach ($l in $callScope) { $scopeById["$($l.ProspectID)"] = [pscustomobject]@{ Lead = $l; Calls = $true;  Opps = $false } }
foreach ($l in $oppLeads) {
    $k = "$($l.ProspectID)"
    if ($scopeById.ContainsKey($k)) { $scopeById[$k].Opps = $true }
    else { $scopeById[$k] = [pscustomobject]@{ Lead = $l; Calls = $false; Opps = $true } }
}
$toPull = @($scopeById.Values)
Write-LsqLog "Unique leads to pull activity for: $($toPull.Count) (call scope $($callScope.Count) + opportunity scope $($oppLeads.Count), deduped)." $logPath

function Get-DataValue {
    param($Activity, [string]$Key)
    foreach ($d in @($Activity.Data)) { if ("$($d.Key)" -eq $Key) { return "$($d.Value)" } }
    return ""
}
function Get-SourceBucket {
    param([string]$Source, [string[]]$Cold, [string[]]$Fb)
    if ($Cold -contains $Source) { return "Cold" }
    if ($Fb   -contains $Source) { return "FB" }
    return "Other"
}

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# Per-lead facts for the target day. Kept flat so every aggregate below is derived from one
# pass of raw rows rather than from another aggregate.
$perLead = New-Object System.Collections.Generic.List[object]
$oppStageTally = @{}     # every Opportunity Stage seen, all time
$oppTouchedToday = @{}   # ... restricted to opportunities modified inside the target day
$oppActorResolved = 0    # opportunities whose ModifiedBy maps to a known rep
$oppActorUnresolved = 0  # ... and those whose does not (why attribution uses the owner)
$ok = 0; $failed = 0; $done = 0
foreach ($entry in $toPull) {
    $c = $entry.Lead
    $bucket = Get-SourceBucket "$($c.Source)" $ColdCallSources $FbSources
    $url = "$base/ProspectActivity.svc/Retrieve?accessKey=$ak&secretKey=$sk&leadId=$($c.ProspectID)"
    try {
        $r = Invoke-LsqWithRetry -What "activity $($c.ProspectID)" -Action {
            Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -ErrorAction Stop
        }
        $ok++
        $acts = @($r.ProspectActivities)

        # --- Calls (EventCode 22), attributed to whoever dialled ---
        foreach ($a in $acts) {
            if (-not $entry.Calls) { break }
            if ("$($a.EventCode)" -ne "22") { continue }
            $when = [datetime]$a.CreatedOn
            if ($when -lt $dayStartUtc -or $when -ge $dayEndUtc) { continue }
            $dur = 0
            [void][int]::TryParse("$($a.ActivityFields.mx_Custom_3)", [ref]$dur)
            [void]$perLead.Add([pscustomobject]@{
                Kind = "Call"; ProspectId = "$($c.ProspectID)"; Bucket = $bucket; Source = "$($c.Source)"
                ActorId = "$($a.ActivityFields.CreatedBy)"; ActorName = ""
                Connected = ($dur -gt 0); Answered = ("$($a.ActivityFields.Status)" -eq "Answered")
                DurationSec = $dur
            })
        }

        # --- Contact stage marked Prospect today (EventCode 3002), actor is a NAME ---
        foreach ($a in $acts) {
            if (-not $entry.Calls) { break }
            if ("$($a.EventCode)" -ne "3002") { continue }
            $when = [datetime]$a.CreatedOn
            if ($when -lt $dayStartUtc -or $when -ge $dayEndUtc) { continue }
            if ((Get-DataValue $a "CurrentStage") -ne $ProspectStageName) { continue }
            [void]$perLead.Add([pscustomobject]@{
                Kind = "Prospect"; ProspectId = "$($c.ProspectID)"; Bucket = $bucket; Source = "$($c.Source)"
                ActorId = ""; ActorName = (Get-DataValue $a "CreatedBy")
                Connected = $false; Answered = $false; DurationSec = 0
            })
        }

        # --- Opportunity sitting at In Discussion, touched today (EventCode 12000) ---
        foreach ($a in $acts) {
            if (-not $entry.Opps) { break }
            if ("$($a.EventCode)" -ne "12000") { continue }

            # Tally EVERY opportunity stage seen, not just the one being reported. A stage
            # reading zero is only trustworthy against the backdrop of what the other stages
            # hold - reporting "In Discussion = 0" with no idea whether ANY opportunity was
            # found is how the first version of this script shipped a bug as a finding.
            $seenStage = "$($a.ActivityFields.mx_Custom_2)"
            if ([string]::IsNullOrWhiteSpace($seenStage)) { $seenStage = "<BLANK>" }
            if ($oppStageTally.ContainsKey($seenStage)) { $oppStageTally[$seenStage]++ } else { $oppStageTally[$seenStage] = 1 }

            # [ref] target must already BE a [datetime] - TryParse against a $null-initialised
            # variable throws a conversion error rather than returning $false.
            $mod = [datetime]::MinValue
            if (-not [datetime]::TryParse("$($a.ModifiedOn)", [ref]$mod)) { continue }
            if ($mod -lt $dayStartUtc -or $mod -ge $dayEndUtc) { continue }
            if ($oppTouchedToday.ContainsKey($seenStage)) { $oppTouchedToday[$seenStage]++ } else { $oppTouchedToday[$seenStage] = 1 }

            # Track how often the opportunity's own ModifiedBy resolves to a known rep. It
            # usually does NOT - see the attribution note below - and a silent failure here
            # is invisible in every other output.
            $modBy = "$($a.ActivityFields.ModifiedBy)"
            if ($nameById.ContainsKey($modBy)) { $oppActorResolved++ } else { $oppActorUnresolved++ }

            if ($seenStage -ne $InDiscussionStage) { continue }

            # Attributed to the CONTACT OWNER, not to ActivityFields.ModifiedBy. Proven live
            # 2026-08-04: ModifiedBy is routinely a GUID belonging to no rep at all (an
            # integration/system account, e.g. b5c423e0-096f-11ef-8d08-0261eba56ddf on a lead
            # owned by Rahul Madaan). Those rows resolved to "<unknown:GUID>", matched no rep,
            # and were silently dropped - which reproduced "In Discussion = 0" even after the
            # detection bug was fixed. Ownership is also the better answer to the question
            # actually asked ("how many of THIS REP's contacts have an opportunity at this
            # stage"), which is about the rep's book rather than about who last clicked save.
            [void]$perLead.Add([pscustomobject]@{
                Kind = "InDiscussion"; ProspectId = "$($c.ProspectID)"; Bucket = $bucket; Source = "$($c.Source)"
                ActorId = "$($c.OwnerId)"; ActorName = ""
                Connected = $false; Answered = $false; DurationSec = 0
            })
        }
    } catch {
        $failed++
        Write-LsqLog "  activity fetch failed for lead $($c.ProspectID) -> $($_.Exception.Message)" $logPath
    }
    $done++
    if ($done % 250 -eq 0) { Write-LsqLog "  activity pulled: $done/$($toPull.Count)  (rows so far: $($perLead.Count))" $logPath }
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Activity pull complete: $ok ok, $failed failed, of $($toPull.Count)." $logPath
if ($failed -gt ($toPull.Count * 0.02)) {
    Write-LsqLog "*** WARNING: $failed activity fetches failed (>2%) - every call/prospect/opportunity number below is an UNDERCOUNT. ***" $logPath
}

# Opportunity backdrop. Printed BEFORE the per-rep tables so that an "In Discussion = 0" row
# is always read against how many opportunities were actually found and what stages exist.
$oppTotal = 0
foreach ($k in $oppStageTally.Keys) { $oppTotal += $oppStageTally[$k] }
Write-LsqLog "" $logPath
Write-LsqLog "=== OPPORTUNITY STAGE BACKDROP ($oppTotal opportunities across $($oppLeads.Count) deal-stage leads) ===" $logPath
foreach ($k in ($oppStageTally.Keys | Sort-Object { -$oppStageTally[$_] })) {
    $t = 0
    if ($oppTouchedToday.ContainsKey($k)) { $t = $oppTouchedToday[$k] }
    Write-LsqLog ("   {0,-28} {1,6} total   {2,4} modified today" -f $k, $oppStageTally[$k], $t) $logPath
}
if ($oppTotal -eq 0) { throw "0 opportunities found across $($oppLeads.Count) deal-stage leads - that cannot be right; refusing to report opportunity metrics." }
Write-LsqLog ("Opportunity ModifiedBy resolves to a known rep: {0} of {1} ({2} unresolved - this is why opportunities are attributed to the CONTACT OWNER, not to ModifiedBy)." -f `
    $oppActorResolved, ($oppActorResolved + $oppActorUnresolved), $oppActorUnresolved) $logPath
# Legacy Opportunity stages were cleared by migration step 06b (PROJECT_PLAN Phase 5R). Any
# that reappear mean reps are still writing retired values, which no write log would reveal.
$knownStages = @($InDiscussionStage, "Prospect", "Agreement Sent", "Invoice Sent", "Payment Received", "Customer", "Closed - Lost")
$legacy = @($oppStageTally.Keys | Where-Object { $knownStages -notcontains $_ })
if ($legacy.Count -gt 0) {
    Write-LsqLog "*** WARNING: $($legacy.Count) NON-CANONICAL Opportunity Stage value(s) in live data: $($legacy -join ', '). Step 06b cleared these - they are being re-introduced. ***" $logPath
}

# Resolve call/opportunity actor GUIDs to names; stage-change actors are already names.
$rows = New-Object System.Collections.Generic.List[object]
foreach ($e in $perLead) {
    $name = $e.ActorName
    if ([string]::IsNullOrWhiteSpace($name)) {
        if ($nameById.ContainsKey($e.ActorId)) { $name = $nameById[$e.ActorId] } else { $name = "<unknown:$($e.ActorId)>" }
    }
    [void]$rows.Add([pscustomobject]@{
        Kind = $e.Kind; Rep = $name; Bucket = $e.Bucket; ProspectId = $e.ProspectId
        Connected = $e.Connected; Answered = $e.Answered; DurationSec = $e.DurationSec
    })
}
$allRows = $rows.ToArray()

# ---------------------------------------------------------------------------------------
# Dispositions - a lead FIELD, not an event. Counted over leads edited today, by owner.
# ---------------------------------------------------------------------------------------
$dispLeads = @($candidates | Where-Object {
    $m = [datetime]::MinValue
    ([datetime]::TryParse("$($_.ModifiedOn)", [ref]$m)) -and $m -ge $dayStartUtc -and $m -lt $dayEndUtc -and
    ($Dispositions -contains "$($_.mx_Call_Disposition)")
})
Write-LsqLog "Leads edited today carrying a reported disposition: $($dispLeads.Count)" $logPath

# ---------------------------------------------------------------------------------------
# Aggregation. Pure - no logging inside (CLAUDE.md gotcha #11 corollary: a function that
# both logs and returns hands its caller the log lines bundled with the return value).
# ---------------------------------------------------------------------------------------
function Measure-RepSlice {
    param($Rows, $DispLeads, [string]$RepName, [string[]]$Buckets, [string[]]$Dispositions)
    $mine  = @($Rows | Where-Object { $_.Rep -eq $RepName -and $Buckets -contains $_.Bucket })
    $calls = @($mine | Where-Object { $_.Kind -eq "Call" })
    $conn  = @($calls | Where-Object { $_.Connected })
    $ans   = @($calls | Where-Object { $_.Answered })
    $disp  = @($DispLeads | Where-Object { $_.OwnerIdName -eq $RepName -and $Buckets -contains $_.Bucket })
    $talk  = ($calls | Measure-Object -Property DurationSec -Sum).Sum
    if ($null -eq $talk) { $talk = 0 }
    # Precomputed: PowerShell 5.1 will not parse an `if` expression as a value inside a
    # [pscustomobject]@{...} literal.
    $connPct = 0
    if ($calls.Count -gt 0) { $connPct = [Math]::Round(100.0 * $conn.Count / $calls.Count, 1) }
    $out = [ordered]@{
        Rep               = $RepName
        TotalCalls        = $calls.Count
        ContactsDialled   = @($calls | Select-Object -ExpandProperty ProspectId -Unique).Count
        TotalConnected    = $conn.Count
        AnsweredByStatus  = $ans.Count
        ConnectPct        = $connPct
        TalkTimeMin       = [Math]::Round($talk / 60.0, 1)
        TotalProspects    = @($mine | Where-Object { $_.Kind -eq "Prospect" }).Count
        TotalInDiscussion = @($mine | Where-Object { $_.Kind -eq "InDiscussion" }).Count
    }
    foreach ($d in $Dispositions) { $out[$d] = @($disp | Where-Object { "$($_.mx_Call_Disposition)" -eq $d }).Count }
    return [pscustomobject]$out
}

# Tag disposition leads with their bucket so the same slicer works on them.
$dispTagged = New-Object System.Collections.Generic.List[object]
foreach ($l in $dispLeads) {
    [void]$dispTagged.Add([pscustomobject]@{
        OwnerIdName = "$($l.OwnerIdName)"
        mx_Call_Disposition = "$($l.mx_Call_Disposition)"
        Bucket = (Get-SourceBucket "$($l.Source)" $ColdCallSources $FbSources)
    })
}
$dispArr = $dispTagged.ToArray()

$allBuckets  = @("Cold", "FB", "Other")
$coldBucket  = @("Cold")
$fbBucket    = @("FB")

$overall = New-Object System.Collections.Generic.List[object]
$cold    = New-Object System.Collections.Generic.List[object]
$fbDirect= New-Object System.Collections.Generic.List[object]
foreach ($r in $resolved) {
    [void]$overall.Add( (Measure-RepSlice $allRows $dispArr $r.OwnerIdName $allBuckets $Dispositions) )
    [void]$cold.Add(    (Measure-RepSlice $allRows $dispArr $r.OwnerIdName $coldBucket $Dispositions) )
    [void]$fbDirect.Add((Measure-RepSlice $allRows $dispArr $r.OwnerIdName $fbBucket   $Dispositions) )
}
$overallArr  = $overall.ToArray()
$coldArr     = $cold.ToArray()
$fbDirectArr = $fbDirect.ToArray()

function Write-RepTable {
    param($Rows, [string]$Title, [string]$LogPath, [string[]]$Dispositions)
    Write-LsqLog "" $LogPath
    Write-LsqLog "=== $Title ===" $LogPath
    Write-LsqLog ("  {0,-20} {1,6} {2,6} {3,6} {4,7} {5,6} {6,6} {7,7} {8,7}" -f `
        "Rep", "Calls", "Conn", "Conn%", "Dialled", "Prosp", "InDisc", $Dispositions[0], $Dispositions[1]) $LogPath
    foreach ($x in ($Rows | Sort-Object -Property TotalCalls -Descending)) {
        Write-LsqLog ("  {0,-20} {1,6} {2,6} {3,6} {4,7} {5,6} {6,6} {7,7} {8,7}" -f `
            $x.Rep, $x.TotalCalls, $x.TotalConnected, $x.ConnectPct, $x.ContactsDialled, `
            $x.TotalProspects, $x.TotalInDiscussion, $x.($Dispositions[0]), $x.($Dispositions[1])) $LogPath
    }
}

Write-RepTable $overallArr  "DAILY CALLING REPORT - ALL SOURCES"                     $logPath $Dispositions
Write-RepTable $coldArr     "COLD CALL SOURCES ONLY ($($ColdCallSources -join ', '))" $logPath $Dispositions
Write-RepTable $fbDirectArr "FB LEADS - direct Source filter ($($FbSources -join ', '))" $logPath $Dispositions

# FB by subtraction vs FB by direct source. Any gap is leads on neither source set.
Write-LsqLog "" $logPath
Write-LsqLog "=== FB LEADS: subtraction (Total - Cold) vs direct Source filter ===" $logPath
$fbCompare = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $overallArr.Count; $i++) {
    $o = $overallArr[$i]; $c = $coldArr[$i]; $f = $fbDirectArr[$i]
    [void]$fbCompare.Add([pscustomobject]@{
        Rep                 = $o.Rep
        CallsBySubtraction  = $o.TotalCalls - $c.TotalCalls
        CallsBySource       = $f.TotalCalls
        ConnBySubtraction   = $o.TotalConnected - $c.TotalConnected
        ConnBySource        = $f.TotalConnected
        GapCalls            = ($o.TotalCalls - $c.TotalCalls) - $f.TotalCalls
    })
}
$fbCompareArr = $fbCompare.ToArray()
foreach ($x in ($fbCompareArr | Sort-Object -Property CallsBySubtraction -Descending)) {
    Write-LsqLog ("  {0,-20} calls: subtraction={1,5}  source={2,5}  gap={3,5}   connected: subtraction={4,5}  source={5,5}" -f `
        $x.Rep, $x.CallsBySubtraction, $x.CallsBySource, $x.GapCalls, $x.ConnBySubtraction, $x.ConnBySource) $logPath
}
$totalGap = ($fbCompareArr | Measure-Object -Property GapCalls -Sum).Sum
Write-LsqLog "" $logPath
Write-LsqLog "Total gap between the two FB readings: $totalGap calls. This is calls on sources that are NEITHER cold-call NOR FB (Website, Inbound, LinkedIn, Kaustubh ICP, ...), not an error." $logPath

# Which non-bucketed sources make up the gap - so the gap is explainable, not a mystery.
Write-LsqLog "" $logPath
Write-LsqLog "=== 'Other' source calls today (the gap, by source) ===" $logPath
$otherBySource = @($candidates | Where-Object { (Get-SourceBucket "$($_.Source)" $ColdCallSources $FbSources) -eq "Other" } | Group-Object Source | Sort-Object Count -Descending)
foreach ($g in ($otherBySource | Select-Object -First 15)) {
    $n = "$($g.Name)"; if ([string]::IsNullOrWhiteSpace($n)) { $n = "<BLANK>" }
    Write-LsqLog ("  {0,6} candidate leads  [{1}]" -f $g.Count, $n) $logPath
}

$grandCalls = ($overallArr | Measure-Object -Property TotalCalls -Sum).Sum
$grandConn  = ($overallArr | Measure-Object -Property TotalConnected -Sum).Sum
$grandProsp = ($overallArr | Measure-Object -Property TotalProspects -Sum).Sum
$grandDisc  = ($overallArr | Measure-Object -Property TotalInDiscussion -Sum).Sum
Write-LsqLog "" $logPath
Write-LsqLog "TOTALS across the $($resolved.Count) reported reps: calls=$grandCalls connected=$grandConn prospects=$grandProsp inDiscussion=$grandDisc" $logPath

# ---------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------
$snapshot = [pscustomobject]@{
    RunAt            = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TargetDate       = $dayStart.ToString("yyyy-MM-dd")
    RepsRequested    = $Reps
    RepsResolved     = $resolved.ToArray()
    ColdCallSources  = $ColdCallSources
    FbSources        = $FbSources
    Dispositions     = $Dispositions
    CandidateLeads   = $candidates.Count
    CallScope        = $callScope.Count
    OpportunityScope = $oppLeads.Count
    ActivityScope    = $toPull.Count
    ActivityOk       = $ok
    ActivityFailed   = $failed
    OpportunityStageTally      = $oppStageTally
    OpportunityModifiedToday   = $oppTouchedToday
    AllSources       = $overallArr
    ColdCallOnly     = $coldArr
    FbDirectSource   = $fbDirectArr
    FbComparison     = $fbCompareArr
}
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding utf8
Write-LsqLog "" $logPath
Write-LsqLog "JSON snapshot written: $jsonPath" $logPath

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# Daily Calling Report - $($dayStart.ToString('yyyy-MM-dd dddd'))")
[void]$md.Add("")
[void]$md.Add("Run $((Get-Date).ToString('yyyy-MM-dd HH:mm')) IST. Candidate leads scanned: **$($candidates.Count)**; activity pulled for **$($toPull.Count)** ($ok ok / $failed failed) - call scope $($callScope.Count), opportunity scope $($oppLeads.Count).")
[void]$md.Add("")
[void]$md.Add("### Opportunity stage backdrop ($oppTotal opportunities found)")
[void]$md.Add("")
[void]$md.Add("| Opportunity stage | Total | Modified today |")
[void]$md.Add("|---|---|---|")
foreach ($k in ($oppStageTally.Keys | Sort-Object { -$oppStageTally[$_] })) {
    $t = 0
    if ($oppTouchedToday.ContainsKey($k)) { $t = $oppTouchedToday[$k] }
    [void]$md.Add("| $k | $($oppStageTally[$k]) | $t |")
}
[void]$md.Add("")
if ($legacy.Count -gt 0) {
    [void]$md.Add("> **Warning:** non-canonical Opportunity Stage value(s) present in live data: ``$($legacy -join '`, `')``. Migration step 06b cleared these; they are being re-introduced by reps.")
    [void]$md.Add("")
}
[void]$md.Add("**Totals across $($resolved.Count) reps: $grandCalls dials, $grandConn connected, $grandProsp moved to Prospect, $grandDisc opportunities at In Discussion.**")
[void]$md.Add("")

function Add-MdTable {
    param($Md, $Rows, [string]$Title, [string[]]$Dispositions)
    [void]$Md.Add("## $Title")
    [void]$Md.Add("")
    [void]$Md.Add("| Rep | Total Calls | Total Connected | Connect % | Contacts dialled | Talk time | Total Prospects | Total In Discussion | $($Dispositions[0]) | $($Dispositions[1]) |")
    [void]$Md.Add("|---|---|---|---|---|---|---|---|---|---|")
    foreach ($x in ($Rows | Sort-Object -Property TotalCalls -Descending)) {
        [void]$Md.Add("| $($x.Rep) | $($x.TotalCalls) | $($x.TotalConnected) | $($x.ConnectPct)% | $($x.ContactsDialled) | $($x.TalkTimeMin) min | $($x.TotalProspects) | $($x.TotalInDiscussion) | $($x.($Dispositions[0])) | $($x.($Dispositions[1])) |")
    }
    [void]$Md.Add("")
}

Add-MdTable $md $overallArr  "All sources" $Dispositions
Add-MdTable $md $coldArr     "Cold Call sources only (``$($ColdCallSources -join '`, `')``)" $Dispositions
Add-MdTable $md $fbDirectArr "FB Leads - direct Source filter (``$($FbSources -join '`, `')``)" $Dispositions

[void]$md.Add("## FB Leads - the two readings compared")
[void]$md.Add("")
# Single-quoted: a backtick inside a DOUBLE-quoted PowerShell string is the escape character
# and would silently vanish, stripping the markdown code formatting.
[void]$md.Add('`Total - Cold Call` versus a direct `Source = FB` filter. The gap is calls on sources that are neither (Website, Inbound, LinkedIn, Kaustubh ICP, ...).')
[void]$md.Add("")
[void]$md.Add("| Rep | Calls (Total - Cold) | Calls (Source = FB) | Gap | Connected (Total - Cold) | Connected (Source = FB) |")
[void]$md.Add("|---|---|---|---|---|---|")
foreach ($x in ($fbCompareArr | Sort-Object -Property CallsBySubtraction -Descending)) {
    [void]$md.Add("| $($x.Rep) | $($x.CallsBySubtraction) | $($x.CallsBySource) | $($x.GapCalls) | $($x.ConnBySubtraction) | $($x.ConnBySource) |")
}
[void]$md.Add("")
[void]$md.Add("**Total gap: $totalGap calls.**")
[void]$md.Add("")
[void]$md.Add("## Method / caveats")
[void]$md.Add("")
[void]$md.Add('- **Total Calls / Connected** come from the native telephony log (EventCode 22), attributed to whoever dialled - not to the lead owner. Connected = call duration > 0; the Status="Answered" count is also captured in the JSON, and the two do not always agree.')
[void]$md.Add('- **Total Prospects** counts the *act* of moving a contact to Prospect today (StageChange activity), not the standing number of contacts at Prospect.')
[void]$md.Add('- **Total In Discussion** counts opportunities *sitting at* In Discussion that were touched today. LSQ emits no per-field opportunity change event, so this cannot be narrowed to "moved to In Discussion today".')
[void]$md.Add('- Opportunities are swept over **every** lead at a deal-bearing contact stage, not off a timestamp watermark. Editing an opportunity does not move the parent lead''s `ModifiedOn` or `ProspectActivityDate_Max` (proven live 2026-08-04: 3 of 21 opportunities modified that day were invisible to both lead-level filters), so a watermarked scan silently under-reports every opportunity metric.')
[void]$md.Add("- **Call me Later / Follow Up** are current lead-field values on leads edited today, attributed to the lead owner. Same limitation: the field records no change actor or change time.")
if (-not $AllOwners) {
    [void]$md.Add("- Activity was pulled only for leads owned by the reported reps. A call placed by a reported rep on a lead owned by someone else is **not** counted. Re-run with ``-AllOwners`` to include them.")
}
$md | Set-Content -Path $summaryPath -Encoding utf8
Write-LsqLog "Markdown summary written: $summaryPath" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "=== Daily calling report complete ===" $logPath
