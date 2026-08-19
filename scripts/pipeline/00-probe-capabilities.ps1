<#
.SYNOPSIS
  Read-only capability probe. Run this BEFORE building anything on top of the pipeline.

.DESCRIPTION
  Answers, against the live account, the questions the pipeline design depends on. Nothing
  is written to LeadSquared and nothing is written to Supabase - this only reads and reports.

  Why a probe script exists at all: this project has twice reached a wrong conclusion by
  reading one documentation page instead of testing (a "no Add Opportunity action" false
  negative, and a "no automation possible" false negative). The standing rule is to probe
  the live API and to treat a ZERO result as needing a negative control just as much as a
  suspicious non-zero one.

  Probes:
    A. Bulk activity read/export endpoints. If any of these work, the whole pipeline gets
       dramatically cheaper - it is the difference between O(leads) and O(1) per day.
    B. Webhook CRUD API - would let webhooks be configured as code rather than by hand.
    C. Candidate-set sizing, so the real API budget is measured rather than assumed.
    D. Event-code census across a sample, so nothing relevant is being silently ignored.
    E. Phone-app sync coverage - stage changes with no telephony record behind them.

.EXAMPLE
  pwsh ./scripts/pipeline/00-probe-capabilities.ps1
  pwsh ./scripts/pipeline/00-probe-capabilities.ps1 -SampleLeads 60

.NOTES
  ASCII only (see CLAUDE.md - a non-ASCII character in a PS 5.1 double-quoted string can
  throw a cascading parse error that silently breaks the rest of the file).
#>

[CmdletBinding()]
param(
    [int]$SampleLeads = 40,
    [int]$SleepMs = 250
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "pipeline_probe_log.txt"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-LsqLog "=== Pipeline capability probe $stamp ===" $logPath

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# ---------------------------------------------------------------------------------------
# Helper: probe one endpoint and classify the result. Returns a plain object - no logging
# inside, because a function that both logs and returns hands its caller the log lines
# bundled with the return value (every unredirected output statement in a PowerShell
# function becomes part of what it returns). That bug has bitten this repo before.
# ---------------------------------------------------------------------------------------
function Test-LsqEndpoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = "POST",
        [string]$Body = "{}",
        [string]$QueryExtra = ""
    )
    $uri = "$base/$Path" + "?accessKey=$ak&secretKey=$sk$QueryExtra"
    try {
        $params = @{ Uri = $uri; Method = $Method; ContentType = "application/json"; ErrorAction = "Stop" }
        if ($Method -eq "POST") { $params["Body"] = $Body }
        $resp = Invoke-RestMethod @params
        $shape = if ($null -eq $resp) { "null" } else { ($resp.PSObject.Properties.Name -join ",") }
        if ($shape.Length -gt 90) { $shape = $shape.Substring(0, 90) + "..." }
        return [pscustomobject]@{ Path = $Path; Status = "200 OK"; Works = $true; Detail = $shape }
    } catch {
        $code = ""
        if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
        }
        # Log Exception.Message alongside any HTTP body - ErrorDetails.Message only exists
        # on HTTP-response exceptions, and logging only that is how a 100%-failure run once
        # produced entirely blank error messages.
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        if ($detail.Length -gt 90) { $detail = $detail.Substring(0, 90) + "..." }
        return [pscustomobject]@{
            Path = $Path
            Status = $(if ($code) { "HTTP $code" } else { "client error" })
            Works = $false
            Detail = $detail
        }
    }
}

function Write-ProbeResult {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$LogPath)
    $mark = if ($Result.Works) { "WORKS " } else { "  -   " }
    Write-LsqLog ("  {0} {1,-58} {2,-14} {3}" -f $mark, $Result.Path, $Result.Status, $Result.Detail) $LogPath
}

# =======================================================================================
# CONTROL. If this fails, nothing else in this run means anything.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- CONTROL (must return 200) ---" $logPath
$control = Test-LsqEndpoint -Path "LeadManagement.svc/LeadsMetaData.Get" -Method "GET"
Write-ProbeResult $control $logPath
if (-not $control.Works) {
    throw "CONTROL CALL FAILED - credentials, host or account access is broken. Every 404 below would be meaningless."
}

# =======================================================================================
# A. Bulk activity read / export.
#
# The pipeline currently costs one API call per lead because no bulk activity read is known
# to exist. Eight names were probed on 2026-07-28 and all 404'd, but LSQ's async export-job
# family was never tried and would change the cost model completely if it works.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- A. Bulk activity read / export (a WORKS here changes the architecture) ---" $logPath

$since = Get-LsqTimestamp ((Get-Date).AddDays(-1))
$searchBody = @{
    Parameter = @{ ActivityEvent = 22; FromDate = $since; ToDate = (Get-LsqTimestamp) }
    Paging    = @{ PageIndex = 1; PageSize = 10 }
} | ConvertTo-Json -Depth 5

