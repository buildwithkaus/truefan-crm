<#
.SYNOPSIS
  Five-level book-health workbook for ONE rep. Read-only against LeadSquared and Supabase.

.DESCRIPTION
  Answers "how healthy is this rep's book", which no single artefact did before: the pieces were
  spread across 03-snapshot-book.ps1 (stage by owner), icp-rep-compliance.ps1 (owner-attributed
  calls), opportunity-hygiene-audit.ps1 (deals) and v_book_health in the warehouse - and
  v_book_health reads dim_contact, which covers only the contacts the calling pipeline happened
  to enrich. This reads the rep's WHOLE book.

    L1  split across stages, call dispositions, disqualification reasons
    L2  call coverage (0 / 1 / 2-3 / 4-5 / 6+), staleness buckets, averages
    L3  prospects: does each one carry an opportunity, with a deal size and a closure date
    L4  disqualified: reason split, calls behind each decision, how many carry no reason
    L5  engaged: disposition split, disposition vs whether anyone actually connected

  WHAT COUNTS AS ACTIVITY. Only EventCode 22 (outbound) and 21 (inbound), and only where
  ActivityFields.CreatedBy equals the rep's OwnerId. Calls by a previous owner are inherited
  activity and are carried in a separate column, never in a rep metric. EventCode 208 (the
  Callkaro AI dialler) is excluded everywhere - it is a background system, not a person, and
  counting it manufactures coverage nobody worked.

  "Last activity date" therefore means the latest 21/22 by this rep. Contacts with none are
  reported as "never touched by owner" rather than as the stale tail of the distribution:
  folding the two together is the same inversion that made the most active reps look worst in
  the connected_no_progress bucket (gotcha 36).

  PREREQUISITE. Lifetime call history must be in fact_call for this rep's book, which
  fact_call does NOT have by default - it begins 2026-08-01, the day the webhook went live.
  Load it first, once per rep:

    powershell.exe -File scripts\pipeline\backfill.ps1 -OwnerId <guid> -FromDate 2000-01-01 -MaxApiCalls 2500

  The script asserts the coverage rather than trusting it, and refuses to write a workbook
  whose Level-2 numbers would be an artefact of a missing backfill.

.PARAMETER Rep
  LSQ OwnerIdName, e.g. "Abhishek Tripathi". Resolved to a GUID against dim_rep, once, and
  matched on the GUID thereafter - reference data once attached the wrong name to a real GUID
  and pulled 2,360 of another rep's leads into a migration (memory/04).

.EXAMPLE
  powershell.exe -File scripts\reports\rep-book-health.ps1 -Rep "Abhishek Tripathi"

.NOTES
  ASCII only. Roughly 2 + N(prospects) API calls; everything else comes from the warehouse.
#>

param(
    [Parameter(Mandatory)][string]$Rep,
    [string]$OwnerId = "",
    [string]$OutPath = "",
    [int]$StaleDays = 14,
    [switch]$SkipOpportunityDetail
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"
. "$PSScriptRoot\..\lib\xlsx.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "rep_book_health_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$safeRep = ($Rep -replace '[^A-Za-z0-9]+', '_').Trim('_')
if (-not $OutPath) { $OutPath = Join-Path $dataDir "book_health_${safeRep}_$stamp.xlsx" }

$cfg = Import-LsqConfig
foreach ($k in @("SUPABASE_URL", "SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']
$sbHead = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }

$now    = (Get-Date).ToUniversalTime()
$nowIst = $now.AddHours(5).AddMinutes(30)

Write-LsqLog "" $logPath
Write-LsqLog "=== Book health: $Rep ===" $logPath

# QC assertions accumulate here and land on their own sheet. A check whose result is only
# printed to a console nobody kept is not a check.
$qc = New-Object System.Collections.Generic.List[object]
function Add-Qc {
    param([string]$Check, [bool]$Pass, $Expected, $Actual, [string]$Note = "")
    [void]$qc.Add([pscustomobject]@{
        Check = $Check; Result = $(if ($Pass) { "PASS" } else { "FAIL" })
        Expected = "$Expected"; Actual = "$Actual"; Note = $Note
    })
    Write-LsqLog ("  [{0}] {1} (expected {2}, got {3})" -f $(if ($Pass) { "PASS" } else { "FAIL" }), $Check, $Expected, $Actual) $logPath
}

function Get-Sb {
    <#
      GET a PostgREST collection, always as an array. Paged, because PostgREST caps a response
      at 1,000 rows by default and a silently truncated read here would understate exactly the
      reps with the most call history.
    #>
    param([Parameter(Mandatory)][string]$Query)
    $out = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $sep = $(if ($Query.Contains("?")) { "&" } else { "?" })
        $uri = "$sbUrl/rest/v1/$Query${sep}limit=1000&offset=$offset"
        $resp = Invoke-LsqWithRetry -What "supabase GET" -Action {
            Invoke-WebRequest -Uri $uri -Headers $sbHead -UseBasicParsing -ErrorAction Stop
        }
        $rows = @(Expand-LsqRows ($resp.Content | ConvertFrom-Json))
        foreach ($r in $rows) { [void]$out.Add($r) }
        if ($rows.Count -lt 1000) { break }
        $offset += 1000
    }
    return $out.ToArray()
}

function Get-SbByProspects {
    <#
      Fetch $Table rows for a set of prospect ids, in batches. A single in.(...) filter holding
      1,869 GUIDs makes a URL no server will accept, and the failure mode is a 414 rather than
      a wrong number - but batching also keeps it working as books grow.
    #>
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Select,
        [Parameter(Mandatory)][string[]]$ProspectIds,
        [int]$BatchSize = 80
    )
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ProspectIds.Count; $i += $BatchSize) {
        $slice = $ProspectIds[$i..([Math]::Min($i + $BatchSize - 1, $ProspectIds.Count - 1))]
        $inList = ($slice -join ",")
        foreach ($r in (Get-Sb "${Table}?select=$Select&prospect_id=in.($inList)")) { [void]$out.Add($r) }
    }
    return $out.ToArray()
}

