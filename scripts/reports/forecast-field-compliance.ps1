<#
.SYNOPSIS
  READ-ONLY: how many opportunities carry BOTH Expected Deal Size and Expected Closure Date,
  broken down by rep and by stage. The compliance check behind the forecast.

.DESCRIPTION
  Reps were asked to fill Expected Deal Size (mx_Custom_6) and Expected Closure Date
  (mx_Custom_8) on every opportunity they consider a prospect. This measures whether they
  have, and where the holes are.

  READS THE WAREHOUSE, NOT THE API. fact_opportunity is loaded from LeadSquared by
  scripts/pipeline/08-load-opportunity-details.ps1, which is the only source for these two
  fields (the activity trail carries neither, and GetOpportunitiesOfLead returns them
  unlabelled). This report is therefore only as fresh as that load, so it prints the load
  watermark at the top and REFUSES to report if the data is older than -MaxAgeHours. A
  compliance number computed on a stale snapshot understates every rep who filled the fields
  in yesterday, which is precisely the population the report exists to find.

  To refresh before running:
    powershell.exe -File scripts\pipeline\backfill.ps1 -DealStagesOnly        # find new deals
    powershell.exe -File scripts\pipeline\08-load-opportunity-details.ps1     # refresh fields

  COUNTING RULES:
    - A deal_value of 0 counts as MISSING, not as a filled-in zero. LSQ writes 0 into an
      untouched numeric field, so 0 and blank are indistinguishable in intent, and a zero-
      value deal is not forecastable either way. This matches opp_value_known() in the
      warehouse views.
    - Every opportunity is counted, including several on the same contact. The deal board
      view (v_opportunity_primary) shows one row per contact; that is right for a board and
      wrong here, because a rep has to fill in every deal they own, not just the best one.
    - Rep name resolves dim_rep.lsq_name -> dim_contact.owner_name -> raw owner id, so an
      opportunity is never silently dropped from the per-rep table.

  DELETED DEALS. An opportunity deleted in LeadSquared leaves its creation event in the
  activity trail forever, so fact_opportunity keeps a ghost row that no API call can refresh
  (GetOpportunityDetails answers HTTP 500 / "Opportunity does not exist"). 19 such rows were
  confirmed on 2026-08-12. They must not count against a rep - a deal that no longer exists
  cannot have its deal size filled in.

  They are identified WITHOUT a hardcoded id list, which would go stale the moment another
  deal is deleted: a full detail pass stamps details_loaded_at on every opportunity that
  still exists, so any row left behind at an older stamp is one the API refused. Rows more
  than -StaleGraceHours behind the newest stamp are reported separately as unverifiable and
  excluded from the denominator unless -IncludeUnverified is passed.

.PARAMETER MaxAgeHours
  Refuse to report if the newest details_loaded_at is older than this. Default 24.

.PARAMETER StaleGraceHours
  How far behind the newest details_loaded_at a row may sit and still count as verified.
  Default 6 - comfortably longer than a full pass (~18 min) and far shorter than a day.

.PARAMETER IncludeUnverified
  Count unrefreshable (almost certainly deleted) opportunities in the denominator anyway.

.PARAMETER Stage
  Restrict to one opportunity stage (e.g. "Prospect"). Default: all stages.

.PARAMETER OpenOnly
  Restrict to Status = Open. Won and Lost deals are included by default, since a closed deal
  that was never valued is a real reporting gap.

.EXAMPLE
  powershell.exe -File scripts\reports\forecast-field-compliance.ps1
  powershell.exe -File scripts\reports\forecast-field-compliance.ps1 -Stage Prospect
  powershell.exe -File scripts\reports\forecast-field-compliance.ps1 -OpenOnly

.NOTES
  ASCII only. Read-only: no LeadSquared writes, no Supabase writes.
#>