$bulkCandidates = @(
    @{ Path = "ProspectActivity.svc/Activity/Retrieve/BySearchParameter"; Body = $searchBody }
    @{ Path = "ProspectActivity.svc/Activities/Get";                      Body = $searchBody }
    @{ Path = "ProspectActivity.svc/GetActivityDetails";                  Body = $searchBody }
    @{ Path = "ProspectActivity.svc/ActivityDetails.Get";                 Body = $searchBody }
    @{ Path = "ProspectActivity.svc/Activity.Get";                        Body = $searchBody }
    @{ Path = "v2/ProspectActivity.svc/Activity/Retrieve/BySearchParameter"; Body = $searchBody }
    @{ Path = "ProspectActivity.svc/Activity/Export";                     Body = $searchBody }
    @{ Path = "LeadManagement.svc/Leads/Export";                          Body = $searchBody }
    @{ Path = "LeadManagement.svc/Lead/Export";                           Body = $searchBody }
    @{ Path = "ProspectActivity.svc/Export/Create";                       Body = $searchBody }
    @{ Path = "BulkExport.svc/Activity/Create";                           Body = $searchBody }
    @{ Path = "DataExport.svc/Activity/Create";                           Body = $searchBody }
)
$bulkWorks = New-Object System.Collections.Generic.List[object]
foreach ($c in $bulkCandidates) {
    $r = Test-LsqEndpoint -Path $c.Path -Body $c.Body
    Write-ProbeResult $r $logPath
    if ($r.Works) { [void]$bulkWorks.Add($r) }
    Start-Sleep -Milliseconds $SleepMs
}

# =======================================================================================
# B. Webhook CRUD API. Documented as existing but never tested on this account.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- B. Webhook CRUD API (read-only probes) ---" $logPath
foreach ($p in @("Webhook.svc/Webhooks.Get", "Webhook.svc/Retrieve", "WebhookManagement.svc/Webhooks.Get")) {
    $r = Test-LsqEndpoint -Path $p -Method "GET"
    Write-ProbeResult $r $logPath
    Start-Sleep -Milliseconds $SleepMs
}

# =======================================================================================
# C. Candidate sizing. What does a day of activity actually cost in API calls?
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- C. Candidate sizing (the real API budget) ---" $logPath

# Negative control FIRST. A filter that silently returns everything, or silently returns
# nothing, must be caught here rather than believed downstream.
$negRows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "ProspectActivityName_Max"; LookupValue = "ZZ_NoSuchActivity_ZZ"; SqlOperator = "="
} -ColumnsCsv "ProspectID" -PageSize 100 -SortColumn "CreatedOn"))
Write-LsqLog "  negative control (bogus activity name): $($negRows.Count) rows -- must be 0" $logPath
if ($negRows.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - ProspectActivityName_Max filter is being ignored." }

$dayStart = Get-LsqTimestamp ((Get-Date).Date)
$cols = "ProspectID,OwnerId,OwnerIdName,ProspectStage,ProspectActivityDate_Max,ProspectActivityName_Max"

$candidates = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "ProspectActivityDate_Max"; LookupValue = $dayStart; SqlOperator = ">"
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }
    foreach ($r in $rows) { [void]$candidates.Add($r) }
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 60) { Write-LsqLog "  WARNING: stopped paging at 60 pages" $logPath; break }
}

$cand = $candidates.ToArray()
Write-LsqLog "  leads touched since $dayStart (UTC): $($cand.Count)" $logPath

function Get-NameTally {
    # Pure. Returns the tally; writes nothing.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $t = @{}
    foreach ($r in $Rows) {
        $v = "$($r.ProspectActivityName_Max)"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = "<BLANK>" }
        if ($t.ContainsKey($v)) { $t[$v]++ } else { $t[$v] = 1 }
    }
    return $t
}

$nameTally = Get-NameTally -Rows $cand
$sum = 0
Write-LsqLog "  breakdown by last activity:" $logPath
$nameTally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-LsqLog ("    {0,6}  [{1}]" -f $_.Value, $_.Name) $logPath
    $sum += $_.Value
}
Write-LsqLog "  reconcile: tally $sum vs scanned $($cand.Count) -- $(if ($sum -eq $cand.Count) { 'OK' } else { 'MISMATCH' })" $logPath

$aiCount = 0
if ($nameTally.ContainsKey($Script:AI_ACTIVITY_NAME)) { $aiCount = $nameTally[$Script:AI_ACTIVITY_NAME] }
$callCount = 0
foreach ($n in $Script:CallActivityNames) { if ($nameTally.ContainsKey($n)) { $callCount += $nameTally[$n] } }