function ConvertFrom-IsoUtc {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or "$Value".Trim() -eq "") { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d }
    return $null
}

function Format-IstDate {
    param([AllowNull()]$D)
    if ($null -eq $D) { return "" }
    return ([datetime]$D).AddHours(5).AddMinutes(30).ToString("yyyy-MM-dd")
}

function Pct { param($n, $d) if (-not $d) { return 0.0 } return [math]::Round(100.0 * $n / $d, 1) }


# =======================================================================================
# PHASE A - resolve the rep to a GUID
# =======================================================================================
if (-not $OwnerId) {
    $repRows = @(Get-Sb ("dim_rep?select=owner_id,lsq_name,team,team_lead&lsq_name=eq." +
                         [uri]::EscapeDataString($Rep)))
    if ($repRows.Count -eq 0) { throw "No dim_rep row for '$Rep'. Check the exact LSQ OwnerIdName - it is not always the name people use (Shubham Kumar Tak is 'Subham Tak' in LSQ)." }
    if ($repRows.Count -gt 1) { throw "dim_rep has $($repRows.Count) rows for '$Rep'. Refusing to guess which GUID is meant." }
    $OwnerId = "$($repRows[0].owner_id)"
    $repTeam = "$($repRows[0].team)"
    $repLead = "$($repRows[0].team_lead)"
} else {
    $repTeam = ""; $repLead = ""
}
Write-LsqLog "Owner: $Rep -> $OwnerId" $logPath


# =======================================================================================
# PHASE B - the authoritative book, live from LeadSquared
#
# Live rather than dim_contact_book because the warehouse copy is a snapshot: it read 1,891
# contacts for this rep where the live book holds 1,869, the difference being reassignments
# since the last load. The live scan is also the independent size guard for everything below -
# a tally that reconciles against its own read reconciles just as well when the read was
# truncated after one page.
# =======================================================================================
$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "OwnerId"; LookupValue = "00000000-0000-0000-0000-000000000000"; SqlOperator = "="
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Add-Qc "Negative control: impossible OwnerId returns no rows" ($neg.Count -eq 0) 0 $neg.Count `
    "A filter that is silently ignored returns the whole account and looks like a finding."
if ($neg.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the OwnerId filter is being ignored." }

$cols = "ProspectID,FirstName,LastName,Company,OwnerId,OwnerIdName,ProspectStage," +
        "mx_Call_Disposition,mx_Disqualification_Reason,mx_Disqualification_Category," +
        "mx_Previous_Contact_Stage,Source,mx_Category,ProspectActivityDate_Max," +
        "ProspectActivityName_Max,CreatedOn,IsPrimaryContact,RelatedCompanyId"

$book = New-Object System.Collections.Generic.List[object]
$page = 1
$columnsChecked = $false
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "OwnerId"; LookupValue = $OwnerId; SqlOperator = "="
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }

    # Leads.Get silently returns FEWER columns rather than erroring on a name it does not know,
    # so a mistyped field would tally as 100% empty and read as a real finding about the rep.
    if (-not $columnsChecked) {
        $present = @($rows[0].PSObject.Properties.Name)
        $want = @("ProspectStage", "mx_Call_Disposition", "mx_Disqualification_Reason",
                  "mx_Previous_Contact_Stage", "ProspectActivityDate_Max", "IsPrimaryContact")
        $absent = @($want | Where-Object { $present -notcontains $_ })
        if ($absent.Count -gt 0) { throw "Leads.Get did not return: $($absent -join ', '). Fix the names before trusting anything." }
        $columnsChecked = $true
    }

    foreach ($r in $rows) { [void]$book.Add($r) }
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 200) { Write-LsqLog "  WARNING: stopped paging at 200" $logPath; break }
}
$book = $book.ToArray()
Write-LsqLog "Book: $($book.Count) contacts across $page pages" $logPath
if ($book.Count -eq 0) { throw "Empty book for $Rep - refusing to report a clean empty run." }

$wrongOwner = @($book | Where-Object { "$($_.OwnerId)" -ne $OwnerId }).Count
Add-Qc "Every scanned contact belongs to this owner" ($wrongOwner -eq 0) 0 $wrongOwner

$whCount = 0
$whRows = @(Get-Sb "dim_contact_book?select=prospect_id&owner_id=eq.$OwnerId")
$whCount = $whRows.Count
$drift = [math]::Abs($book.Count - $whCount)
Add-Qc "Live book size agrees with dim_contact_book" ($drift -le [math]::Max(50, [int](0.05 * $book.Count))) `
    "$whCount +/- 5%" $book.Count "Drift is reassignment since the last warehouse load, not an error."

$ids = @($book | ForEach-Object { "$($_.ProspectID)" })


