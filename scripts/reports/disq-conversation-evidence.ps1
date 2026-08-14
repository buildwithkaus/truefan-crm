<#
.SYNOPSIS
  READ-ONLY. Stratified sample of disqualified contacts: did a HUMAN ever actually have a
  conversation with them before they were written off?

.DESCRIPTION
  Every field-level answer to "why did this lead not buy" is a relabelling of the legacy
  ProspectStage value (96.7% of the pile, proven by mx_Previous_Contact_Stage). So the field
  cannot say whether a reason was gathered in a conversation or assumed. The activity trail
  can - it is the only independent record.

  Per sampled contact this counts, across the FULL trail:
    - EventCode 22  outbound human dial      (connected = ActivityFields.mx_Custom_3 > 0)
    - EventCode 21  inbound human call
    - EventCode 208 Callkaro AI dialler      (a background system, never a rep - memory/10)
    - EventCode 201 WhatsApp                 (a one-actor broadcast integration, not outreach)
  and reports, per disqualification reason, the share with at least one CONNECTED HUMAN call.

  Costs one API call per contact (no bulk activity read exists), so it samples rather than
  scans. Sample size is set per reason for a +/-5pp confidence interval at 95%.

  NEGATIVE CONTROL: a contact known to have connected calls must come back with >0, and the
  per-reason totals must equal the sample size drawn.

.EXAMPLE
  powershell.exe -File .\scripts\reports\disq-conversation-evidence.ps1 -PerReason 200
#>

param(
    [int]$PerReason = 200,
    [string]$ScanFile
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "disq_conversation_evidence_log.txt"
$outPath = Join-Path $dataDir "disq_conversation_evidence_$stamp.json"

if (-not $ScanFile) {
    $ScanFile = (Get-ChildItem (Join-Path $dataDir "disq_deep_dive_*.json") |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
Write-LsqLog "=== disq-conversation-evidence start ($stamp) - source $([IO.Path]::GetFileName($ScanFile)) ===" $logPath

$rows = Get-Content $ScanFile -Raw | ConvertFrom-Json
$disq = @($rows | Where-Object { $_.Stage -eq 'Disqualified' })
Write-Output "Disqualified population: $($disq.Count)"

# The six reasons that carry the commercial argument, plus the blank one.
$reasons = @(
    'Not Interested - No Reason Stated'
    'Invalid / Not a Business'
    'Low Budget / Pricing Mismatch'
    'Just Enquiring - No Intent'
    'No Celebrity Requirement'
    'Invalid Contact Data'
)

$cfg = Import-LsqConfig
$results = New-Object System.Collections.Generic.List[object]
$rand = New-Object System.Random 20260813   # fixed seed: the sample is reproducible

foreach ($reason in $reasons) {
    $pool = @($disq | Where-Object { $_.Reason -eq $reason })
    if ($pool.Count -eq 0) { continue }
    $n = [Math]::Min($PerReason, $pool.Count)
    $sample = $pool | Sort-Object { $rand.Next() } | Select-Object -First $n

    Write-Output ""
    Write-Output "=== [$reason]  pool=$($pool.Count)  sampling $n ==="
    Write-LsqLog "Sampling $n of $($pool.Count) for [$reason]" $logPath

    $stat = [ordered]@{
        Reason = $reason; Pool = $pool.Count; Sampled = 0
        HumanDial = 0; HumanConnected = 0; InboundCall = 0
        AiDial = 0; AiOnly = 0; WhatsApp = 0; NoTouchAtAll = 0
        TotalHumanDials = 0; TotalAiDials = 0; Failed = 0
    }

    foreach ($c in $sample) {
        try { $acts = Get-LeadActivities -ProspectId $c.Id -Config $cfg }
        catch { $stat.Failed++; continue }
        $stat.Sampled++

        $hDial = 0; $hConn = 0; $inb = 0; $ai = 0; $wa = 0
        foreach ($a in @($acts)) {
            switch ("$($a.EventCode)") {
                '22'  { $hDial++; if (Test-LsqCallConnected $a) { $hConn++ } }
                '21'  { $inb++ }
                '208' { $ai++ }
                '201' { $wa++ }
            }
        }
        $stat.TotalHumanDials += $hDial
        $stat.TotalAiDials    += $ai
        if ($hDial -gt 0) { $stat.HumanDial++ }
        if ($hConn -gt 0) { $stat.HumanConnected++ }
        if ($inb   -gt 0) { $stat.InboundCall++ }
        if ($ai    -gt 0) { $stat.AiDial++ }
        if ($wa    -gt 0) { $stat.WhatsApp++ }
        if ($ai -gt 0 -and $hDial -eq 0) { $stat.AiOnly++ }
        if ($hDial -eq 0 -and $ai -eq 0 -and $inb -eq 0 -and $wa -eq 0) { $stat.NoTouchAtAll++ }

        $results.Add([pscustomobject]@{
            Id = $c.Id; Reason = $reason; Owner = $c.Owner; Source = $c.Source
            HumanDials = $hDial; HumanConnects = $hConn; Inbound = $inb
            AiDials = $ai; WhatsApp = $wa
        })
        Start-Sleep -Milliseconds 60
    }

    $s = $stat.Sampled
    function P($v) { if ($s -eq 0) { return 0 }; return [math]::Round(100.0*$v/$s, 1) }
    Write-Output ("  sampled                      {0,5}" -f $s)
    Write-Output ("  had >=1 human outbound dial  {0,5}  {1}%" -f $stat.HumanDial,      (P $stat.HumanDial))
    Write-Output ("  had >=1 CONNECTED human call {0,5}  {1}%   <-- someone actually spoke to them" -f $stat.HumanConnected, (P $stat.HumanConnected))
    Write-Output ("  had an inbound call          {0,5}  {1}%" -f $stat.InboundCall,    (P $stat.InboundCall))
    Write-Output ("  touched by the AI dialler    {0,5}  {1}%" -f $stat.AiDial,         (P $stat.AiDial))
    Write-Output ("  AI dialler ONLY, no human    {0,5}  {1}%" -f $stat.AiOnly,         (P $stat.AiOnly))
    Write-Output ("  WhatsApp broadcast           {0,5}  {1}%" -f $stat.WhatsApp,       (P $stat.WhatsApp))
    Write-Output ("  NO touch of any kind, ever   {0,5}  {1}%" -f $stat.NoTouchAtAll,   (P $stat.NoTouchAtAll))
    Write-Output ("  mean human dials / contact   {0,5}" -f ([math]::Round($stat.TotalHumanDials/[Math]::Max(1,$s),2)))
    Write-Output ("  mean AI dials / contact      {0,5}" -f ([math]::Round($stat.TotalAiDials/[Math]::Max(1,$s),2)))
    if ($stat.Failed -gt 0) { Write-Output ("  FAILED fetches               {0,5}" -f $stat.Failed) }
    Write-LsqLog ("[$reason] connected=$($stat.HumanConnected)/$s aiOnly=$($stat.AiOnly) noTouch=$($stat.NoTouchAtAll)") $logPath
}

$results | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $outPath -Encoding UTF8
Write-Output ""
Write-Output "Per-contact evidence written to $outPath"
Write-LsqLog "Done. $($results.Count) contacts sampled." $logPath
