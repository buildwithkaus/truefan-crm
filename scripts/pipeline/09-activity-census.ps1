<#
.SYNOPSIS
  READ-ONLY. Census of every activity type in the account: which of the 57 configured types
  actually carry traffic, who generates each, and what a channel backfill would cost.

.DESCRIPTION
  Everything built so far reads six EventCodes (21, 22, 203, 3002, 12000, 33) and the live
  webhook path stores only three. That was correct for a calling pipeline and is wrong for a
  channel one: a 450-lead sample on 2026-08-03 found 1,565 WhatsApp events (codes 201 + 3011)
  against 2,059 outbound calls. WhatsApp is the second-largest touch channel in the account
  and is invisible to every report.

  This script answers, from live data rather than from the two-week-old cached schema dump:

    A. What activity types exist right now (the cached catalogue predates the Opportunity
       type, so it is known to be incomplete).
    B. Which types are the LAST activity on a lead, across the WHOLE book. Complete
       population, ~91 API calls, so it cannot be biased by a sampling choice. It is a lower
       bound - a type that never lands last is invisible here - which is why C exists.
    C. Which types appear anywhere in a trail, from two INDEPENDENT samples (see below).
    D. Whether EventCodes 204/205/206 hold real money. The Opportunity value fields are
       empty on 1,396 of 1,398 deals, but the SOP tells reps to log instalments on activity
       205 (Amount Received / Total Amount / Pending Amount). If that is populated, the
       "no deal value" problem is a reporting gap, not a data gap.
    E. Whether EventCode 3001 (LeadAssigned) carries the new owner. That decides whether
       assignment history is recoverable or only capturable going forward.
    F. What each candidate backfill scope would cost in API calls, so the scope decision is
       made on numbers.

  TWO SAMPLES, NEVER POOLED. Stratum 1 is a uniform random sample of the whole book and is
  the only one from which an account-wide rate may be read. Stratum 2 deliberately
  over-samples leads whose last activity is NOT a call, because a uniform sample of a book
  that is 41% Callkaro and mostly phone would observe a low-frequency channel zero times and
  report it as absent. Stratum 2 answers "what does this channel look like when it occurs",
  never "how common is it". Pooling them would silently inflate every non-call rate, so the
  output keeps them apart and labels which question each can answer.

  Reservoir sampling is used so the sample is drawn in one pass without holding ~91,000 lead
  objects in memory.

  NOTHING IS WRITTEN. Not to LeadSquared, not to Supabase. Output is JSON + Markdown + a
  PROPOSED ref_channel seed CSV for review before anything is applied.

.PARAMETER SampleSize
  Leads sampled per stratum for the trail census. 300 per stratum = ~600 API calls.

.PARAMETER MinExpectedLeads
  Absolute floor for the full scan, from an independent source (the book is ~91,000). Guards
  against a truncated scan, which reconciles perfectly against itself.

.PARAMETER SkipCatalogue
  Skip the live activity-type catalogue probe and use the cached dump.

.EXAMPLE
  powershell.exe -File scripts\pipeline\09-activity-census.ps1 -SampleSize 5   # smoke test
  powershell.exe -File scripts\pipeline\09-activity-census.ps1                 # full run

  Note: this machine has Windows PowerShell 5.1 only - `pwsh` is NOT installed, despite what
  the examples elsewhere in this repo say. Use powershell.exe.

.NOTES
  ASCII only (CLAUDE.md rule 6). Read-only against LeadSquared. Budget: ~91 calls for the
  full scan plus 2 x SampleSize trail pulls, against a 10,000/day cap.
#>