# =======================================================================================
# PHASE C - lifetime activity, from the warehouse
# =======================================================================================
Write-LsqLog "Reading lifetime call history..." $logPath
$calls = Get-SbByProspects -Table "fact_call" -ProspectIds $ids `
    -Select "activity_id,prospect_id,event_code,direction,called_at_utc,actor_owner_id,status,duration_sec,connected"
Write-LsqLog "  fact_call rows for this book: $($calls.Count)" $logPath

# The backfill is the thing that makes Level 2 mean anything. Without it fact_call starts
# 2026-08-01 and "never called" silently means "not called this month" - which would report a
# diligent rep's June work as neglect. Assert the coverage instead of assuming it.
$earliest = $null
foreach ($c in $calls) {
    $d = ConvertFrom-IsoUtc $c.called_at_utc
    if ($null -ne $d -and ($null -eq $earliest -or $d -lt $earliest)) { $earliest = $d }
}
$webhookCutover = [datetime]::SpecifyKind([datetime]"2026-08-01T00:00:00", [System.DateTimeKind]::Utc)
$hasPreCutover = ($null -ne $earliest -and $earliest -lt $webhookCutover)
Add-Qc "Lifetime call history is loaded (pre-2026-08-01 calls present)" $hasPreCutover `
    "calls before 2026-08-01" (Format-IstDate $earliest) `
    "If FAIL, run backfill.ps1 -OwnerId $OwnerId -FromDate 2000-01-01 first."
if (-not $hasPreCutover) {
    throw "fact_call holds no calls before the 2026-08-01 webhook cutover for this book. Level 2 would be an artefact of the missing backfill. Run: powershell.exe -File scripts\pipeline\backfill.ps1 -OwnerId $OwnerId -FromDate 2000-01-01 -MaxApiCalls 2500"
}

$stages = Get-SbByProspects -Table "fact_stage_change" -ProspectIds $ids `
    -Select "prospect_id,changed_at_utc,previous_stage,current_stage,changed_by_name"
