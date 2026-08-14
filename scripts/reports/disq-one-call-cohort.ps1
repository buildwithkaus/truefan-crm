<#
.SYNOPSIS
  READ-ONLY. Builds the "one connected call, then disqualified as Not Interested - No Reason
  Stated" cohort, with the transcript of that single call.

.DESCRIPTION
  Candidate pool: contacts currently at Disqualified whose Disqualification Reason is exactly
  'Not Interested - No Reason Stated' AND whose LAST activity was a phone call (inbound or
  outbound) on/after 1 July 2026. The last-activity filter is what makes this affordable -
  there are 25,626 contacts on that reason and no bulk activity read exists, so scanning them
  all would cost 25,626 API calls. Restricting to a call as the last touch cuts it to ~1,960
  and keeps exactly the population where a call plausibly caused the disqualification.

  The disqualification moment is taken from EventCode 3002 in the trail itself
  (PreviousStage / CurrentStage / CreatedBy in Data[]), NOT from the warehouse stage history.
  The trail is complete for every contact; the warehouse is only reliable from 1 August.

  A contact qualifies when it has EXACTLY ONE connected call across its whole history -
  connected meaning duration > 0 on EventCode 22 (outbound) or 21 (inbound) - and that call
  carries a transcript in mx_Custom_10.

.PARAMETER Probe
  Dump the raw shape of EventCode 3002 on a few contacts and stop. Run this first.

.EXAMPLE
  powershell.exe -File .\scripts\reports\disq-one-call-cohort.ps1 -Probe
  powershell.exe -File .\scripts\reports\disq-one-call-cohort.ps1 -MaxScan 2000
#>