[CmdletBinding()]
param(
    [int]$SampleSize = 300,
    [int]$MinExpectedLeads = 80000,
    [int]$SleepMs = 250,
    [switch]$SkipCatalogue,
    [string]$TouchedSince = "2026-08-01"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "activity_census_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"

$cfg = Import-LsqConfig

Write-LsqLog "" $logPath
Write-LsqLog "=== Activity census $stamp (READ-ONLY) ===" $logPath
Write-LsqLog "SampleSize=$SampleSize per stratum, MinExpectedLeads=$MinExpectedLeads" $logPath


# =======================================================================================
# Channel mapping proposal.
#
# DATA, not logic: this table only PROPOSES a ref_channel seed for review. Nothing is
# applied. Anything not matched here comes out as 'unmapped', which is the point - an
# unrecognised EventCode must appear as a row nobody has classified yet, never as an
# absence. Every expensive failure in this repo has been silence read as zero.
#
# Keyed on "EventCode|EventName" because EventCode 3011 is genuinely two different things:
# it appears as both "WhatsApp Message" and "Opportunity" in the same trail dump.
# =======================================================================================
$Script:ChannelProposal = @{
    # --- phone -------------------------------------------------------------------------
    "22"   = @{ Channel = "phone";    Direction = "outbound"; Actor = "rep";         Touch = $true;  Engagement = $true  }
    "21"   = @{ Channel = "phone";    Direction = "inbound";  Actor = "rep";         Touch = $true;  Engagement = $true  }
    # 203 and 209 ANNOTATE a call, they are not calls. The telephony log (22/21) already
    # carries the dial, so marking these as touches would double-count every outcome a rep
    # bothers to fill in - which would perversely make the most disciplined reps look like
    # the highest-volume ones. 203 already lands in fact_call_outcome for this reason.
    "203"  = @{ Channel = "phone";    Direction = "outbound"; Actor = "rep";         Touch = $false; Engagement = $true  }
    # 209 "Call Disposition" did not exist when the cached catalogue was taken; it was
    # created 2026-08-06. It carries per-activity Call Disposition, Last Call Status,
    # Disqualification Category/Reason AND a first-class Notes field - i.e. exactly the
    # per-call disposition history the lead field cannot keep, and a real destination for
    # the notes that have never been capturable.
    "209"  = @{ Channel = "phone";    Direction = "outbound"; Actor = "rep";         Touch = $false; Engagement = $true  }
    "103"  = @{ Channel = "phone";    Direction = "outbound"; Actor = "rep";         Touch = $true;  Engagement = $true  }
    "104"  = @{ Channel = "phone";    Direction = "outbound"; Actor = "rep";         Touch = $true;  Engagement = $false }
    "105"  = @{ Channel = "phone";    Direction = "outbound"; Actor = "rep";         Touch = $true;  Engagement = $false }
    "208"  = @{ Channel = "ai_call";  Direction = "outbound"; Actor = "ai";          Touch = $false; Engagement = $false }
    "29"   = @{ Channel = "system";   Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
    "36"   = @{ Channel = "system";   Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }

    # --- messaging ---------------------------------------------------------------------
    # 201 carries its own Direction in mx_Custom_2 (Inbound|Outbound); the value below is
    # only the default for a record where that field is empty.
    "201"  = @{ Channel = "whatsapp"; Direction = "outbound"; Actor = "integration"; Touch = $true;  Engagement = $true  }
    "207"  = @{ Channel = "chat";     Direction = "inbound";  Actor = "integration"; Touch = $true;  Engagement = $true  }

    # --- meetings ----------------------------------------------------------------------
    "102"  = @{ Channel = "meeting";  Direction = "outbound"; Actor = "rep";         Touch = $true;  Engagement = $true  }
    "200"  = @{ Channel = "meeting";  Direction = "outbound"; Actor = "rep";         Touch = $true;  Engagement = $true  }
    "101"  = @{ Channel = "meeting";  Direction = "inbound";  Actor = "rep";         Touch = $true;  Engagement = $true  }

    # --- deal / money ------------------------------------------------------------------
    "12000" = @{ Channel = "deal";    Direction = "";         Actor = "rep";         Touch = $false; Engagement = $false }
    "33"    = @{ Channel = "deal";    Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
    "32"    = @{ Channel = "deal";    Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
    "204"   = @{ Channel = "deal";    Direction = "outbound"; Actor = "rep";         Touch = $true;  Engagement = $true  }
    "205"   = @{ Channel = "payment"; Direction = "";         Actor = "rep";         Touch = $false; Engagement = $false }
    "206"   = @{ Channel = "payment"; Direction = "";         Actor = "rep";         Touch = $false; Engagement = $false }
    "98"    = @{ Channel = "payment"; Direction = "";         Actor = "integration"; Touch = $false; Engagement = $false }
    "30"    = @{ Channel = "deal";    Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }

    # --- forms / inbound capture -------------------------------------------------------
    "97"   = @{ Channel = "form";     Direction = "inbound";  Actor = "integration"; Touch = $false; Engagement = $true  }
    "202"  = @{ Channel = "form";     Direction = "inbound";  Actor = "integration"; Touch = $false; Engagement = $true  }
    "23"   = @{ Channel = "system";   Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }

    # --- system events (no ActivityType metadata; observed live only) ------------------
    "3001" = @{ Channel = "system";   Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
    "3002" = @{ Channel = "system";   Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
    "3004" = @{ Channel = "system";   Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
    "3006" = @{ Channel = "system";   Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
}

# EventCode 3011 is resolved by name, not by code - it is the one collision in the account.
$Script:ChannelProposalByName = @{
    "3011|WhatsApp Message" = @{ Channel = "whatsapp"; Direction = "outbound"; Actor = "integration"; Touch = $true;  Engagement = $true  }
    "3011|Opportunity"      = @{ Channel = "deal";     Direction = "";         Actor = "system";      Touch = $false; Engagement = $false }
}

function Get-ProposedChannel {
    <#
      PURE. Proposes a channel row for one EventCode/EventName pair. Falls back to the
      catalogue's own Tags before giving up, so the ~45 email/web/privacy types classify
      themselves rather than all landing in 'unmapped' and drowning the review.

      Returns a hashtable, never $null. An unrecognised type comes back as 'unmapped' on
      purpose - see the header on $Script:ChannelProposal.
    #>
    param(
        [Parameter(Mandatory)][string]$EventCode,
        [string]$EventName = "",
        [string]$Tags = ""
    )

    $byName = "$EventCode|$EventName"
    if ($Script:ChannelProposalByName.ContainsKey($byName)) { return $Script:ChannelProposalByName[$byName] }
    if ($Script:ChannelProposal.ContainsKey($EventCode))    { return $Script:ChannelProposal[$EventCode] }

    # Tag-derived fallback for the long tail of marketing/system types.
    if ($Tags -like "*{Email}*") {
        # Responses are the prospect replying; opens and clicks are the prospect reacting.
        # Neither is outreach we performed, so is_touch stays false for the whole family.
        $isReply = ($EventName -like "*Response*") -or ($EventName -like "*Inbound Email*")
        return @{ Channel = "email"; Direction = "inbound"; Actor = "integration"
                  Touch = $false; Engagement = $true; Reply = $isReply }
    }
    if ($Tags -like "*{Web}*" -or $Tags -like "*{Portal}*" -or $Tags -like "*{Widget}*" -or
        $Tags -like "*{Landing Pages Pro}*") {
        return @{ Channel = "web"; Direction = "inbound"; Actor = "integration"; Touch = $false; Engagement = $true }
    }
    if ($Tags -like "*{Forms}*") {
        return @{ Channel = "form"; Direction = "inbound"; Actor = "integration"; Touch = $false; Engagement = $true }
    }
    if ($Tags -like "*{Privacy}*" -or $Tags -like "*{Document Designer}*" -or $Tags -like "*{Capture}*") {
        return @{ Channel = "system"; Direction = ""; Actor = "system"; Touch = $false; Engagement = $false }
    }

    return @{ Channel = "unmapped"; Direction = ""; Actor = "unknown"; Touch = $false; Engagement = $false }
}


# =======================================================================================
# CONTROL. If this fails, every zero below is meaningless.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- CONTROL ---" $logPath
$controlOk = $false
try {
    $ctlUri = "$($cfg['LSQ_API_HOST'])/LeadManagement.svc/LeadsMetaData.Get?accessKey=$($cfg['LSQ_ACCESS_KEY'])&secretKey=$($cfg['LSQ_SECRET_KEY'])"
    $ctl = Invoke-WebRequest -Uri $ctlUri -Method Get -UseBasicParsing -ErrorAction Stop
    $controlOk = ($ctl.StatusCode -eq 200)
} catch { $controlOk = $false }
Write-LsqLog "  LeadsMetaData.Get -> $(if ($controlOk) { '200 OK' } else { 'FAILED' })" $logPath
if (-not $controlOk) { throw "CONTROL CALL FAILED - credentials or host are broken. Every result below would be meaningless." }


# =======================================================================================
# A. The live activity-type catalogue.
#
# The cached data/activity_types_schema.json is dated 2026-07-27 and predates the
# Opportunity type created the same day, so it is known-incomplete. No generator script
# survives, so the endpoint is probed rather than assumed - the same discipline that found
# GetOpportunityDetails after 14 wrong guesses had "proved" it did not exist.
# =======================================================================================
function Find-ActivityCatalogue {
    <#
      PURE. Probes candidate endpoints and returns the first that yields activity types.
      Returns @{ Path; Method; Types; Attempts } - Types is empty when nothing worked, and
      Attempts carries every probe so the caller can log the whole trail.
    #>
    param([Parameter(Mandatory)][hashtable]$Config)

    $base = $Config['LSQ_API_HOST']; $ak = $Config['LSQ_ACCESS_KEY']; $sk = $Config['LSQ_SECRET_KEY']
    $candidates = @(
        @{ Path = "ProspectActivity.svc/ActivityTypes.Get";     Method = "GET" }
        @{ Path = "v2/ProspectActivity.svc/ActivityTypes.Get";  Method = "GET" }
        @{ Path = "ProspectActivity.svc/ActivityTypes/Get";     Method = "GET" }
        @{ Path = "ProspectActivity.svc/ActivityType.Get";      Method = "GET" }
        @{ Path = "ProspectActivity.svc/GetActivityTypes";      Method = "GET" }
        @{ Path = "LeadManagement.svc/LeadActivityMetaData.Get"; Method = "GET" }
        @{ Path = "ProspectActivity.svc/ActivityTypes.Get";     Method = "POST" }
    )

    $attempts = New-Object System.Collections.Generic.List[object]
    foreach ($c in $candidates) {
        $uri = "$base/$($c.Path)?accessKey=$ak&secretKey=$sk"
        $status = ""; $types = @()
        try {
            $params = @{ Uri = $uri; Method = $c.Method; UseBasicParsing = $true; ErrorAction = "Stop" }
            if ($c.Method -eq "POST") {
                $params["Body"] = "{}"
                $params["ContentType"] = "application/json"
            }
            # Invoke-WebRequest then ConvertFrom-Json, never Invoke-RestMethod: @() on an
            # Invoke-RestMethod result counts $null as 1 and a nested array as 1 (gotcha 19).
            $raw = Invoke-WebRequest @params
            $status = "HTTP $($raw.StatusCode)"
            $parsed = $raw.Content | ConvertFrom-Json

            # The payload may be a bare array or wrapped one level deep.
            $rows = @()
            if ($parsed -is [System.Array]) { $rows = $parsed }
            else {
                foreach ($p in $parsed.PSObject.Properties) {
                    if ($p.Value -is [System.Array]) { $rows = $p.Value; break }
                }
            }
            $withCode = @($rows | Where-Object { $null -ne $_.ActivityEvent })
            if ($withCode.Count -gt 0) { $types = $withCode }
        } catch {
            $status = $_.Exception.Message
            if ($status.Length -gt 80) { $status = $status.Substring(0, 80) + "..." }
        }
        [void]$attempts.Add([pscustomobject]@{
            Path = $c.Path; Method = $c.Method; Status = $status; TypeCount = @($types).Count
        })
        if (@($types).Count -gt 0) {
            return @{ Path = $c.Path; Method = $c.Method; Types = $types; Attempts = $attempts.ToArray() }
        }
    }
    return @{ Path = ""; Method = ""; Types = @(); Attempts = $attempts.ToArray() }
}

Write-LsqLog "" $logPath
Write-LsqLog "--- A. Activity-type catalogue ---" $logPath

$catalogue = @{}     # "EventCode" -> @{ Name; Tags; EventType; Direction }
$catalogueSource = ""

if (-not $SkipCatalogue) {
    $found = Find-ActivityCatalogue -Config $cfg
    foreach ($a in $found.Attempts) {
        Write-LsqLog ("  {0,-6} {1,-44} {2,-14} types={3}" -f $a.Method, $a.Path, $a.Status, $a.TypeCount) $logPath
    }
    if (@($found.Types).Count -gt 0) {
        $catalogueSource = "live:$($found.Path)"
        $livePath = Join-Path $dataDir "activity_types_schema_$stamp.json"
        ($found.Types | ConvertTo-Json -Depth 8) | Set-Content -Path $livePath -Encoding UTF8
        Write-LsqLog "  LIVE catalogue: $(@($found.Types).Count) types -> $livePath" $logPath
        foreach ($t in $found.Types) {
            $catalogue["$($t.ActivityEvent)"] = @{
                Name = "$($t.ActivityEventName)"; Tags = "$($t.Tags)"
                EventType = "$($t.EventType)";    Direction = "$($t.EventDirection)"
            }
        }
    } else {
        Write-LsqLog "  No catalogue endpoint answered. Falling back to the cached dump." $logPath
    }
}

if ($catalogue.Count -eq 0) {
    $cachedPath = Join-Path $dataDir "activity_types_schema.json"
    if (Test-Path $cachedPath) {
        $cached = (Get-Content $cachedPath -Raw) | ConvertFrom-Json
        foreach ($t in $cached) {
            $catalogue["$($t.ActivityEvent)"] = @{
                Name = "$($t.ActivityEventName)"; Tags = "$($t.Tags)"
                EventType = "$($t.EventType)";    Direction = "$($t.EventDirection)"
            }
        }
        $catalogueSource = "cached:2026-07-27 (STALE - predates the Opportunity type)"
        Write-LsqLog "  Cached catalogue: $($catalogue.Count) types. STALE, treat gaps with suspicion." $logPath
    } else {
        $catalogueSource = "none"
        Write-LsqLog "  WARNING: no catalogue at all. Every type will classify from live data only." $logPath
    }
}


# =======================================================================================
# B. Whole-book enumeration of ProspectActivityName_Max.
#
# Complete population. Cheap (~91 pages). It is a LOWER BOUND on which types are in use -
# the field holds one value, so a type that never lands last is invisible here. That is
# exactly why it is never used as a hard exclusion anywhere in this repo, and why section C
# exists alongside it.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- B. Whole-book last-activity enumeration ---" $logPath

# Negative control first. A zero result is as suspect as a weird non-zero one; two
# unverified zeros once silently skipped 20,076 leads.
$negRows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "ProspectActivityName_Max"; LookupValue = "ZZ_NoSuchActivity_ZZ"; SqlOperator = "="
} -ColumnsCsv "ProspectID" -PageSize 100 -SortColumn "CreatedOn"))
Write-LsqLog "  negative control: $($negRows.Count) rows -- must be 0" $logPath
if ($negRows.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the activity-name filter is being ignored." }

$sinceUtc = ConvertFrom-LsqUtc "$TouchedSince 00:00:00"
if ($null -eq $sinceUtc) { throw "TouchedSince '$TouchedSince' is not a parsable date." }

$cols = "ProspectID,OwnerId,OwnerIdName,ProspectStage,ProspectActivityName_Max,ProspectActivityDate_Max"

$nameTally    = @{}    # last-activity name -> count
$stageTally   = @{}    # contact stage -> count
$total        = 0
# NOT $touchedSinceCount. PowerShell variable names are case-INSENSITIVE, so that name is the
# same variable as the [string]$TouchedSince parameter - and because the parameter is TYPED,
# assigning 0 to it coerces straight back to the string "0". The counter then throws
# "'++' works only on numbers" 90 pages into a scan. Same family as the $pid / $host
# read-only-automatic trap in gotcha 19: a parameter name is reserved for the whole script.
$touchedSinceCount = 0
$workable     = 0
$page         = 1

# Reservoir sampling: one pass, bounded memory. Holding ~91,000 lead objects to sample from
# afterwards works until the book grows; this does not change.
$rand      = New-Object System.Random 20260810
$reservoirAll  = New-Object System.Collections.Generic.List[object]
$reservoirNonCall = New-Object System.Collections.Generic.List[object]
$seenAll = 0; $seenNonCall = 0

$callNames = @($Script:CallActivityNames) + @($Script:AI_ACTIVITY_NAME)

Write-LsqLog "  scanning the full book (about 91 pages)..." $logPath
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "CreatedOn"; LookupValue = "2000-01-01 00:00:00"; SqlOperator = ">"
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }

    foreach ($r in $rows) {
        $total++

        $name = "$($r.ProspectActivityName_Max)"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "<none>" }
        if ($nameTally.ContainsKey($name)) { $nameTally[$name]++ } else { $nameTally[$name] = 1 }

        $stage = "$($r.ProspectStage)"
        if ([string]::IsNullOrWhiteSpace($stage)) { $stage = "<blank>" }
        if ($stageTally.ContainsKey($stage)) { $stageTally[$stage]++ } else { $stageTally[$stage] = 1 }
        if ($stage -eq "Fresh" -or $stage -eq "Engaged" -or $stage -eq "Prospect") { $workable++ }

        $touchedAt = ConvertFrom-LsqUtc "$($r.ProspectActivityDate_Max)"
        if ($null -ne $touchedAt -and $touchedAt -ge $sinceUtc) { $touchedSinceCount++ }

        # Stratum 1 - uniform over the whole book.
        $seenAll++
        if ($reservoirAll.Count -lt $SampleSize) { [void]$reservoirAll.Add($r) }
        else {
            $j = $rand.Next(0, $seenAll)
            if ($j -lt $SampleSize) { $reservoirAll[$j] = $r }
        }

        # Stratum 2 - leads whose last activity is NOT a call and NOT the AI dialler.
        # Deliberately biased; it answers "what does this channel look like", never "how
        # common is it".
        if ($name -ne "<none>" -and $callNames -notcontains $name) {
            $seenNonCall++
            if ($reservoirNonCall.Count -lt $SampleSize) { [void]$reservoirNonCall.Add($r) }
            else {
                $k = $rand.Next(0, $seenNonCall)
                if ($k -lt $SampleSize) { $reservoirNonCall[$k] = $r }
            }
        }
    }

    if ($page % 20 -eq 0) { Write-LsqLog "    page $page -> running total $total" $logPath }
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 300) { Write-LsqLog "  WARNING: stopped at 300 pages" $logPath; break }
}

Write-LsqLog "  scanned $total leads across $page pages" $logPath

# Guard against an INDEPENDENT expected size. A truncated scan reconciles perfectly against
# itself - that is exactly how a one-page scan once reported as a whole-account sweep.
if ($total -lt $MinExpectedLeads) {
    throw "Scanned only $total leads, expected at least $MinExpectedLeads. Refusing to report a partial census."
}

$nameSum = 0
foreach ($v in $nameTally.Values) { $nameSum += $v }
Write-LsqLog "  reconcile: name tally $nameSum vs scanned $total -- $(if ($nameSum -eq $total) { 'OK' } else { 'MISMATCH' })" $logPath
if ($nameSum -ne $total) { throw "Last-activity tally does not reconcile to the scan total." }

Write-LsqLog "" $logPath
Write-LsqLog "  last activity across the whole book:" $logPath
$nameTally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-LsqLog ("    {0,7}  {1}" -f $_.Value, $_.Name) $logPath
}
Write-LsqLog "" $logPath
Write-LsqLog "  workable (Fresh/Engaged/Prospect): $workable" $logPath
Write-LsqLog "  touched since $TouchedSince          : $touchedSinceCount" $logPath
Write-LsqLog "  stratum 2 frame (non-call last act) : $seenNonCall" $logPath


# =======================================================================================
# C. Trail census over the two strata.
# =======================================================================================
function Measure-ActivityTrails {
    <#
      PURE. Pulls the trail for each lead and tallies EventCode|EventName. Returns a
      hashtable of results and writes nothing - a function that both logs and returns hands
      the caller its log lines bundled with the return value.

      Money and direction fields are read here because they are the whole point of sections
      D and E: reading a trail is one API call and re-reading it later to extract one more
      field would double the budget for nothing.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Leads,
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$SleepMs = 250
    )

    $tally     = @{}   # "code|name" -> @{ Events; Leads(hash); Actors(hash); First; Last; WithFields }
    $moneyRows = New-Object System.Collections.Generic.List[object]
    $dispoRows = New-Object System.Collections.Generic.List[object]
    $waStatus  = @{}
    $waDir     = @{}
    $assignSamples = New-Object System.Collections.Generic.List[object]
    $errors    = New-Object System.Collections.Generic.List[object]
    $done = 0

    foreach ($lead in $Leads) {
        $pid_ = "$($lead.ProspectID)"
        try {
            $acts = Get-LeadActivities -ProspectId $pid_ -Config $Config
            $done++
        } catch {
            [void]$errors.Add([pscustomobject]@{ ProspectID = $pid_; Error = "$($_.Exception.Message)" })
            Start-Sleep -Milliseconds $SleepMs
            continue
        }

        foreach ($a in $acts) {
            $code = "$($a.EventCode)"
            $name = "$($a.EventName)"
            if ([string]::IsNullOrWhiteSpace($name)) { $name = "<no name>" }
            $key = "$code|$name"

            if (-not $tally.ContainsKey($key)) {
                # NOT a member called Count. A hashtable already HAS an intrinsic, read-only
                # Count property (its number of entries), and $e.Count would silently read
                # that instead of the counter - four, forever, on every row.
                $tally[$key] = @{
                    Events = 0; Leads = @{}; Actors = @{}
                    First = $null; Last = $null; WithFields = 0
                }
            }
            $e = $tally[$key]
            $e.Events++
            $e.Leads[$pid_] = $true

            $actor = "$($a.ActivityFields.CreatedBy)".Trim()
            if (-not $actor) { $actor = (Get-ActivityDataValue $a "CreatedBy") }
            if ($actor) { $e.Actors[$actor] = $true }

            if ($null -ne $a.ActivityFields) { $e.WithFields++ }

            $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
            if ($null -ne $when) {
                if ($null -eq $e.First -or $when -lt $e.First) { $e.First = $when }
                if ($null -eq $e.Last  -or $when -gt $e.Last)  { $e.Last  = $when }
            }

            # D. Money on 204 / 205 / 206. Field map read from the live activity schema:
            #    205 mx_Custom_1 Amount Received, _4 Total Amount, _5 Pending Amount
            #    206 Status = Payment Received (Yes|No)
            #    204 Status = In Progress|Follow Up|Signed|Not Interested|Future Prospect
            if ($code -eq "205" -or $code -eq "206" -or $code -eq "204") {
                [void]$moneyRows.Add([pscustomobject]@{
                    ProspectID     = $pid_
                    EventCode      = $code
                    CreatedOn      = "$($a.CreatedOn)"
                    Status         = "$($a.ActivityFields.Status)"
                    AmountReceived = "$($a.ActivityFields.mx_Custom_1)"
                    TotalAmount    = "$($a.ActivityFields.mx_Custom_4)"
                    PendingAmount  = "$($a.ActivityFields.mx_Custom_5)"
                    Note           = "$($a.ActivityFields.ActivityEvent_Note)"
                })
            }

            # 209 "Call Disposition" and 203. The question is not whether they exist but
            # whether the Notes field is actually filled: notes have been structurally
            # uncapturable until now (no Notes API, and the lead Notes field holds imported
            # ICP descriptions), so 0 have ever been recorded. If 209 carries real notes,
            # the longest-standing gap in this CRM closes with a webhook rather than a
            # product decision.
            if ($code -eq "209" -or $code -eq "203") {
                $noteText = "$($a.ActivityFields.ActivityEvent_Note)".Trim()
                # 203 and 209 REUSE mx_Custom_1/2/3 for completely different things. Reading
                # them without branching on the event code first is the same defect that put
                # call durations into a text outcome field (gotcha 14), and it silently
                # produces a plausible-looking tally of the wrong vocabulary.
                #   203  _1 Not Connected Outcome  _2 Connected Outcome  _3 Next Step
                #   209  _1 Call Disposition       _2 Last Call Status   _3 Disq Category
                #                                                        _4 Disq Reason
                if ($code -eq "209") {
                    [void]$dispoRows.Add([pscustomobject]@{
                        ProspectID = $pid_; EventCode = $code; CreatedOn = "$($a.CreatedOn)"
                        Field      = "Call Disposition"
                        Value      = "$($a.ActivityFields.mx_Custom_1)"
                        Secondary  = "$($a.ActivityFields.mx_Custom_2)"   # Last Call Status
                        DisqCategory = "$($a.ActivityFields.mx_Custom_3)"
                        DisqReason   = "$($a.ActivityFields.mx_Custom_4)"
                        HasNote    = [bool]$noteText; NoteLength = $noteText.Length
                    })
                } else {
                    $connected = "$($a.ActivityFields.mx_Custom_2)".Trim()
                    $notConn   = "$($a.ActivityFields.mx_Custom_1)".Trim()
                    [void]$dispoRows.Add([pscustomobject]@{
                        ProspectID = $pid_; EventCode = $code; CreatedOn = "$($a.CreatedOn)"
                        Field      = $(if ($connected) { "Connected Outcome" } else { "Not Connected Outcome" })
                        Value      = $(if ($connected) { $connected } else { $notConn })
                        Secondary  = "$($a.ActivityFields.mx_Custom_3)"   # Next Step
                        DisqCategory = ""
                        DisqReason   = ""
                        HasNote    = [bool]$noteText; NoteLength = $noteText.Length
                    })
                }
            }

            # WhatsApp direction and delivery status - the two fields that decide whether
            # 201 can carry a reply rate at all.
            if ($code -eq "201" -or ($code -eq "3011" -and $name -eq "WhatsApp Message")) {
                $st = "$($a.ActivityFields.Status)"; if (-not $st) { $st = "<blank>" }
                $dr = "$($a.ActivityFields.mx_Custom_2)"; if (-not $dr) { $dr = "<blank>" }
                if ($waStatus.ContainsKey($st)) { $waStatus[$st]++ } else { $waStatus[$st] = 1 }
                if ($waDir.ContainsKey($dr))    { $waDir[$dr]++ }    else { $waDir[$dr] = 1 }
            }

            # E. Does LeadAssigned carry the new owner? Keep a few whole records so the
            # answer is inspectable rather than asserted.
            if ($code -eq "3001" -and $assignSamples.Count -lt 5) {
                $keys = @()
                foreach ($d in @($a.Data)) { $keys += "$($d.Key)=$($d.Value)" }
                [void]$assignSamples.Add([pscustomobject]@{
                    ProspectID = $pid_
                    CreatedOn  = "$($a.CreatedOn)"
                    DataPairs  = ($keys -join " | ")
                    FieldKeys  = (@($a.ActivityFields.PSObject.Properties.Name) -join ",")
                })
            }
        }

        Start-Sleep -Milliseconds $SleepMs
    }

    return @{
        Tally = $tally; Sampled = $done; Errors = $errors.ToArray()
        Money = $moneyRows.ToArray(); WaStatus = $waStatus; WaDirection = $waDir
        AssignSamples = $assignSamples.ToArray(); Dispositions = $dispoRows.ToArray()
    }
}