param(
    [int]$MaxAgeHours     = 24,
    [int]$StaleGraceHours = 6,
    [string]$Stage        = "",
    [switch]$OpenOnly,
    [switch]$SkipFreshnessCheck,
    [switch]$IncludeUnverified
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$cfg = Import-LsqConfig
foreach ($k in @("SUPABASE_URL","SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}
$sbUrl  = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey  = $cfg['SUPABASE_SERVICE_KEY']
$sbHead = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }

$dataDir = Join-Path $PSScriptRoot "..\..\data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$logPath = Join-Path $dataDir "forecast_compliance_log.txt"

# ---------------------------------------------------------------------------------------
# Paged fetch. PostgREST caps a response at 1000 rows and returns the first page with no
# error, so a single unpaged GET silently truncates - the exact failure hard rule 4 exists
# for. The expected total comes from the Content-Range header (an independent count computed
# server-side, not from the rows themselves) and is asserted after the loop.
# ---------------------------------------------------------------------------------------
function Get-SbCount {
    param([string]$Query)
    $sep = if ($Query -match '\?') { '&' } else { '?' }
    $h = $sbHead.Clone(); $h['Prefer'] = 'count=exact'
    $r = Invoke-WebRequest -Uri "$sbUrl/rest/v1/$Query$sep`limit=1" -Headers $h -UseBasicParsing
    $cr = "$($r.Headers['Content-Range'])"      # e.g. "0-0/1398"
    if ($cr -match '/(\d+)$') { return [int]$Matches[1] }
    throw "Could not read a row count from Content-Range '$cr'"
}

function Get-SbAll {
    param([string]$Query)
    $out = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $sep = if ($Query -match '\?') { '&' } else { '?' }
        $uri = "$sbUrl/rest/v1/$Query$sep" + "limit=1000&offset=$offset"
        $page = (Invoke-WebRequest -Uri $uri -Headers $sbHead -UseBasicParsing).Content | ConvertFrom-Json
        $n = @($page).Count
        if ($n -eq 0) { break }
        foreach ($r in $page) { [void]$out.Add($r) }
        if ($n -lt 1000) { break }
        $offset += 1000
    }
    return $out.ToArray()
}

Write-LsqLog "=== Forecast field compliance ===" $logPath

# ---------------------------------------------------------------------------------------
# Freshness gate.
# ---------------------------------------------------------------------------------------
$wm = (Invoke-WebRequest -UseBasicParsing -Headers $sbHead `
        -Uri "$sbUrl/rest/v1/fact_opportunity?select=details_loaded_at&order=details_loaded_at.desc.nullslast&limit=1").Content | ConvertFrom-Json
$loadedAt = $null
if ($wm.Count -gt 0 -and $wm[0].details_loaded_at) { $loadedAt = [datetime]$wm[0].details_loaded_at }

$neverLoaded = Get-SbCount "fact_opportunity?select=activity_id&details_loaded_at=is.null"

if ($null -eq $loadedAt) {
    throw "No opportunity has ever been detail-loaded. Run scripts\pipeline\08-load-opportunity-details.ps1 first."
}
$ageH = [Math]::Round(((Get-Date).ToUniversalTime() - $loadedAt.ToUniversalTime()).TotalHours, 1)
Write-LsqLog "Detail load watermark : $($loadedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC  (${ageH}h old)" $logPath
if ($neverLoaded -gt 0) {
    Write-LsqLog "WARNING: $neverLoaded opportunities have NEVER been detail-loaded and are counted as missing both fields." $logPath
}
if ($ageH -gt $MaxAgeHours -and -not $SkipFreshnessCheck) {
    throw ("Opportunity details are ${ageH}h old (limit ${MaxAgeHours}h). Anything a rep filled in since then is invisible.`n" +
           "  Refresh:  powershell.exe -File scripts\pipeline\backfill.ps1 -DealStagesOnly`n" +
           "            powershell.exe -File scripts\pipeline\08-load-opportunity-details.ps1`n" +
           "  Override: -SkipFreshnessCheck (states the age in the output)")
}

# ---------------------------------------------------------------------------------------
# Pull.
# ---------------------------------------------------------------------------------------
$sel = "activity_id,prospect_id,opportunity_name,stage,status,owner_id,deal_value,expected_close_date,created_at_utc,details_loaded_at"
$q   = "fact_opportunity?select=$sel&order=activity_id"
if ($Stage)   { $q += "&stage=eq." + [uri]::EscapeDataString($Stage) }
if ($OpenOnly) { $q += "&status=eq.Open" }