$opps = Get-SbByProspects -Table "fact_opportunity" -ProspectIds $ids `
    -Select "activity_id,prospect_id,opportunity_name,stage,status,owner_id,created_at_utc"
Write-LsqLog "  stage changes: $($stages.Count) | opportunities: $($opps.Count)" $logPath

# ---- per-contact aggregates -----------------------------------------------------------
$agg = @{}
foreach ($id in $ids) {
    $agg[$id] = [pscustomobject]@{
        OutOwner = 0; OutConn = 0; InOwner = 0; InConn = 0; TalkSec = 0
        ByOthers = 0; First = $null; Last = $null
        AnsweredMismatch = 0
    }
}
foreach ($c in $calls) {
    $pidKey = "$($c.prospect_id)"
    if (-not $agg.ContainsKey($pidKey)) { continue }
    $a = $agg[$pidKey]

    # The inherited-book rule. A call placed by whoever held this contact before is real work,
    # but it is not THIS rep's work, and crediting it makes coverage look like diligence.
    if ("$($c.actor_owner_id)" -ne $OwnerId) { $a.ByOthers++; continue }

    $dur = 0; [void][int]::TryParse("$($c.duration_sec)", [ref]$dur)
    $isConn = ($dur -gt 0)
    # Cross-check, reported rather than silently resolved: duration and Status have agreed on
    # every call observed so far, and a divergence is worth knowing about.
    $saysAnswered = ("$($c.status)".Trim() -eq "Answered")
    if ($isConn -ne $saysAnswered) { $a.AnsweredMismatch++ }

    if ("$($c.direction)" -eq "inbound") {
        $a.InOwner++; if ($isConn) { $a.InConn++ }
    } else {
        $a.OutOwner++; if ($isConn) { $a.OutConn++ }
    }
    $a.TalkSec += $dur

    $when = ConvertFrom-IsoUtc $c.called_at_utc
    if ($null -ne $when) {
        if ($null -eq $a.First -or $when -lt $a.First) { $a.First = $when }
        if ($null -eq $a.Last  -or $when -gt $a.Last)  { $a.Last  = $when }
    }
}

# Disqualified-at: the LAST transition INTO Disqualified. 3002 is present on nearly every
# contact because the July restructure bulk-wrote ProspectStage, so its mere existence proves
# nothing - only the transition itself is the decision.
$disqAt = @{}
foreach ($s in $stages) {
    if ("$($s.current_stage)".Trim() -ne "Disqualified") { continue }
    $when = ConvertFrom-IsoUtc $s.changed_at_utc
    if ($null -eq $when) { continue }
    $pidKey = "$($s.prospect_id)"
    if (-not $disqAt.ContainsKey($pidKey) -or $when -gt $disqAt[$pidKey].When) {
        $disqAt[$pidKey] = @{ When = $when; By = "$($s.changed_by_name)" }
    }
}

$oppByProspect = @{}
foreach ($o in $opps) {
    $pidKey = "$($o.prospect_id)"
    if (-not $oppByProspect.ContainsKey($pidKey)) { $oppByProspect[$pidKey] = New-Object System.Collections.Generic.List[object] }
    [void]$oppByProspect[$pidKey].Add($o)
}


# =======================================================================================
# PHASE D - live opportunity detail for every Prospect-stage contact
#
# GetOpportunityDetails, not GetOpportunitiesOfLead: the latter returns flat properties with no
# Fields[], and it lags its index badly enough to report 0 deals for a lead that demonstrably
# has one (gotchas 24, 25, 48). Existence comes from the EventCode 12000 trail, which is
# immediate and authoritative, via fact_opportunity.
# =======================================================================================
$prospects = @($book | Where-Object { "$($_.ProspectStage)" -eq "Prospect" })
$oppDetail = @{}
if (-not $SkipOpportunityDetail) {
    $toRead = New-Object System.Collections.Generic.List[string]
    foreach ($p in $prospects) {
        $pidKey = "$($p.ProspectID)"
        if ($oppByProspect.ContainsKey($pidKey)) {
            foreach ($o in $oppByProspect[$pidKey]) { [void]$toRead.Add("$($o.activity_id)") }
        }
    }
    Write-LsqLog "Reading $($toRead.Count) opportunity details live..." $logPath
    $failedOpp = 0
    foreach ($oid in $toRead) {
        try {
            $oppDetail[$oid] = Get-LsqOpportunityDetails -OpportunityId $oid -Config $cfg
        } catch {
            # A DELETED opportunity's detail read returns HTTP 500, not 404, and 500 is
            # classified transient - so this costs ~14s of retries before landing here.
            $failedOpp++
            Write-LsqLog "  opportunity detail FAILED $oid : $($_.Exception.Message)" $logPath
        }
        Start-Sleep -Milliseconds 250
    }
    Write-LsqLog "  read $($oppDetail.Count), failed $failedOpp" $logPath
}

function Get-OppField {
    param($Detail, [string]$Schema)
    if ($null -eq $Detail -or $null -eq $Detail.Fields) { return "" }
    if (-not $Detail.Fields.ContainsKey($Schema)) { return "" }
    return "$($Detail.Fields[$Schema].Value)".Trim()
}


# =======================================================================================
# PHASE E - derive the per-contact table
# =======================================================================================
$rowsOut = New-Object System.Collections.Generic.List[object]
foreach ($b in $book) {
    $pidKey = "$($b.ProspectID)"
    $a = $agg[$pidKey]
    $totalOwner = $a.OutOwner + $a.InOwner
    $daysSince = $null
    if ($null -ne $a.Last) { $daysSince = [math]::Floor(($now - $a.Last).TotalDays) }

    # Staleness. "Never touched by owner" is its own bucket, NOT the far end of the scale:
    # a contact nobody has dialled and a contact dialled three months ago are different
    # problems, and merging them buries the first inside the second.
    $stale = "Never touched by owner"
    if ($null -ne $daysSince) {
        if     ($daysSince -le 14) { $stale = "0-2 weeks" }
        elseif ($daysSince -le 30) { $stale = "2 weeks - 1 month" }
        elseif ($daysSince -le 60) { $stale = "1-2 months" }
        else                       { $stale = "2 months+" }
    }

    $attempts = $a.OutOwner
    $bucket = switch ($attempts) { 0 { "0 calls" } 1 { "1 call" } default {
        if ($attempts -le 3) { "2-3 calls" } elseif ($attempts -le 5) { "4-5 calls" } else { "6+ calls" } } }

    # .ToArray(), never @(...). Wrapping a List[object] in @() throws "Argument types do not
    # match" rather than converting it (gotcha 12).
    $oppList = @()
    if ($oppByProspect.ContainsKey($pidKey)) { $oppList = $oppByProspect[$pidKey].ToArray() }
    $oppId = ""; $oppName = ""; $oppStage = ""; $oppStatus = ""; $dealVal = ""; $closeDate = ""
    if ($oppList.Count -gt 0) {
        $o = $oppList[0]
        $oppId = "$($o.activity_id)"; $oppName = "$($o.opportunity_name)"
        $oppStage = "$($o.stage)"; $oppStatus = "$($o.status)"
        if ($oppDetail.ContainsKey($oppId)) {
            $d = $oppDetail[$oppId]
            if ($d.OppStage) { $oppStage = $d.OppStage }
            if ($d.Status)   { $oppStatus = $d.Status }
            $dealVal   = Get-OppField $d "mx_Custom_6"
            $closeDate = Get-OppField $d "mx_Custom_8"
        }
    }

    $dq = $null
    if ($disqAt.ContainsKey($pidKey)) { $dq = $disqAt[$pidKey] }

    [void]$rowsOut.Add([pscustomobject]@{
        ProspectId   = $pidKey
        Name         = ("$($b.FirstName) $($b.LastName)").Trim()
        Company      = "$($b.Company)"
        Stage        = "$($b.ProspectStage)"
        Disposition  = "$($b.mx_Call_Disposition)".Trim()
        DisqReason   = "$($b.mx_Disqualification_Reason)".Trim()
        DisqCategory = "$($b.mx_Disqualification_Category)".Trim()
        PrevStage    = "$($b.mx_Previous_Contact_Stage)".Trim()
        Source       = "$($b.Source)".Trim()
        Category     = "$($b.mx_Category)".Trim()
        IsPrimary    = $(if (Test-LsqTrue $b.IsPrimaryContact) { "Yes" } else { "No" })
        OutOwner     = [int]$a.OutOwner
        OutConn      = [int]$a.OutConn
        InOwner      = [int]$a.InOwner
        InConn       = [int]$a.InConn
        TotalOwner   = [int]$totalOwner
        TotalConn    = [int]($a.OutConn + $a.InConn)
        TalkMin      = [math]::Round($a.TalkSec / 60.0, 1)
        ByOthers     = [int]$a.ByOthers
        FirstCall    = (Format-IstDate $a.First)
        LastCall     = (Format-IstDate $a.Last)
        DaysSince    = $(if ($null -eq $daysSince) { "" } else { [int]$daysSince })
        StaleBucket  = $stale
        CallBucket   = $bucket
        HasOpp       = $(if ($oppList.Count -gt 0) { "Yes" } else { "No" })
        OppCount     = [int]$oppList.Count
        OppName      = $oppName
        OppStage     = $oppStage
        OppStatus    = $oppStatus
        DealValue    = $dealVal
        CloseDate    = $closeDate
        DisqAt       = (Format-IstDate $(if ($dq) { $dq.When } else { $null }))
        DisqBy       = $(if ($dq) { $dq.By } else { "" })
        LastActAny   = "$($b.ProspectActivityDate_Max)"
        LastActName  = "$($b.ProspectActivityName_Max)"
        AnsMismatch  = [int]$a.AnsweredMismatch
    })
}
$rowsOut = $rowsOut.ToArray()
$total = $rowsOut.Count


# =======================================================================================
# Tallies
# =======================================================================================
function Tally {
    param($Rows, [string]$Prop, [string]$BlankLabel = "(blank)")
    $h = @{}
    foreach ($r in $Rows) {
        $v = "$($r.$Prop)".Trim()
        if ($v -eq "") { $v = $BlankLabel }
        if ($h.ContainsKey($v)) { $h[$v]++ } else { $h[$v] = 1 }
    }
    return $h
}
function TallyRows {
    param($H, $Denom, [string[]]$Canonical = @(), [switch]$NoFlag)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in ($H.GetEnumerator() | Sort-Object Value -Descending)) {
        $flag = ""
        if (-not $NoFlag -and $Canonical.Count -gt 0 -and $e.Key -ne "(blank)") {
            if ($Canonical -notcontains $e.Key) { $flag = "NOT SELECTABLE - reps cannot filter this" }
        }
        [void]$out.Add(@($e.Key, [int]$e.Value, [double](Pct $e.Value $Denom), $flag))
    }
    return $out.ToArray()
}

$tStage = Tally $rowsOut "Stage"
$tDisp  = Tally $rowsOut "Disposition"
$disqRows = @($rowsOut | Where-Object { $_.Stage -eq "Disqualified" })
$engRows  = @($rowsOut | Where-Object { $_.Stage -eq "Engaged" })
$tReason = Tally $disqRows "DisqReason" "(no reason given)"

Add-Qc "Stage tally reconciles to the book" (($tStage.Values | Measure-Object -Sum).Sum -eq $total) $total (($tStage.Values | Measure-Object -Sum).Sum)
Add-Qc "Disposition tally reconciles to the book" (($tDisp.Values | Measure-Object -Sum).Sum -eq $total) $total (($tDisp.Values | Measure-Object -Sum).Sum)
Add-Qc "Disqualification-reason tally reconciles to the Disqualified count" `
    (($tReason.Values | Measure-Object -Sum).Sum -eq $disqRows.Count) $disqRows.Count (($tReason.Values | Measure-Object -Sum).Sum)