Write-LsqLog "" $logPath
Write-LsqLog "--- C. Trail census, stratum 1 (uniform over the whole book) ---" $logPath
$s1 = Measure-ActivityTrails -Leads $reservoirAll.ToArray() -Config $cfg -SleepMs $SleepMs
Write-LsqLog "  sampled $($s1.Sampled) leads ($($s1.Errors.Count) failed)" $logPath
$s1.Tally.GetEnumerator() | Sort-Object { $_.Value.Events } -Descending | ForEach-Object {
    Write-LsqLog ("    {0,6} events / {1,4} leads / {2,3} actors   {3}" -f `
        $_.Value.Events, $_.Value.Leads.Count, $_.Value.Actors.Count, $_.Key) $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "--- C. Trail census, stratum 2 (over-samples non-call leads - shape only, NOT a rate) ---" $logPath
$s2 = Measure-ActivityTrails -Leads $reservoirNonCall.ToArray() -Config $cfg -SleepMs $SleepMs
Write-LsqLog "  sampled $($s2.Sampled) leads ($($s2.Errors.Count) failed)" $logPath
$s2.Tally.GetEnumerator() | Sort-Object { $_.Value.Events } -Descending | ForEach-Object {
    Write-LsqLog ("    {0,6} events / {1,4} leads / {2,3} actors   {3}" -f `
        $_.Value.Events, $_.Value.Leads.Count, $_.Value.Actors.Count, $_.Key) $logPath
}


