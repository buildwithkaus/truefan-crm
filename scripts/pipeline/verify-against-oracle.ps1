<#
.SYNOPSIS
  Independently recount a day's calls straight from LeadSquared and reconcile against what
  the Supabase pipeline reports for the same day. Any mismatch is a pipeline defect.

.DESCRIPTION
  This is the most valuable check available, and it is nearly free to build, because a
  correct answer already exists: scripts/reports/calls-for-day.ps1 counts EventCode 22 by
  rep and predates this pipeline entirely. This script reimplements that count directly
  against the API - deliberately NOT reusing the pipeline's own normaliser - and diffs it
  against v_rep_day.

  An oracle that shares code with the thing it checks proves nothing. The only shared
  ingredient here is the raw API response.

  What a mismatch usually means:
    pipeline LOWER  - the webhook missed calls and the reconciler has not caught up, or a
                      lead was never queued at all
    pipeline HIGHER - double counting (would indicate the activity_id primary key is not
                      doing its job, which should be impossible - investigate hard)
    owner mismatch  - the lead was reassigned between the call and the pull, so is_owner_call
                      resolved differently. Expected occasionally; a pattern is not.

.EXAMPLE
  pwsh ./scripts/pipeline/verify-against-oracle.ps1
  pwsh ./scripts/pipeline/verify-against-oracle.ps1 -TargetDate 2026-08-07

.NOTES
  Read-only against both systems. ASCII only.
#>