$offStage = @($tStage.Keys | Where-Object { $Script:ContactStages -notcontains $_ -and $_ -ne "(blank)" })
Add-Qc "All stage values are in the canonical taxonomy" ($offStage.Count -eq 0) 0 $offStage.Count `
    $(if ($offStage.Count) { "Off-taxonomy: " + ($offStage -join ", ") } else { "" })

$mismatch = ($rowsOut | Measure-Object -Property AnsMismatch -Sum).Sum
Add-Qc "Duration>0 agrees with Status='Answered'" ($mismatch -eq 0) 0 $mismatch `
    "Reported, not resolved - a divergence is itself a finding."

$oppOwnedElsewhere = 0
foreach ($p in $prospects) {
    $pidKey = "$($p.ProspectID)"
    if ($oppByProspect.ContainsKey($pidKey)) {
        foreach ($o in $oppByProspect[$pidKey]) { if ("$($o.owner_id)" -ne $OwnerId) { $oppOwnedElsewhere++ } }
    }
}

# ---- L2 aggregates ----
$callBucketOrder = @("0 calls", "1 call", "2-3 calls", "4-5 calls", "6+ calls")
$staleOrder = @("0-2 weeks", "2 weeks - 1 month", "1-2 months", "2 months+", "Never touched by owner")
$tBucket = Tally $rowsOut "CallBucket"
$tStale  = Tally $rowsOut "StaleBucket"

$worked      = @($rowsOut | Where-Object { $_.OutOwner -gt 0 })
$everConn    = @($rowsOut | Where-Object { $_.OutConn -gt 0 })
$sumOut      = ($rowsOut | Measure-Object -Property OutOwner -Sum).Sum
$sumOutConn  = ($rowsOut | Measure-Object -Property OutConn -Sum).Sum
$sumIn       = ($rowsOut | Measure-Object -Property InOwner -Sum).Sum
$sumInConn   = ($rowsOut | Measure-Object -Property InConn -Sum).Sum
$sumOthers   = ($rowsOut | Measure-Object -Property ByOthers -Sum).Sum


# =======================================================================================
# Sheets
# =======================================================================================
$sheets = New-Object System.Collections.Generic.List[object]

