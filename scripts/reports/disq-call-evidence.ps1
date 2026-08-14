<#
.SYNOPSIS
  READ-ONLY. Builds the two cohorts needed to answer "what happened on the call that actually
  got the lead disqualified" - not "what happened on some call to a lead that is now
  disqualified", which is a different and much weaker question.

.DESCRIPTION
  Supersedes the 2026-08-13 transcript read, which was wrong: it analysed 299 recordings from
  contacts that are currently Disqualified without establishing that any of those calls was the
  one on which the rep disqualified them. Nothing in that set tied a conversation to a decision.

  This does tie them. For every contact a REP moved to Disqualified since 1 Aug (excluding
  Kaustubh, Admin and system/bulk writes), it reads the full activity trail and reconstructs
  the call timeline against the disqualification timestamp, so the LAST call at or before that
  moment can be named. That call is the disqualifying call; everything earlier is the run-up.

  COHORT A - rep-disqualified since 1 Aug, sampled for those that carry a transcript.
  COHORT B - the same population, restricted to contacts with exactly ONE connected call.

  THE TRANSCRIPT FIELD. mx_Custom_10 on EventCode 22 holds the transcript URL and mx_Custom_4
  the recording; confirmed live 2026-08-13 by dumping every field on every event code rather
  than assuming. Coverage is thin, so this reports the fill rate rather than quietly sampling
  whatever happens to have one - a study built only on transcribed calls is a study of whichever
  calls the transcription service happened to catch.

.PARAMETER MaxContacts
  Cap on contacts scanned. Each costs one API call (no bulk activity read exists).

.EXAMPLE
  powershell.exe -File .\scripts\reports\disq-call-evidence.ps1 -MaxContacts 1600
#>