$expected = Get-SbCount $q
$opps     = Get-SbAll  $q
Write-LsqLog "Opportunities in scope : $($opps.Count) (server count $expected)" $logPath
if ($opps.Count -ne $expected) {
    throw "TRUNCATED SCAN: fetched $($opps.Count) but the server counted $expected. Not reporting on a partial read."
}
if ($opps.Count -eq 0) { Write-LsqLog "Nothing in scope." $logPath; return }

$reps = @{}
foreach ($r in (Get-SbAll "dim_rep?select=owner_id,lsq_name,team")) { $reps["$($r.owner_id)"] = $r }
$contacts = @{}
foreach ($c in (Get-SbAll "dim_contact?select=prospect_id,owner_name,company_name")) { $contacts["$($c.prospect_id)"] = $c }

# ---------------------------------------------------------------------------------------
# Classify.
# ---------------------------------------------------------------------------------------
$staleBefore = $loadedAt.ToUniversalTime().AddHours(-$StaleGraceHours)

$rows = New-Object System.Collections.Generic.List[object]
foreach ($o in $opps) {
    $ct = $contacts["$($o.prospect_id)"]

    # A row the last full pass could not refresh: the opportunity no longer exists in LSQ.
    $verified = $false
    if ($o.details_loaded_at) {
        $verified = ([datetime]$o.details_loaded_at).ToUniversalTime() -ge $staleBefore
    }

    $repName = $null
    if ($o.owner_id -and $reps.ContainsKey("$($o.owner_id)")) { $repName = "$($reps["$($o.owner_id)"].lsq_name)" }
    if (-not $repName -and $ct -and $ct.owner_name)           { $repName = "$($ct.owner_name)" }
    if (-not $repName -and $o.owner_id)                       { $repName = "$($o.owner_id)" }
    if (-not $repName)                                        { $repName = "<unassigned>" }

    # 0 is LSQ's untouched-numeric default and is not a forecastable value. See header.
    $hasValue = $false
    if ($null -ne $o.deal_value) {
        $dv = 0.0
        if ([double]::TryParse("$($o.deal_value)", [ref]$dv) -and $dv -gt 0) { $hasValue = $true }
    }
    $hasDate = ($null -ne $o.expected_close_date -and "$($o.expected_close_date)".Trim() -ne "")

    $state = if ($hasValue -and $hasDate) { "both" }
             elseif ($hasValue)           { "value only" }
             elseif ($hasDate)            { "date only" }
             else                         { "neither" }

    [void]$rows.Add([pscustomobject]@{
        rep           = $repName
        verified      = $verified
        team          = if ($o.owner_id -and $reps.ContainsKey("$($o.owner_id)")) { "$($reps["$($o.owner_id)"].team)" } else { "" }
        stage         = if ($o.stage)  { "$($o.stage)" }  else { "<blank>" }
        status        = if ($o.status) { "$($o.status)" } else { "<blank>" }
        company       = if ($ct) { "$($ct.company_name)" } else { "" }
        opportunity   = "$($o.opportunity_name)"
        deal_value    = $o.deal_value
        close_date    = $o.expected_close_date
        has_value     = $hasValue
        has_date      = $hasDate
        state         = $state
        created_at    = $o.created_at_utc
        prospect_id   = "$($o.prospect_id)"
        activity_id   = "$($o.activity_id)"
    })
}
$everything  = $rows.ToArray()
$unverified  = @($everything | Where-Object { -not $_.verified })
if ($IncludeUnverified) {
    $all = $everything
} else {
    $all = @($everything | Where-Object { $_.verified })
}
if ($all.Count -eq 0) { throw "Every row in scope is unverifiable. Re-run the detail load before reporting." }

function Write-Block {
    param([string]$Title, $Groups, [string]$KeyLabel)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("{0,-26} {1,6} {2,6} {3,7} {4,6} {5,6} {6,8}" -f `
        $KeyLabel, "opps", "both", "both %", "value", "date", "neither")
    Write-Host ("-" * 74)
    foreach ($g in $Groups) {
        $items   = $g.Group
        $n       = $items.Count
        $both    = @($items | Where-Object { $_.state -eq "both" }).Count
        $vOnly   = @($items | Where-Object { $_.state -eq "value only" }).Count
        $dOnly   = @($items | Where-Object { $_.state -eq "date only" }).Count
        $neither = @($items | Where-Object { $_.state -eq "neither" }).Count
        $pct     = if ($n -gt 0) { [Math]::Round(100.0 * $both / $n, 1) } else { 0 }
        Write-Host ("{0,-26} {1,6} {2,6} {3,6}% {4,6} {5,6} {6,8}" -f `
            $g.Name, $n, $both, $pct, $vOnly, $dOnly, $neither)
    }
}