# ---- 1. Summary ----
$sum = New-Object System.Collections.Generic.List[object]
function S { param($k, $v, $note = "") [void]$sum.Add(@("$k", $v, "$note")) }
S "REP" $Rep
S "Owner GUID" $OwnerId
S "Team" $(if ($repTeam) { $repTeam } else { "(not set in dim_rep)" }) $(if ($repLead) { "Team lead: $repLead" } else { "dim_rep.team/team_lead are unpopulated - see migration 013 for the mapping" })
S "Generated (IST)" $nowIst.ToString("yyyy-MM-dd HH:mm")
S "" ""
S "LEVEL 1 - THE BOOK" ""
S "Contacts owned" ([int]$total) "Live from LeadSquared; dim_contact_book held $whCount"
foreach ($s in ($Script:ContactStages + $offStage)) {
    if ($tStage.ContainsKey($s)) { S "  $s" ([int]$tStage[$s]) (("{0}%" -f (Pct $tStage[$s] $total))) }
}
S "  Contacts with no disposition set" ([int]$(if ($tDisp.ContainsKey("(blank)")) { $tDisp["(blank)"] } else { 0 })) ""
S "" ""
S "LEVEL 2 - IS THE BOOK BEING WORKED" ""
S "Contacts this rep has never dialled" ([int]($total - $worked.Count)) (("{0}% of the book" -f (Pct ($total - $worked.Count) $total)))
S "Contacts dialled exactly once" ([int]$(if ($tBucket.ContainsKey("1 call")) { $tBucket["1 call"] } else { 0 })) ""
S "Contacts he has ever connected with" ([int]$everConn.Count) (("{0}% of the book" -f (Pct $everConn.Count $total)))
S "Outbound calls by this rep (lifetime)" ([int]$sumOut) ""
S "  of which connected" ([int]$sumOutConn) (("{0}% connect rate" -f (Pct $sumOutConn $sumOut)))
S "Inbound calls to this rep" ([int]$sumIn) ("$sumInConn connected")
S "Calls on his book by OTHER owners" ([int]$sumOthers) "Inherited activity - never counted as his work"
S "Avg connected outbound PER CONTACT" ([double][math]::Round($sumOutConn / [double]$total, 2)) "Denominator: whole book"
S "Avg connected outbound PER DIALLED CONTACT" ([double]$(if ($worked.Count) { [math]::Round($sumOutConn / [double]$worked.Count, 2) } else { 0 })) "Denominator: contacts he actually dialled"
S "Avg outbound attempts per dialled contact" ([double]$(if ($worked.Count) { [math]::Round($sumOut / [double]$worked.Count, 2) } else { 0 })) ""
S "" ""
S "LEVEL 3 - PROSPECTS" ""
S "Contacts at Prospect stage" ([int]$prospects.Count) ""
$pWith = @($prospects | Where-Object { $oppByProspect.ContainsKey("$($_.ProspectID)") }).Count
S "  with an opportunity" ([int]$pWith) (("{0}%" -f (Pct $pWith $prospects.Count)))
S "  with NO opportunity" ([int]($prospects.Count - $pWith)) "A prospect with no deal is invisible to the pipeline"
$prospRows = @($rowsOut | Where-Object { $_.Stage -eq "Prospect" })
$withVal = @($prospRows | Where-Object { Test-LsqForecastValue $_.DealValue }).Count
$withDate = @($prospRows | Where-Object { Test-LsqForecastDate $_.CloseDate }).Count
S "  with an expected deal size" ([int]$withVal) "0 counts as unfilled - it is LSQ's untouched-numeric default"
S "  with an expected closure date" ([int]$withDate) ""
S "" ""
S "LEVEL 4 - DISQUALIFIED" ""
S "Disqualified contacts" ([int]$disqRows.Count) (("{0}% of the book" -f (Pct $disqRows.Count $total)))
$noReason = @($disqRows | Where-Object { $_.DisqReason -eq "" }).Count
S "  with NO reason recorded" ([int]$noReason) (("{0}% of disqualifications" -f (Pct $noReason $disqRows.Count)))
$disqNoCall = @($disqRows | Where-Object { $_.OutOwner -eq 0 }).Count
S "  he never dialled" ([int]$disqNoCall) "Written off without this rep calling"
$disqNoConn = @($disqRows | Where-Object { $_.OutConn -eq 0 }).Count
S "  he never connected with" ([int]$disqNoConn) "No conversation behind the decision"
S "" ""
S "LEVEL 5 - ENGAGED" ""
S "Engaged contacts" ([int]$engRows.Count) (("{0}% of the book" -f (Pct $engRows.Count $total)))
$engNoDisp = @($engRows | Where-Object { $_.Disposition -eq "" }).Count
S "  carrying no call disposition" ([int]$engNoDisp) (("{0}%" -f (Pct $engNoDisp $engRows.Count)))
$engStale = @($engRows | Where-Object { $_.StaleBucket -eq "2 months+" -or $_.StaleBucket -eq "1-2 months" }).Count
S "  last dialled over a month ago" ([int]$engStale) ""
$engNever = @($engRows | Where-Object { $_.OutOwner -eq 0 }).Count
S "  he has never dialled" ([int]$engNever) "Engaged means someone was reached - but not by him"
S "" ""
S "HOW TO READ THIS" ""
S "Activity = EventCode 22/21 only" "" "Callkaro (208) is a bot and is excluded everywhere"
S "Attribution = CreatedBy equals this owner" "" "Calls by a previous owner sit in 'By others'"
S "Last activity = his latest call" "" "Not ProspectActivityDate_Max, which any system write moves"
S "Disqualification reasons are mostly migration artifacts" "" "96.7% account-wide are a rename of the legacy stage - see the L4 sheet's Previous Stage split"
S "'Did Not Pick' is applied to calls that connected" "" "The L5 sheet cross-tabs disposition against whether anyone actually connected"
[void]$sheets.Add(@{ Name = "Summary"; Headers = @("Metric", "Value", "Note"); Rows = $sum.ToArray(); ColWidths = @(46, 16, 62) })

# ---- 2/3/4. L1 splits ----
[void]$sheets.Add(@{ Name = "L1 Stages"; Headers = @("Contact Stage", "Contacts", "% of book", "Flag")
    Rows = (TallyRows $tStage $total $Script:ContactStages); ColWidths = @(30, 12, 12, 46) })
[void]$sheets.Add(@{ Name = "L1 Dispositions"; Headers = @("Call Disposition", "Contacts", "% of book", "Flag")
    Rows = (TallyRows $tDisp $total $Script:CallDispositions); ColWidths = @(38, 12, 12, 46) })
[void]$sheets.Add(@{ Name = "L1 Disq reasons"; Headers = @("Disqualification Reason", "Contacts", "% of disqualified", "Flag")
    Rows = (TallyRows $tReason $disqRows.Count @() -NoFlag); ColWidths = @(42, 12, 18, 30) })