param(
    [switch]$Probe,
    [int]$MaxScan = 2000,
    [string]$Since = "2026-07-01"
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "disq_one_call_log.txt"
$outPath = Join-Path $dataDir "disq_one_call_cohort_$stamp.json"
$utf8    = New-Object Text.UTF8Encoding($false)
$cfg     = Import-LsqConfig

$TARGET_REASON = 'Not Interested - No Reason Stated'

# ---------------------------------------------------------------------------------------
# Candidate pool from the existing full-book scan
# ---------------------------------------------------------------------------------------
$sc = Get-ChildItem (Join-Path $dataDir "disq_deep_dive_*.json") |
      Sort-Object Length -Descending | Select-Object -First 1
Write-Output "book scan: $($sc.Name)"
$book = [IO.File]::ReadAllText($sc.FullName, $utf8) | ConvertFrom-Json

$callNames = @('Outbound Phone Call Activity','Inbound Phone Call Activity','01. Phone Call/ Follow Up')
$pool = @($book | Where-Object {
    $_.Stage -eq 'Disqualified' -and
    "$($_.Reason)".Trim() -eq $TARGET_REASON -and
    "$($_.LastActAt)" -ge $Since -and
    ($callNames -contains "$($_.LastActName)".Trim())
})
Write-Output "candidate pool: $($pool.Count)"
Write-LsqLog "=== disq-one-call-cohort ($stamp) pool=$($pool.Count) ===" $logPath

if ($Probe) {
    Write-Output ""
    Write-Output "=== EventCode 3002 shape ==="
    $seen = 0
    foreach ($p in ($pool | Select-Object -First 8)) {
        $acts = @(Get-LeadActivities -ProspectId $p.Id -Config $cfg)
        foreach ($a in $acts) {
            if ("$($a.EventCode)" -ne '3002') { continue }
            Write-Output ""
            Write-Output "contact $($p.Id)  CreatedOn=$($a.CreatedOn)"
            Write-Output "  Data[]:"
            foreach ($d in @($a.Data)) { Write-Output ("    {0,-18} {1}" -f $d.Key, $d.Value) }
            Write-Output "  ActivityFields:"
            foreach ($pr in $a.ActivityFields.PSObject.Properties) {
                $v = "$($pr.Value)".Trim()
                if ($v) { Write-Output ("    {0,-26} {1}" -f $pr.Name, $v) }
            }
            $seen++
            break
        }
        if ($seen -ge 3) { break }
    }
    return
}

# ---------------------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------------------
if ($pool.Count -gt $MaxScan) { $pool = @($pool | Select-Object -First $MaxScan) }

$recs = New-Object Collections.Generic.List[object]
$done = 0; $failed = 0
foreach ($p in $pool) {
    $done++
    try { $acts = @(Get-LeadActivities -ProspectId $p.Id -Config $cfg) }
    catch { $failed++; continue }

    # --- the disqualification moment, from the trail ---
    $disqAt = $null; $disqBy = ''; $prevStage = ''
    foreach ($a in $acts) {
        if ("$($a.EventCode)" -ne '3002') { continue }
        $cur = Get-ActivityDataValue $a 'CurrentStage'
        if ("$cur".Trim() -ne 'Disqualified') { continue }
        $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
        if (-not $when) { continue }
        if ($null -eq $disqAt -or $when -gt $disqAt) {
            $disqAt    = $when
            $disqBy    = (Get-ActivityDataValue $a 'CreatedBy')
            $prevStage = (Get-ActivityDataValue $a 'PreviousStage')
        }
    }

    # --- calls ---
    $calls = New-Object Collections.Generic.List[object]
    foreach ($a in $acts) {
        $ec = "$($a.EventCode)"
        if ($ec -notin @('22','21')) { continue }
        $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
        if (-not $when) { $when = ConvertFrom-LsqUtc "$($a.ActivityFields.mx_Custom_2)" }
        $dur = 0
        [void][int]::TryParse("$($a.ActivityFields.mx_Custom_3)", [ref]$dur)
        $calls.Add([pscustomobject]@{
            EventCode  = $ec
            Direction  = $(if ($ec -eq '22') { 'Outbound' } else { 'Inbound' })
            WhenUtc    = $when
            DurationS  = $dur
            Connected  = ($dur -gt 0)
            Status     = "$($a.ActivityFields.Status)".Trim()
            Transcript = "$($a.ActivityFields.mx_Custom_10)".Trim()
            Recording  = "$($a.ActivityFields.mx_Custom_4)".Trim()
        })
    }
    $ordered   = @($calls | Sort-Object WhenUtc)
    $connected = @($ordered | Where-Object { $_.Connected })

    $recs.Add([pscustomobject]@{
        ProspectId     = "$($p.Id)"
        Owner          = "$($p.Owner)"
        DisqAtUtc      = $disqAt
        DisqBy         = "$disqBy"
        PreviousStage  = "$prevStage"
        Source         = "$($p.Source)"
        Industry       = "$($p.Industry)"
        City           = "$($p.City)"
        CreatedOn      = "$($p.CreatedOn)"
        TotalCalls     = $ordered.Count
        OutboundCalls  = @($ordered | Where-Object { $_.EventCode -eq '22' }).Count
        InboundCalls   = @($ordered | Where-Object { $_.EventCode -eq '21' }).Count
        ConnectedCalls = $connected.Count
        TheCall        = $(if ($connected.Count -eq 1) { $connected[0] } else { $null })
        Calls          = $ordered
    })

    if ($done % 100 -eq 0) {
        Write-Output "  ...$done / $($pool.Count)  (failed $failed)"
        Write-LsqLog "  ...$done / $($pool.Count)" $logPath
    }
    Start-Sleep -Milliseconds 55
}

$n = $recs.Count
function Pct($x) { if ($n -eq 0) { return 0 } return [math]::Round(100.0*$x/$n,1) }
Write-Output ""
Write-Output "scanned $n (failed $failed)"
Write-Output ""
Write-Output "--- connected calls across the whole history ---"
$recs | Group-Object ConnectedCalls | Sort-Object { [int]$_.Name } |
    ForEach-Object { "  {0,3} connected : {1,5}  {2}%" -f $_.Name, $_.Count, (Pct $_.Count) }

$one  = @($recs | Where-Object { $_.ConnectedCalls -eq 1 })
$oneT = @($one | Where-Object { $null -ne $_.TheCall -and "$($_.TheCall.Transcript)" -ne '' })
Write-Output ""
Write-Output "EXACTLY 1 connected call            : $($one.Count)"
Write-Output "...and that call has a transcript   : $($oneT.Count)"
Write-Output ""
Write-Output "--- reps on the qualifying set ---"
$oneT | Group-Object DisqBy | Sort-Object Count -Descending |
    ForEach-Object { "  {0,4}  {1}" -f $_.Count, $_.Name }

[pscustomobject]@{ GeneratedUtc=(Get-Date).ToUniversalTime(); Reason=$TARGET_REASON
                   Scanned=$n; Failed=$failed; Records=$recs } |
    ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $outPath -Encoding UTF8
Write-Output ""
Write-Output "Records: $outPath"
Write-LsqLog "wrote $outPath ($n records, $($oneT.Count) qualifying)" $logPath