# =======================================================================================
# D. Does any money exist on 204 / 205 / 206?
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- D. Money on activities 204 / 205 / 206 ---" $logPath

$allMoney = @($s1.Money) + @($s2.Money)
$withAmount = @($allMoney | Where-Object {
    $n = 0.0
    ([double]::TryParse($_.AmountReceived, [ref]$n) -and $n -gt 0) -or
    ([double]::TryParse($_.TotalAmount,    [ref]$n) -and $n -gt 0)
})
Write-LsqLog "  205/206/204 activities seen : $($allMoney.Count)" $logPath
Write-LsqLog "  carrying a non-zero amount  : $($withAmount.Count)" $logPath
if ($withAmount.Count -gt 0) {
    Write-LsqLog "  VERDICT: money IS being logged on activities. Value-weighted conversion is reachable." $logPath
    foreach ($m in ($withAmount | Select-Object -First 10)) {
        Write-LsqLog ("    {0}  recv={1} total={2} pending={3} status={4}" -f `
            $m.EventCode, $m.AmountReceived, $m.TotalAmount, $m.PendingAmount, $m.Status) $logPath
    }
} else {
    Write-LsqLog "  VERDICT: no amounts found in this sample. ICP analysis stays count-based." $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "--- D2. Per-call disposition and NOTES on 209 / 203 ---" $logPath
$allDispo = @($s1.Dispositions) + @($s2.Dispositions)
$withNote = @($allDispo | Where-Object { $_.HasNote })
Write-LsqLog "  209/203 activities seen : $($allDispo.Count)" $logPath
Write-LsqLog "  carrying a real note    : $($withNote.Count)" $logPath
Write-LsqLog "  of which EventCode 209 : $(@($allDispo | Where-Object { $_.EventCode -eq '209' }).Count)" $logPath
if ($allDispo.Count -gt 0) {
    # Tallied per (EventCode, Field) because these are DIFFERENT vocabularies living in the
    # same mx_Custom_1 slot. Merging them would invent a single option list that no dropdown
    # anywhere actually has.
    $dispoTally = @{}
    foreach ($d in $allDispo) {
        $v = "$($d.Value)"; if (-not $v) { $v = "<blank>" }
        $key = "$($d.EventCode) $($d.Field) = $v"
        if ($dispoTally.ContainsKey($key)) { $dispoTally[$key]++ } else { $dispoTally[$key] = 1 }
    }
    Write-LsqLog "  values used (per event code and field):" $logPath
    $dispoTally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        Write-LsqLog ("    {0,5}  {1}" -f $_.Value, $_.Name) $logPath
    }
}
if ($withNote.Count -gt 0) {
    Write-LsqLog "  VERDICT: notes ARE being written here. This is a destination for the note gap." $logPath
} else {
    Write-LsqLog "  VERDICT: no notes in this sample. The note gap is unchanged." $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "--- WhatsApp field usage (201 / 3011) ---" $logPath
$waStatusAll = @{}; $waDirAll = @{}
foreach ($src in @($s1.WaStatus, $s2.WaStatus)) {
    foreach ($k in $src.Keys) { if ($waStatusAll.ContainsKey($k)) { $waStatusAll[$k] += $src[$k] } else { $waStatusAll[$k] = $src[$k] } }
}
foreach ($src in @($s1.WaDirection, $s2.WaDirection)) {
    foreach ($k in $src.Keys) { if ($waDirAll.ContainsKey($k)) { $waDirAll[$k] += $src[$k] } else { $waDirAll[$k] = $src[$k] } }
}
Write-LsqLog "  Status  : $(($waStatusAll.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')" $logPath
Write-LsqLog "  Direction: $(($waDirAll.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')" $logPath


# =======================================================================================
# E. Does EventCode 3001 (LeadAssigned) carry the new owner?
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- E. LeadAssigned (3001) record shape ---" $logPath
$assignAll = @($s1.AssignSamples) + @($s2.AssignSamples)
if ($assignAll.Count -eq 0) {
    Write-LsqLog "  No 3001 records in either sample. Assignment history may be forward-only." $logPath
} else {
    foreach ($a in ($assignAll | Select-Object -First 5)) {
        Write-LsqLog "  $($a.CreatedOn)  Data[ $($a.DataPairs) ]" $logPath
        Write-LsqLog "     ActivityFields keys: $($a.FieldKeys)" $logPath
    }
    Write-LsqLog "  Read the pairs above: if an owner id or name is present, assignment history" $logPath
    Write-LsqLog "  is RECOVERABLE from trails. If not, only the assignment DATE is." $logPath
}


# =======================================================================================
# F. What would a channel backfill cost?
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- F. Backfill scope pricing (cap is 10,000 API calls/day) ---" $logPath

# Share of stratum-1 leads holding at least one non-call, non-system activity. Only stratum
# 1 may be used for this - stratum 2 is biased by construction.
$nonCallChannels = @("whatsapp", "chat", "meeting", "email", "form", "payment")
$leadsWithChannel = @{}
foreach ($k in $s1.Tally.Keys) {
    $parts = $k.Split('|')
    $prop = Get-ProposedChannel -EventCode $parts[0] -EventName $parts[1] `
                -Tags $(if ($catalogue.ContainsKey($parts[0])) { $catalogue[$parts[0]].Tags } else { "" })
    if ($nonCallChannels -contains $prop.Channel) {
        foreach ($lid in $s1.Tally[$k].Leads.Keys) { $leadsWithChannel[$lid] = $true }
    }
}
$share = 0.0
if ($s1.Sampled -gt 0) { $share = [math]::Round(100.0 * $leadsWithChannel.Count / $s1.Sampled, 1) }

Write-LsqLog "  stratum-1 leads holding a non-call channel activity: $($leadsWithChannel.Count) of $($s1.Sampled) ($share%)" $logPath
Write-LsqLog "" $logPath
Write-LsqLog ("  {0,-40} {1,9}  {2}" -f "scope", "API calls", "nights at 8,000/day") $logPath
foreach ($scope in @(
    @{ Name = "whole book";                       N = $total }
    @{ Name = "workable book (Fresh/Eng/Prosp)";  N = $workable }
    @{ Name = "touched since $TouchedSince";      N = $touchedSinceCount }
    @{ Name = "non-call last activity only";      N = $seenNonCall }
)) {
    $nights = [math]::Ceiling($scope.N / 8000.0)
    Write-LsqLog ("  {0,-40} {1,9}  {2}" -f $scope.Name, $scope.N, $nights) $logPath
}
Write-LsqLog "" $logPath
Write-LsqLog "  Estimated rows recovered = scope x $share% (from stratum 1 only)." $logPath


# =======================================================================================
# Output: JSON, Markdown summary, and a PROPOSED ref_channel seed.
# =======================================================================================
function ConvertTo-CensusRows {
    <#
      PURE. Flattens a tally hashtable into sortable rows with the proposed channel mapping
      attached. Used for both strata and for the seed file, so one classification is applied
      everywhere rather than three that can drift.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Tally,
        [Parameter(Mandatory)][hashtable]$Catalogue,
        [int]$SampledLeads
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($k in $Tally.Keys) {
        $parts = $k.Split('|')
        $code = $parts[0]
        $name = $(if ($parts.Count -gt 1) { $parts[1] } else { "" })
        $tags = ""; $known = $false
        if ($Catalogue.ContainsKey($code)) { $tags = $Catalogue[$code].Tags; $known = $true }
        $prop = Get-ProposedChannel -EventCode $code -EventName $name -Tags $tags
        $e = $Tally[$k]
        [void]$rows.Add([pscustomobject]@{
            EventCode        = $code
            EventName        = $name
            InCatalogue      = $known
            Tags             = $tags
            Events           = $e.Events
            Leads            = $e.Leads.Count
            Actors           = $e.Actors.Count
            PctOfSampledLeads= $(if ($SampledLeads -gt 0) { [math]::Round(100.0 * $e.Leads.Count / $SampledLeads, 1) } else { 0 })
            HasActivityFields= $e.WithFields
            FirstSeen        = $(if ($e.First) { $e.First.ToString("yyyy-MM-dd") } else { "" })
            LastSeen         = $(if ($e.Last)  { $e.Last.ToString("yyyy-MM-dd") }  else { "" })
            ProposedChannel  = $prop.Channel
            ProposedDirection= $prop.Direction
            ProposedActorKind= $prop.Actor
            ProposedIsTouch  = $prop.Touch
            ProposedIsEngagement = $prop.Engagement
        })
    }
    return $rows.ToArray()
}

$rows1 = ConvertTo-CensusRows -Tally $s1.Tally -Catalogue $catalogue -SampledLeads $s1.Sampled
$rows2 = ConvertTo-CensusRows -Tally $s2.Tally -Catalogue $catalogue -SampledLeads $s2.Sampled

# The seed is the UNION of both strata: stratum 2 exists precisely so a rare channel gets a
# row. Counts are deliberately not carried into the seed - it is a mapping, not a measurement.
$seen = @{}
$seedRows = New-Object System.Collections.Generic.List[object]
foreach ($r in (@($rows1) + @($rows2))) {
    $key = "$($r.EventCode)|$($r.EventName)"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    [void]$seedRows.Add([pscustomobject]@{
        event_code    = $r.EventCode
        event_name    = $r.EventName
        channel       = $r.ProposedChannel
        direction     = $r.ProposedDirection
        actor_kind    = $r.ProposedActorKind
        is_touch      = $r.ProposedIsTouch
        is_engagement = $r.ProposedIsEngagement
        is_active     = $true
        notes         = "PROPOSED $stamp from live census; review before applying"
    })
}

$jsonPath = Join-Path $dataDir "activity_census_$stamp.json"
$mdPath   = Join-Path $dataDir "activity_census_summary_$stamp.md"
$seedPath = Join-Path $dataDir "ref_channel_seed_$stamp.csv"

@{
    Stamp             = $stamp
    CatalogueSource   = $catalogueSource
    CatalogueTypes    = $catalogue.Count
    BookTotal         = $total
    Workable          = $workable
    TouchedSince      = @{ Date = $TouchedSince; Leads = $touchedSinceCount }
    NonCallFrame      = $seenNonCall
    LastActivityTally = $nameTally
    ContactStageTally = $stageTally
    Stratum1          = @{ Sampled = $s1.Sampled; Failed = $s1.Errors.Count; Rows = $rows1 }
    Stratum2          = @{ Sampled = $s2.Sampled; Failed = $s2.Errors.Count; Rows = $rows2 }
    Money             = @{ Seen = $allMoney.Count; WithAmount = $withAmount.Count; Rows = $allMoney }
    WhatsAppStatus    = $waStatusAll
    WhatsAppDirection = $waDirAll
    LeadAssignedShape = $assignAll
    ChannelShareS1    = $share
} | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

$seedRows.ToArray() | Export-Csv -Path $seedPath -NoTypeInformation -Encoding UTF8

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# Activity census - $stamp")
[void]$md.Add("")
[void]$md.Add("Read-only. Nothing was written to LeadSquared or Supabase.")
[void]$md.Add("")
[void]$md.Add("Catalogue source: ``$catalogueSource`` ($($catalogue.Count) types)")
[void]$md.Add("")
[void]$md.Add("| | |")
[void]$md.Add("|---|---|")
[void]$md.Add("| Book scanned | $total |")
[void]$md.Add("| Workable (Fresh/Engaged/Prospect) | $workable |")
[void]$md.Add("| Touched since $TouchedSince | $touchedSinceCount |")
[void]$md.Add("| Non-call last activity | $seenNonCall |")
[void]$md.Add("| Stratum 1 sampled | $($s1.Sampled) |")
[void]$md.Add("| Stratum 2 sampled | $($s2.Sampled) |")
[void]$md.Add("")
[void]$md.Add("## Last activity across the WHOLE book (complete population)")
[void]$md.Add("")
[void]$md.Add("A lower bound: the field holds one value, so a type that never lands last is invisible here.")
[void]$md.Add("")
[void]$md.Add("| Last activity | Leads |")
[void]$md.Add("|---|---|")
$nameTally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    [void]$md.Add("| $($_.Name) | $($_.Value) |")
}
[void]$md.Add("")
[void]$md.Add("## Stratum 1 - uniform sample of the whole book")
[void]$md.Add("")
[void]$md.Add("**This is the only stratum an account-wide rate may be read from.**")
[void]$md.Add("")
[void]$md.Add("| Code | Name | Events | Leads | % leads | Actors | Proposed channel | Touch |")
[void]$md.Add("|---|---|---|---|---|---|---|---|")
foreach ($r in ($rows1 | Sort-Object Events -Descending)) {
    [void]$md.Add("| $($r.EventCode) | $($r.EventName) | $($r.Events) | $($r.Leads) | $($r.PctOfSampledLeads)% | $($r.Actors) | $($r.ProposedChannel) | $($r.ProposedIsTouch) |")
}
[void]$md.Add("")
[void]$md.Add("## Stratum 2 - over-samples non-call leads")
[void]$md.Add("")
[void]$md.Add("**Biased by construction. Answers what a channel looks like, never how common it is.**")
[void]$md.Add("")
[void]$md.Add("| Code | Name | Events | Leads | Actors | Proposed channel |")
[void]$md.Add("|---|---|---|---|---|---|")
foreach ($r in ($rows2 | Sort-Object Events -Descending)) {
    [void]$md.Add("| $($r.EventCode) | $($r.EventName) | $($r.Events) | $($r.Leads) | $($r.Actors) | $($r.ProposedChannel) |")
}
[void]$md.Add("")
[void]$md.Add("## Money on activities 204 / 205 / 206")
[void]$md.Add("")
[void]$md.Add("- Activities seen: **$($allMoney.Count)**")
[void]$md.Add("- Carrying a non-zero amount: **$($withAmount.Count)**")
[void]$md.Add("")
if ($withAmount.Count -gt 0) {
    [void]$md.Add("Money **is** logged on activities. Value-weighted conversion is reachable without")
    [void]$md.Add("waiting for the Opportunity forecast fields to be filled.")
} else {
    [void]$md.Add("No amounts found in this sample. ICP and funnel analysis stays count-based.")
}
[void]$md.Add("")
[void]$md.Add("## Unmapped types needing a decision")
[void]$md.Add("")
$unmapped = @((@($rows1) + @($rows2)) | Where-Object { $_.ProposedChannel -eq "unmapped" })
if ($unmapped.Count -eq 0) {
    [void]$md.Add("None - every observed type classified.")
} else {
    [void]$md.Add("| Code | Name | Events | In catalogue |")
    [void]$md.Add("|---|---|---|---|")
    foreach ($r in $unmapped) {
        [void]$md.Add("| $($r.EventCode) | $($r.EventName) | $($r.Events) | $($r.InCatalogue) |")
    }
}
[void]$md.Add("")
[void]$md.Add("## Backfill pricing")
[void]$md.Add("")
[void]$md.Add("| Scope | API calls | Nights at 8,000/day |")
[void]$md.Add("|---|---|---|")
[void]$md.Add("| Whole book | $total | $([math]::Ceiling($total / 8000.0)) |")
[void]$md.Add("| Workable book | $workable | $([math]::Ceiling($workable / 8000.0)) |")
[void]$md.Add("| Touched since $TouchedSince | $touchedSinceCount | $([math]::Ceiling($touchedSinceCount / 8000.0)) |")
[void]$md.Add("| Non-call last activity only | $seenNonCall | $([math]::Ceiling($seenNonCall / 8000.0)) |")
[void]$md.Add("")
[void]$md.Add("$share% of stratum-1 leads hold at least one non-call channel activity.")

($md.ToArray() -join "`r`n") | Set-Content -Path $mdPath -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "Wrote:" $logPath
Write-LsqLog "  $jsonPath" $logPath
Write-LsqLog "  $mdPath" $logPath
Write-LsqLog "  $seedPath   (PROPOSED - review before applying)" $logPath
Write-LsqLog "Census complete." $logPath