# ---- 5. L2 Activity ----
$l2 = New-Object System.Collections.Generic.List[object]
function L2 { param($a, $b, $c = "") [void]$l2.Add(@("$a", $b, "$c")) }
L2 "OUTBOUND ATTEMPTS PER CONTACT (by this rep, lifetime)" "" ""
foreach ($k in $callBucketOrder) {
    $v = $(if ($tBucket.ContainsKey($k)) { $tBucket[$k] } else { 0 })
    L2 "  $k" ([int]$v) (("{0}% of book" -f (Pct $v $total)))
}
L2 "" "" ""
L2 "TIME SINCE HIS LAST CALL" "" ""
foreach ($k in $staleOrder) {
    $v = $(if ($tStale.ContainsKey($k)) { $tStale[$k] } else { 0 })
    L2 "  $k" ([int]$v) (("{0}% of book" -f (Pct $v $total)))
}
L2 "" "" ""
L2 "VOLUME" "" ""
L2 "  Outbound calls (lifetime)" ([int]$sumOut) ""
L2 "  Outbound connected" ([int]$sumOutConn) (("{0}% connect rate" -f (Pct $sumOutConn $sumOut)))
L2 "  Inbound calls" ([int]$sumIn) ""
L2 "  Inbound connected" ([int]$sumInConn) ""
L2 "  Talk time (hours)" ([double][math]::Round((($rowsOut | Measure-Object -Property TalkMin -Sum).Sum) / 60.0, 1)) ""
L2 "  Calls by other owners on his book" ([int]$sumOthers) "Inherited - excluded from every metric above"
L2 "" "" ""
L2 "AVERAGES - BOTH DENOMINATORS" "" "Which one you use changes the answer several-fold"
L2 "  Connected outbound per contact (whole book)" ([double][math]::Round($sumOutConn / [double]$total, 2)) "n=$total"
L2 "  Connected outbound per DIALLED contact" ([double]$(if ($worked.Count) { [math]::Round($sumOutConn / [double]$worked.Count, 2) } else { 0 })) "n=$($worked.Count)"
L2 "  Attempts per contact (whole book)" ([double][math]::Round($sumOut / [double]$total, 2)) "n=$total"
L2 "  Attempts per DIALLED contact" ([double]$(if ($worked.Count) { [math]::Round($sumOut / [double]$worked.Count, 2) } else { 0 })) "n=$($worked.Count)"
[void]$sheets.Add(@{ Name = "L2 Activity"; Headers = @("Measure", "Value", "Note"); Rows = $l2.ToArray(); ColWidths = @(52, 14, 46) })

# ---- 6. L3 Prospects ----
$pRows = @($prospRows | Sort-Object { $_.HasOpp }, { -1 * $_.OutConn } | ForEach-Object {
    $gaps = New-Object System.Collections.Generic.List[string]
    if ($_.HasOpp -eq "No") { [void]$gaps.Add("no opportunity") }
    if ($_.HasOpp -eq "Yes" -and -not (Test-LsqForecastValue $_.DealValue)) { [void]$gaps.Add("no deal size") }
    if ($_.HasOpp -eq "Yes" -and -not (Test-LsqForecastDate $_.CloseDate)) { [void]$gaps.Add("no closure date") }
    if ($_.IsPrimary -eq "No" -and $_.HasOpp -eq "Yes") { [void]$gaps.Add("deal on a non-primary contact") }
    if ($_.OutConn -eq 0) { [void]$gaps.Add("never connected") }
    if ($_.OppCount -gt 1) { [void]$gaps.Add("$($_.OppCount) deals - fragmented account") }
    ,@($_.Company, $_.Name, $_.HasOpp, $_.OppStage, $_.OppStatus, $_.DealValue, $_.CloseDate,
       $_.OutOwner, $_.OutConn, $_.InOwner, $_.InConn, $_.LastCall, $_.DaysSince, $_.IsPrimary,
       ($gaps -join "; ")) })
[void]$sheets.Add(@{ Name = "L3 Prospects"
    Headers = @("Company", "Contact", "Has opp", "Deal stage", "Status", "Expected deal size",
                "Expected closure", "Out calls", "Out connected", "In calls", "In connected",
                "Last call", "Days since", "Primary", "Gaps")
    Rows = $pRows; ColWidths = @(34, 22, 9, 20, 10, 18, 17, 10, 13, 9, 12, 12, 11, 9, 44) })

# ---- 7. L4 Disqualified ----
$dRows = @($disqRows | Sort-Object DisqReason, { -1 * $_.OutOwner } | ForEach-Object {
    ,@($_.Company, $_.Name, $(if ($_.DisqReason) { $_.DisqReason } else { "(no reason given)" }),
       $_.DisqCategory, $_.PrevStage, $_.OutOwner, $_.OutConn, $_.InOwner, $_.TalkMin,
       $_.LastCall, $_.DisqAt, $_.DisqBy, $_.Disposition) })
[void]$sheets.Add(@{ Name = "L4 Disqualified"
    Headers = @("Company", "Contact", "Disqualification reason", "Category", "Previous stage",
                "Out calls", "Out connected", "In calls", "Talk min", "Last call",
                "Disqualified on", "Disqualified by", "Disposition")
    Rows = $dRows; ColWidths = @(34, 22, 36, 24, 26, 10, 13, 9, 10, 12, 15, 22, 26) })

# Reason x evidence. The question "why don't they buy" is only answerable where somebody
# actually spoke to the contact; the rest measures how the migration ran.
$dSum = New-Object System.Collections.Generic.List[object]
foreach ($e in ($tReason.GetEnumerator() | Sort-Object Value -Descending)) {
    $sel = @($disqRows | Where-Object { $(if ($_.DisqReason) { $_.DisqReason } else { "(no reason given)" }) -eq $e.Key })
    $nc = @($sel | Where-Object { $_.OutOwner -eq 0 }).Count
    $nconn = @($sel | Where-Object { $_.OutConn -eq 0 }).Count
    $legacy = @($sel | Where-Object { $_.PrevStage -ne "" }).Count
    [void]$dSum.Add(@($e.Key, [int]$e.Value, [double](Pct $e.Value $disqRows.Count), [int]$nc,
        [int]$nconn, [double](Pct $nconn $sel.Count), [int]$legacy,
        [double]([math]::Round((($sel | Measure-Object -Property OutOwner -Average).Average), 2))))
}
[void]$sheets.Add(@{ Name = "L4 Reason summary"
    Headers = @("Reason", "Contacts", "% of disq", "Never dialled", "Never connected",
                "% never connected", "Carries a previous stage", "Avg attempts")
    Rows = $dSum.ToArray(); ColWidths = @(42, 11, 11, 14, 16, 18, 24, 13) })