[CmdletBinding()]
param(
    [string]$TargetDate = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd"),
    [int]$SleepMs = 250,
    [int]$Tolerance = 0
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "pipeline_oracle_log.txt"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-LsqLog "=== Oracle verification for $TargetDate (run $stamp) ===" $logPath

$cfg = Import-LsqConfig
foreach ($k in @("SUPABASE_URL", "SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}

# ---------------------------------------------------------------------------------------
# The IST day, expressed as a UTC window.
#
# LSQ stores UTC; the business runs on IST. A call at 23:45 IST is 18:15 UTC on the SAME
# date, but one at 02:00 IST is 20:30 UTC on the PREVIOUS date - so a UTC-date window
# silently misfiles exactly the late-evening calls a daily scorecard is judged on.
# ---------------------------------------------------------------------------------------
$dayIst = [datetime]::ParseExact($TargetDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
$dayStartUtc = $dayIst.AddHours(-5).AddMinutes(-30)
$dayEndUtc = $dayStartUtc.AddDays(1)
Write-LsqLog "IST day $TargetDate = UTC window [$($dayStartUtc.ToString('yyyy-MM-dd HH:mm:ss')), $($dayEndUtc.ToString('yyyy-MM-dd HH:mm:ss')))" $logPath

# ---------------------------------------------------------------------------------------
# SIDE A - count straight from LeadSquared.
# ---------------------------------------------------------------------------------------
$negRows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "ProspectActivityDate_Max"; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">"
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Write-LsqLog "Negative control: $($negRows.Count) rows -- must be 0" $logPath
if ($negRows.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - filter ignored, results untrustworthy." }

# Candidates: anything touched from the start of the target day onward. Deliberately does
# NOT exclude AI-dialler leads - the oracle must be able to see a rep call that the
# pipeline's own optimisation might have skipped. That is precisely what it is checking.
$since = $dayStartUtc.ToString("yyyy-MM-dd HH:mm:ss")
$cols = "ProspectID,OwnerId,OwnerIdName,ProspectActivityDate_Max,ProspectActivityName_Max"

$list = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "ProspectActivityDate_Max"; LookupValue = $since; SqlOperator = ">"
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }
    foreach ($r in $rows) { [void]$list.Add($r) }
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 100) { Write-LsqLog "  WARNING: stopped paging at 100 pages" $logPath; break }
}
$candidates = $list.ToArray()
Write-LsqLog "Candidates to scan: $($candidates.Count)" $logPath
if ($candidates.Count -eq 0) { throw "Zero candidates - refusing to report a clean reconciliation against nothing." }

function Get-OracleTally {
    <#
      PURE. Counts owner-attributed outbound calls per rep inside the UTC window.
      Returns a hashtable; writes nothing.

      A function that both logs and returns hands its caller the log lines bundled with the
      return value, because every unredirected output statement in a PowerShell function
      becomes part of what it returns. That has broken a script in this repo before, so the
      tally/report split is mandatory.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc,
        [Parameter(Mandatory)][hashtable]$Config,
        [int]$SleepMs = 250
    )
    $byRep = @{}
    $ok = 0; $failed = 0
    foreach ($lead in $Candidates) {
        try {
            $acts = Get-LeadActivities -ProspectId $lead.ProspectID -Config $Config
            $ok++
        } catch {
            $failed++
            continue
        }
        $ownerId = "$($lead.OwnerId)"
        $ownerName = "$($lead.OwnerIdName)"
        foreach ($a in $acts) {
            if ("$($a.EventCode)" -ne "22") { continue }
            $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
            if ($null -eq $when) { continue }
            if ($when -lt $StartUtc -or $when -ge $EndUtc) { continue }
            # Same attribution rule the pipeline uses, applied independently: credit the
            # call only when the dialler is also the lead's current owner.
            if ("$($a.ActivityFields.CreatedBy)" -ne $ownerId) { continue }

            if (-not $byRep.ContainsKey($ownerName)) {
                $byRep[$ownerName] = [pscustomobject]@{ Dials = 0; Connects = 0; Contacts = @{} }
            }
            $byRep[$ownerName].Dials++
            if ((Get-LsqCallDuration $a) -gt 0) { $byRep[$ownerName].Connects++ }
            $byRep[$ownerName].Contacts["$($lead.ProspectID)"] = $true
        }
        Start-Sleep -Milliseconds $SleepMs
    }
    return @{ ByRep = $byRep; Ok = $ok; Failed = $failed }
}

Write-LsqLog "Pulling trails (1 API call per lead)..." $logPath
$oracle = Get-OracleTally -Candidates $candidates -StartUtc $dayStartUtc -EndUtc $dayEndUtc -Config $cfg -SleepMs $SleepMs
Write-LsqLog "Trails fetched: $($oracle.Ok) ok, $($oracle.Failed) failed" $logPath
if ($oracle.Failed -gt [Math]::Max(5, $candidates.Count * 0.02)) {
    Write-LsqLog "WARNING: more than 2% of trail fetches failed. This comparison is NOT trustworthy." $logPath
}

# ---------------------------------------------------------------------------------------
# SIDE B - what the pipeline says.
#
# Read v_rep_day straight from Supabase. That is the SAME view the Sheet tabs and the Excel
# workbook are painted from, so this checks the numbers people actually read rather than a
# parallel calculation - while sharing no code at all with the counting logic above.
# ---------------------------------------------------------------------------------------
foreach ($k in @("SUPABASE_URL", "SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']
$reportUri = "$sbUrl/rest/v1/v_rep_day?select=rep,dials,connects,contacts&report_date=eq.$TargetDate"

$pipelineResp = Invoke-LsqWithRetry -What "v_rep_day" -Action {
    # Invoke-WebRequest + ConvertFrom-Json rather than Invoke-RestMethod: the latter has been
    # observed returning a PostgREST array nested one level deeper, which makes .Count read 1
    # and silently turns a full result set into a single row (gotcha 9, same failure family).
    (Invoke-WebRequest -Uri $reportUri -Headers @{ apikey = $sbKey; Authorization = "Bearer $sbKey" } `
        -Method Get -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
}

$pipelineByRep = @{}
foreach ($r in @($pipelineResp)) { if ($r.rep) { $pipelineByRep["$($r.rep)"] = $r } }
Write-LsqLog "Pipeline reports $($pipelineByRep.Count) reps for $TargetDate" $logPath

# ---------------------------------------------------------------------------------------
# Reconcile.
# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog ("{0,-24} {1,10} {2,10} {3,10} {4,10}  {5}" -f "Rep", "LSQ dials", "Pipe dials", "LSQ conn", "Pipe conn", "Verdict") $logPath
Write-LsqLog ("-" * 92) $logPath

$allReps = New-Object System.Collections.Generic.List[string]
foreach ($k in $oracle.ByRep.Keys) { [void]$allReps.Add($k) }
foreach ($k in $pipelineByRep.Keys) { if (-not $oracle.ByRep.ContainsKey($k)) { [void]$allReps.Add($k) } }

$mismatches = 0
$oracleTotal = 0; $pipelineTotal = 0

foreach ($rep in ($allReps.ToArray() | Sort-Object)) {
    $o = $oracle.ByRep[$rep]
    $p = $pipelineByRep[$rep]

    $oDials = if ($o) { $o.Dials } else { 0 }
    $oConn = if ($o) { $o.Connects } else { 0 }
    $pDials = if ($p) { [int]$p.dials } else { 0 }
    $pConn = if ($p) { [int]$p.connects } else { 0 }

    # A pipeline number of 0 against a non-zero oracle for a day BEFORE the webhook went
    # live is expected, not a defect - the webhook only captures forward. Flagged rather
    # than silently counted as a mismatch, so a pre-cutover date cannot read as a failure.

    $oracleTotal += $oDials
    $pipelineTotal += $pDials

    $delta = [Math]::Abs($oDials - $pDials)
    $verdict = if ($delta -le $Tolerance) { "OK" }
               elseif ($pDials -lt $oDials) { "PIPELINE LOW by $($oDials - $pDials)" }
               else { "PIPELINE HIGH by $($pDials - $oDials) -- investigate, PK should prevent this" }
    if ($delta -gt $Tolerance) { $mismatches++ }

    Write-LsqLog ("{0,-24} {1,10} {2,10} {3,10} {4,10}  {5}" -f $rep, $oDials, $pDials, $oConn, $pConn, $verdict) $logPath
}

Write-LsqLog ("-" * 92) $logPath
Write-LsqLog ("{0,-24} {1,10} {2,10}" -f "TOTAL", $oracleTotal, $pipelineTotal) $logPath
Write-LsqLog "" $logPath

if ($mismatches -eq 0 -and $oracleTotal -gt 0) {
    Write-LsqLog "RESULT: PASS - the pipeline matches an independent count of the live API, rep by rep." $logPath
} elseif ($oracleTotal -eq 0) {
    Write-LsqLog "RESULT: INCONCLUSIVE - the oracle found no owner-attributed calls on $TargetDate." $logPath
    Write-LsqLog "        Either nobody called that day, or the attribution rule is filtering everything." $logPath
    Write-LsqLog "        Do NOT read this as a pass." $logPath
} elseif ($pipelineTotal -eq 0) {
    Write-LsqLog "RESULT: NO PIPELINE DATA for $TargetDate." $logPath
    Write-LsqLog "        If this date is BEFORE the webhook went live (2026-08-08), that is expected -" $logPath
    Write-LsqLog "        the webhook only captures forward and there is no historical backfill." $logPath
    Write-LsqLog "        If it is after, the webhook has stopped: run" $logPath
    Write-LsqLog "          pwsh ./scripts/pipeline/01-manage-webhooks.ps1 -Action List" $logPath
    Write-LsqLog "        and check for 'DISABLED - 10 consecutive failures'." $logPath
} else {
    Write-LsqLog "RESULT: FAIL - $mismatches rep(s) disagree. The pipeline has a defect; do not publish these numbers." $logPath
    Write-LsqLog "        LOW pipeline  = missed ingestion. Check the webhook is enabled (-Action List), the" $logPath
    Write-LsqLog "        Unparsed tab is empty, and the Apps Script executions log has no failures." $logPath
    Write-LsqLog "        HIGH pipeline = duplicate rows, which the ActivityId dedupe should make impossible." $logPath
    Write-LsqLog "        Treat HIGH as urgent - it means every call count in the report is inflated." $logPath
}
Write-LsqLog "Log: $logPath" $logPath