$total   = $all.Count
$tBoth   = @($all | Where-Object { $_.state -eq "both" }).Count
$tValue  = @($all | Where-Object { $_.has_value }).Count
$tDate   = @($all | Where-Object { $_.has_date }).Count
$tNone   = @($all | Where-Object { $_.state -eq "neither" }).Count

Write-Host ""
Write-Host "=======================================================================" -ForegroundColor Yellow
Write-Host " FORECAST FIELD COMPLIANCE - Expected Deal Size + Expected Closure Date" -ForegroundColor Yellow
Write-Host "=======================================================================" -ForegroundColor Yellow
Write-Host (" Warehouse loaded  : {0} UTC ({1}h old)" -f $loadedAt.ToUniversalTime().ToString('yyyy-MM-dd HH:mm'), $ageH)
Write-Host (" Scope             : {0}{1}{2}" -f `
    "all stages/statuses", $(if ($Stage) { " | stage=$Stage" } else { "" }), $(if ($OpenOnly) { " | status=Open" } else { "" }))
Write-Host ""
Write-Host (" Opportunities            : {0}" -f $total)
Write-Host (" BOTH fields filled       : {0}  ({1}%)" -f $tBoth,  [Math]::Round(100.0*$tBoth/$total,1))
Write-Host (" Missing at least one     : {0}  ({1}%)" -f ($total-$tBoth), [Math]::Round(100.0*($total-$tBoth)/$total,1))
Write-Host ("   - has Deal Size        : {0}" -f $tValue)
Write-Host ("   - has Closure Date     : {0}" -f $tDate)
Write-Host ("   - has NEITHER          : {0}  ({1}%)" -f $tNone, [Math]::Round(100.0*$tNone/$total,1))

if ($unverified.Count -gt 0) {
    Write-Host ""
    if ($IncludeUnverified) {
        Write-Host (" NOTE: {0} of the above could not be refreshed from LSQ and are almost certainly" -f $unverified.Count) -ForegroundColor DarkYellow
        Write-Host ("       deleted deals. They are INCLUDED here because -IncludeUnverified was passed,") -ForegroundColor DarkYellow
        Write-Host ("       so they count against their rep. Drop the switch to exclude them.") -ForegroundColor DarkYellow
    } else {
        Write-Host (" EXCLUDED: {0} opportunities the last pass could not refresh - deleted in LSQ." -f $unverified.Count) -ForegroundColor DarkYellow
        Write-Host ("           They are ghost rows from the activity trail, not rep negligence.") -ForegroundColor DarkYellow
        Write-Host ("           Affected reps: {0}" -f (($unverified | Group-Object rep | Sort-Object Count -Descending |
                        ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ", ")) -ForegroundColor DarkYellow
    }
}

Write-Block "BY STAGE" (
    $all | Group-Object stage | Sort-Object { $_.Group.Count } -Descending
) "stage"

Write-Block "BY STATUS" (
    $all | Group-Object status | Sort-Object { $_.Group.Count } -Descending
) "status"

Write-Block "BY REP" (
    $all | Group-Object rep | Sort-Object { $_.Group.Count } -Descending
) "rep"

# ---------------------------------------------------------------------------------------
# Per-opportunity CSV so a rep can be handed their own worklist.
# ---------------------------------------------------------------------------------------
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$csv   = Join-Path $dataDir "forecast_compliance_$stamp.csv"
$all | Sort-Object rep, stage, company | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host ("Per-opportunity detail written to: {0}" -f $csv)

$gapCsv = Join-Path $dataDir "forecast_gaps_$stamp.csv"
@($all | Where-Object { $_.state -ne "both" }) | Sort-Object rep, stage, company |
    Export-Csv -Path $gapCsv -NoTypeInformation -Encoding UTF8
Write-Host ("Worklist of gaps only written to : {0}" -f $gapCsv)

Write-LsqLog "Total $total | both $tBoth | missing $($total-$tBoth)" $logPath