# ---- 8. L5 Engaged ----
$eRows = @($engRows | Sort-Object Disposition, { -1 * $_.OutOwner } | ForEach-Object {
    ,@($_.Company, $_.Name, $(if ($_.Disposition) { $_.Disposition } else { "(none set)" }),
       $_.OutOwner, $_.OutConn, $_.InOwner, $_.TalkMin, $_.LastCall, $_.DaysSince,
       $_.StaleBucket, $_.CallBucket) })
[void]$sheets.Add(@{ Name = "L5 Engaged"
    Headers = @("Company", "Contact", "Call disposition", "Out calls", "Out connected", "In calls",
                "Talk min", "Last call", "Days since", "Staleness", "Attempts")
    Rows = $eRows; ColWidths = @(34, 22, 34, 10, 13, 9, 10, 12, 11, 22, 12) })

# Disposition x reality. A disposition claiming nobody picked up, on a contact that connected,
# is worse than a blank field - it reads as a settled fact.
$eDisp = Tally $engRows "Disposition" "(none set)"
$eSum = New-Object System.Collections.Generic.List[object]
foreach ($e in ($eDisp.GetEnumerator() | Sort-Object Value -Descending)) {
    $sel = @($engRows | Where-Object { $(if ($_.Disposition) { $_.Disposition } else { "(none set)" }) -eq $e.Key })
    $conn = @($sel | Where-Object { $_.OutConn -gt 0 }).Count
    $never = @($sel | Where-Object { $_.OutOwner -eq 0 }).Count
    $fresh = @($sel | Where-Object { $_.StaleBucket -eq "0-2 weeks" }).Count
    $old = @($sel | Where-Object { $_.StaleBucket -eq "1-2 months" -or $_.StaleBucket -eq "2 months+" }).Count
    $flag = ""
    if ($Script:CallDispositions -notcontains $e.Key -and $e.Key -ne "(none set)") { $flag = "NOT SELECTABLE" }
    if ($Script:NoContactDispositions -contains $e.Key -and $conn -gt 0) {
        $flag = ($flag + " | $conn of these DID connect").Trim(" |")
    }
    [void]$eSum.Add(@($e.Key, [int]$e.Value, [double](Pct $e.Value $engRows.Count), [int]$conn,
        [int]$never, [int]$fresh, [int]$old, $flag))
}
[void]$sheets.Add(@{ Name = "L5 Disposition check"
    Headers = @("Call disposition", "Contacts", "% of engaged", "Ever connected", "Never dialled",
                "Called <2wk ago", "Called >1mo ago", "Flag")
    Rows = $eSum.ToArray(); ColWidths = @(36, 11, 13, 15, 14, 16, 16, 40) })

# ---- 9. Contacts ----
$allRows = @($rowsOut | Sort-Object Stage, Company | ForEach-Object {
    ,@($_.ProspectId, $_.Company, $_.Name, $_.Stage, $_.Disposition, $_.DisqReason, $_.DisqCategory,
       $_.PrevStage, $_.Source, $_.Category, $_.IsPrimary, $_.OutOwner, $_.OutConn, $_.InOwner,
       $_.InConn, $_.TotalOwner, $_.TotalConn, $_.TalkMin, $_.ByOthers, $_.FirstCall, $_.LastCall,
       $_.DaysSince, $_.StaleBucket, $_.CallBucket, $_.HasOpp, $_.OppStage, $_.OppStatus,
       $_.DealValue, $_.CloseDate, $_.DisqAt, $_.DisqBy, $_.LastActAny, $_.LastActName) })
[void]$sheets.Add(@{ Name = "Contacts"
    Headers = @("ProspectId", "Company", "Contact", "Stage", "Disposition", "Disq reason",
                "Disq category", "Previous stage", "Source", "Category", "Primary", "Out calls",
                "Out connected", "In calls", "In connected", "Total calls", "Total connected",
                "Talk min", "By other owners", "First call", "Last call", "Days since",
                "Staleness", "Attempts", "Has opp", "Deal stage", "Deal status",
                "Expected deal size", "Expected closure", "Disqualified on", "Disqualified by",
                "Last activity (any)", "Last activity name")
    Rows = $allRows; ColWidths = @(38, 34, 22, 16, 30, 36, 24, 26, 22, 22, 9, 10, 13, 9, 12, 11,
                                   15, 10, 15, 12, 12, 11, 22, 12, 9, 20, 11, 18, 17, 15, 22, 21, 28) })

# ---- 10. QC ----
Add-Qc "Opportunities on his prospects are owned by him" ($oppOwnedElsewhere -eq 0) 0 $oppOwnedElsewhere `
    "A deal owned by someone else on a contact he owns is a split account."
[void]$sheets.Add(@{ Name = "QC"; Headers = @("Check", "Result", "Expected", "Actual", "Note")
    Rows = @($qc | ForEach-Object { ,@($_.Check, $_.Result, $_.Expected, $_.Actual, $_.Note) })
    ColWidths = @(58, 9, 22, 16, 70) })


New-XlsxWorkbook -Sheets $sheets.ToArray() -Path $OutPath | Out-Null

$failed = @($qc | Where-Object { $_.Result -eq "FAIL" })
Write-LsqLog "" $logPath
Write-LsqLog "Wrote $OutPath" $logPath
Write-LsqLog "  $total contacts | $($qc.Count) QC checks, $($failed.Count) failed" $logPath
if ($failed.Count -gt 0) {
    Write-LsqLog "  FAILED CHECKS - read the QC sheet before quoting any number:" $logPath
    foreach ($f in $failed) { Write-LsqLog "    - $($f.Check): expected $($f.Expected), got $($f.Actual)" $logPath }
}
Write-Output $OutPath