param(
    [int]$MaxContacts = 1600,
    [string]$Since = "2026-08-01"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "disq_call_evidence_log.txt"
$outPath = Join-Path $dataDir "disq_call_evidence_$stamp.json"

$cfg   = Import-LsqConfig
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']

Write-LsqLog "=== disq-call-evidence start ($stamp) since=$Since ===" $logPath

function SbPage($p) {
    $all = New-Object Collections.Generic.List[object]; $off = 0
    while ($true) {
        $sep = if ($p -like "*?*") { "&" } else { "?" }
        $req = [Net.HttpWebRequest]::Create("$sbUrl/rest/v1/$p$sep" + "limit=1000&offset=$off")
        $req.Method = "GET"
        $req.Headers.Add("apikey", $sbKey); $req.Headers.Add("Authorization", "Bearer $sbKey")
        $r = $req.GetResponse()
        $b = (New-Object IO.StreamReader($r.GetResponseStream())).ReadToEnd(); $r.Close()
        $rows = $b | ConvertFrom-Json
        if (-not $rows -or $rows.Count -eq 0) { break }
        foreach ($x in $rows) { $all.Add($x) }
        if ($rows.Count -lt 1000) { break }
        $off += 1000
    }
    return $all
}

# ---------------------------------------------------------------------------------------
# 1. The population: contacts a REP moved to Disqualified since $Since.
#
# Excluding Kaustubh, Admin and the blank actor is what makes this a study of rep judgement.
# Those three are bulk and admin sweeps - 40% of all movement in this window is a blank actor
# and another 24% is one person, and mixing them in would describe an operation, not a decision.
# ---------------------------------------------------------------------------------------
$hist = SbPage "v_stage_history?select=prospect_id,changed_at_utc,previous_stage,changed_by_name&current_stage=eq.Disqualified&changed_at_utc=gte.$Since"
$excluded = @('Kaustubh Chauhan', 'Admin', 'System', '')

$byContact = @{}
foreach ($h in $hist) {
    $who = "$($h.changed_by_name)".Trim()
    if ($who -eq '' -or $excluded -contains $who) { continue }
    $id = "$($h.prospect_id)"
    # Keep the EARLIEST rep-made disqualification per contact - that is the decision moment.
    if (-not $byContact.ContainsKey($id) -or
        [datetime]$h.changed_at_utc -lt [datetime]$byContact[$id].changed_at_utc) {
        $byContact[$id] = $h
    }
}
$pop = @($byContact.Values | Sort-Object { [datetime]$_.changed_at_utc })
Write-Output "Rep-disqualified contacts since ${Since}: $($pop.Count)"
Write-LsqLog "population = $($pop.Count) contacts" $logPath

if ($pop.Count -gt $MaxContacts) { $pop = @($pop | Select-Object -First $MaxContacts) }

# ---------------------------------------------------------------------------------------
# 2. Walk each trail and reconstruct the call timeline against the disqualification moment.
# ---------------------------------------------------------------------------------------
$recs    = New-Object Collections.Generic.List[object]
$done    = 0
$failed  = 0

foreach ($p in $pop) {
    $done++
    try { $acts = @(Get-LeadActivities -ProspectId $p.prospect_id -Config $cfg) }
    catch { $failed++; continue }

    $disqAt = [datetime]::Parse($p.changed_at_utc).ToUniversalTime()

    $calls = New-Object Collections.Generic.List[object]
    $disposition = ''; $disqCategory = ''; $disqReason = ''
    foreach ($a in $acts) {
        $ec = "$($a.EventCode)"
        if ($ec -eq '209') {
            if (-not $disposition)  { $disposition  = "$($a.ActivityFields.mx_Custom_1)".Trim() }
            if (-not $disqCategory) { $disqCategory = "$($a.ActivityFields.mx_Custom_3)".Trim() }
        }
        if ($ec -notin @('22','21','203')) { continue }

        $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
        if (-not $when) { $when = ConvertFrom-LsqUtc "$($a.ActivityFields.mx_Custom_2)" }
        if (-not $when) { continue }

        $dur = 0
        [void][int]::TryParse("$($a.ActivityFields.mx_Custom_3)", [ref]$dur)
        if ($ec -ne '22') { $dur = Get-LsqCallDuration $a }

        $calls.Add([pscustomobject]@{
            EventCode  = $ec
            WhenUtc    = $when
            DurationS  = $dur
            Connected  = ($dur -gt 0)
            Status     = "$($a.ActivityFields.Status)".Trim()
            Actor      = "$($a.ActivityFields.CreatedBy)".Trim()
            Transcript = "$($a.ActivityFields.mx_Custom_10)".Trim()
            Recording  = "$($a.ActivityFields.mx_Custom_4)".Trim()
        })
    }

    $ordered = @($calls | Sort-Object WhenUtc)
    # The disqualifying call: latest call at or before the stage change. A 2-hour grace window
    # absorbs a rep who logs the call a moment after clicking the stage, which is common.
    $atOrBefore = @($ordered | Where-Object { $_.WhenUtc -le $disqAt.AddHours(2) })
    $last  = if ($atOrBefore.Count -gt 0) { $atOrBefore[-1] } else { $null }
    $prior = if ($atOrBefore.Count -gt 1) { $atOrBefore[0..($atOrBefore.Count-2)] } else { @() }

    $recs.Add([pscustomobject]@{
        ProspectId      = "$($p.prospect_id)"
        DisqAtUtc       = $disqAt
        DisqBy          = "$($p.changed_by_name)".Trim()
        PreviousStage   = "$($p.previous_stage)".Trim()
        Disposition209  = $disposition
        DisqCategory209 = $disqCategory
        TotalCalls      = $ordered.Count
        CallsBeforeDisq = $atOrBefore.Count
        ConnectedCalls  = @($ordered | Where-Object { $_.Connected }).Count
        ConnectedBefore = @($atOrBefore | Where-Object { $_.Connected }).Count
        LastCallUtc     = if ($last) { $last.WhenUtc } else { $null }
        LastCallDur     = if ($last) { $last.DurationS } else { 0 }
        LastConnected   = if ($last) { $last.Connected } else { $false }
        LastTranscript  = if ($last) { $last.Transcript } else { '' }
        HoursCallToDisq = if ($last) { [math]::Round(($disqAt - $last.WhenUtc).TotalHours, 2) } else { $null }
        AnyTranscript   = @($atOrBefore | Where-Object { $_.Transcript }).Count
        Calls           = $ordered
    })

    if ($done % 100 -eq 0) {
        Write-LsqLog "  ...$done / $($pop.Count) (failed $failed)" $logPath
        Write-Output "  ...$done / $($pop.Count)"
    }
    Start-Sleep -Milliseconds 55
}

Write-LsqLog "scanned $done, failed $failed" $logPath

# ---------------------------------------------------------------------------------------
# 3. Coverage and cohorts.
# ---------------------------------------------------------------------------------------
function Pct($n, $d) { if ($d -eq 0) { return 0 } return [math]::Round(100.0*$n/$d, 1) }
$n = $recs.Count

Write-Output ""
Write-Output "=== POPULATION ==="
Write-Output "rep-disqualified contacts scanned : $n   (failed fetches: $failed)"

Write-Output ""
Write-Output "=== CALL ACTIVITY BEFORE THE DISQUALIFICATION ==="
$noCall = @($recs | Where-Object { $_.CallsBeforeDisq -eq 0 }).Count
$noConn = @($recs | Where-Object { $_.ConnectedBefore -eq 0 }).Count
Write-Output ("no call at all before being disqualified : {0,5}  {1}%" -f $noCall, (Pct $noCall $n))
Write-Output ("never connected before being disqualified: {0,5}  {1}%" -f $noConn, (Pct $noConn $n))
$b = @{}
foreach ($r in $recs) {
    $k = switch ($r.ConnectedBefore) { 0 {'0 connected'} 1 {'1 connected'} 2 {'2 connected'} default {'3+ connected'} }
    if ($b.ContainsKey($k)) { $b[$k]++ } else { $b[$k] = 1 }
}
$b.GetEnumerator() | Sort-Object Name | ForEach-Object { "  {0,-14} {1,5}  {2}%" -f $_.Name, $_.Value, (Pct $_.Value $n) }

Write-Output ""
Write-Output "=== TRANSCRIPT COVERAGE (mx_Custom_10 on EventCode 22) ==="
$withAny  = @($recs | Where-Object { $_.AnyTranscript -gt 0 }).Count
$withLast = @($recs | Where-Object { $_.LastTranscript }).Count
Write-Output ("contacts with ANY transcript in the run-up   : {0,5}  {1}%" -f $withAny, (Pct $withAny $n))
Write-Output ("contacts where the DISQUALIFYING call has one: {0,5}  {1}%" -f $withLast, (Pct $withLast $n))

Write-Output ""
Write-Output "=== EventCode 209 disposition, where present ==="
$with209 = @($recs | Where-Object { $_.Disposition209 })
Write-Output "contacts carrying a 209 disposition: $($with209.Count)  ($(Pct $with209.Count $n)%)"
$with209 | Group-Object Disposition209 | Sort-Object Count -Descending |
    ForEach-Object { "  {0,5}  [{1}]" -f $_.Count, $_.Name }

# COHORT A - the disqualifying call is transcribed.
$cohortA = @($recs | Where-Object { $_.LastTranscript } | Sort-Object DisqAtUtc)
# COHORT B - exactly one connected call in the whole run-up.
$cohortB = @($recs | Where-Object { $_.ConnectedBefore -eq 1 } | Sort-Object DisqAtUtc)
$cohortBT = @($cohortB | Where-Object { $_.LastTranscript })

Write-Output ""
Write-Output "=== COHORTS ==="
Write-Output "A. disqualifying call transcribed          : $($cohortA.Count)"
Write-Output "B. exactly ONE connected call before disq  : $($cohortB.Count)"
Write-Output "   of which the disqualifying call is transcribed: $($cohortBT.Count)"

$payload = [pscustomobject]@{
    GeneratedUtc = (Get-Date).ToUniversalTime()
    Since        = $Since
    Scanned      = $n
    Failed       = $failed
    Records      = $recs
}
$payload | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $outPath -Encoding UTF8
Write-Output ""
Write-Output "Per-contact records: $outPath"
Write-LsqLog "wrote $outPath" $logPath