Write-LsqLog "" $logPath
Write-LsqLog "  API BUDGET (cap is 10,000 calls/day):" $logPath
Write-LsqLog "    naive - one trail pull per touched lead      : $($cand.Count) calls" $logPath
Write-LsqLog "    excluding the Callkaro AI dialler            : $($cand.Count - $aiCount) calls (saves $aiCount)" $logPath
Write-LsqLog "    call-activity leads only                     : $callCount calls" $logPath

# =======================================================================================
# D. Event-code census. Confirms nothing relevant is being ignored by the normaliser.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- D. Event-code census over $SampleLeads sampled leads ---" $logPath

$sample = @($cand | Get-Random -Count ([Math]::Min($SampleLeads, $cand.Count)))
$codeTally = @{}
$sampled = 0; $failed = 0
foreach ($lead in $sample) {
    try {
        $acts = Get-LeadActivities -ProspectId $lead.ProspectID -Config $cfg
        $sampled++
        foreach ($a in $acts) {
            $k = "$($a.EventCode) | $($a.EventName)"
            if ($codeTally.ContainsKey($k)) { $codeTally[$k]++ } else { $codeTally[$k] = 1 }
        }
    } catch {
        $failed++
        Write-LsqLog "    trail fetch failed for $($lead.ProspectID): $($_.Exception.Message)" $logPath
    }
    Start-Sleep -Milliseconds $SleepMs
}
Write-LsqLog "  sampled $sampled leads ($failed failed)" $logPath
$codeTally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-LsqLog ("    {0,6}  {1}" -f $_.Value, $_.Name) $logPath
}

# =======================================================================================
# E. Phone-app sync coverage.
#
# Reps place calls from handsets and the sync to LSQ is known to be unreliable. This
# measures the gap directly: contacts whose stage moved today with no telephony record
# behind it. Turns a known anecdote into a number for the conversation with the LSQ team.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- E. Stage changes today with no call activity behind them ---" $logPath

$todayUtcStart = [datetime]::UtcNow.Date.AddHours(-5).AddMinutes(-30)  # midnight IST in UTC
$noTelephony = 0; $withTelephony = 0
foreach ($lead in $sample) {
    try {
        $acts = Get-LeadActivities -ProspectId $lead.ProspectID -Config $cfg
        $stagedToday = @($acts | Where-Object {
            "$($_.EventCode)" -eq $Script:EVENT_STAGE_CHANGE -and
            (ConvertFrom-LsqUtc "$($_.CreatedOn)") -ge $todayUtcStart
        })
        if ($stagedToday.Count -eq 0) { continue }
        $calledToday = @($acts | Where-Object {
            ("$($_.EventCode)" -eq $Script:EVENT_CALL_OUTBOUND -or "$($_.EventCode)" -eq $Script:EVENT_CALL_INBOUND) -and
            (ConvertFrom-LsqUtc "$($_.CreatedOn)") -ge $todayUtcStart
        })
        if ($calledToday.Count -eq 0) { $noTelephony++ } else { $withTelephony++ }
    } catch { }
    Start-Sleep -Milliseconds $SleepMs
}
Write-LsqLog "  stage-changed today WITH a call logged   : $withTelephony" $logPath
Write-LsqLog "  stage-changed today with NO call logged  : $noTelephony" $logPath
Write-LsqLog "  (the second number is either desk work without calling, or unsynced handset calls)" $logPath

# =======================================================================================
# Verdict
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "=== VERDICT ===" $logPath
if ($bulkWorks.Count -gt 0) {
    Write-LsqLog "  BULK ACTIVITY READ IS AVAILABLE - revisit the reconciler design before building:" $logPath
    foreach ($w in $bulkWorks) { Write-LsqLog "    $($w.Path)" $logPath }
} else {
    Write-LsqLog "  No bulk activity read. Per-lead trail pulls confirmed as the only option;" $logPath
    Write-LsqLog "  the watermark + AI-exclusion design in the reconciler is therefore required." $logPath
}
Write-LsqLog "  Daily budget needed with AI excluded: ~$($cand.Count - $aiCount) of 10,000 calls." $logPath
Write-LsqLog "" $logPath
Write-LsqLog "  STILL UNANSWERABLE FROM A SCRIPT (must be checked on-screen in the LSQ UI):" $logPath
Write-LsqLog "    1. Does an Automation with an Activity trigger fire when the TELEPHONY" $logPath
Write-LsqLog "       INTEGRATION creates an EventCode 22? This is the load-bearing unknown." $logPath
Write-LsqLog "    2. Is a Custom/Webhook action available on this plan tier?" $logPath
Write-LsqLog "    3. Can it send a custom header (decides header vs query-string secret)?" $logPath
Write-LsqLog "  The reconciler and its webhook_coverage_pct metric answer #1 empirically" $logPath
Write-LsqLog "  once the automation is live - see docs/CALLING_PIPELINE.md." $logPath
Write-LsqLog "" $logPath
Write-LsqLog "Probe complete. Log: $logPath" $logPath
