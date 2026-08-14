<#
.SYNOPSIS
  Assembles the whole disqualification analysis into ONE Excel workbook.

.DESCRIPTION
  Reads what the analysis scripts already produced and writes it to a fixed path, overwriting
  each time, so re-running refreshes the same file:

    data/disq_call_evidence_*.json  - 1,520 rep-made disqualifications + full call timelines
    data/disq_deep_dive_*.json      - live scan of all 91,056 contacts
    <scratch>/cohort_manifest.csv   - the 200 disqualifying-call transcripts sampled
    <scratch>/coding.csv            - the hand-coding of the transcripts that were read

  Writes the .xlsx package directly via scripts/lib/xlsx.ps1 - no Excel, no modules.
  Excel COM (the approach in export-distribution-xlsx.ps1) was tried first and could not carry
  this workbook: 10 sheets and ~9,400 rows threw OutOfMemoryException at the same sheet on every
  run, with screen updating off, manual calculation, chunked writes and header-only AutoFilter.

.PARAMETER ScratchDir
  Where cohort_manifest.csv and coding.csv live.

.EXAMPLE
  powershell.exe -File .\scripts\reports\export-disqualification-workbook.ps1
#>

param(
    # Inputs live in data/ so this survives the session that produced them. Point elsewhere
    # only if you are rebuilding from a fresh scratch run.
    [string]$InputDir,
    [string]$OutPath
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\xlsx.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
if (-not $InputDir) { $InputDir = $dataDir }
$ScratchDir = $InputDir
if (-not $OutPath) { $OutPath = Join-Path $dataDir "TrueFan_Disqualification_Analysis.xlsx" }
$logPath = Join-Path $dataDir "export_disq_workbook_log.txt"
$utf8 = New-Object Text.UTF8Encoding($false)

Write-LsqLog "=== export-disqualification-workbook start ===" $logPath

# ---------------------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------------------
$evidenceFile = Get-ChildItem (Join-Path $dataDir "disq_call_evidence_*.json") |
                Sort-Object Length -Descending | Select-Object -First 1
$scanFile     = Get-ChildItem (Join-Path $dataDir "disq_deep_dive_*.json") |
                Sort-Object Length -Descending | Select-Object -First 1
Write-Output "evidence: $($evidenceFile.Name)"
Write-Output "book scan: $($scanFile.Name)"

$recs = ([IO.File]::ReadAllText($evidenceFile.FullName, $utf8) | ConvertFrom-Json).Records
Write-Output "  disqualifications: $($recs.Count)"
$book = [IO.File]::ReadAllText($scanFile.FullName, $utf8) | ConvertFrom-Json
Write-Output "  book contacts: $($book.Count)"

$manifest = @()
$mf = Join-Path $ScratchDir "cohort_manifest.csv"
if (Test-Path $mf) { $manifest = @(Import-Csv $mf) }
$coding = @{}
$cf = Join-Path $ScratchDir "coding.csv"
if (Test-Path $cf) { foreach ($c in (Import-Csv $cf)) { $coding["$($c.Cohort)$($c.Idx)"] = $c.Code } }
Write-Output "  transcripts sampled: $($manifest.Count), coded: $($coding.Count)"

# ---------------------------------------------------------------------------------------
# Helpers: build a 2D object[,] from headers + rows of arrays
# ---------------------------------------------------------------------------------------
function New-Grid {
    param([string[]]$Headers, [System.Collections.IEnumerable]$Rows)
    return @{ Headers = $Headers; Rows = @($Rows) }
}
function Pct($n, $d) { if ($d -eq 0) { return 0 } return [math]::Round(100.0 * $n / $d, 1) }

$sheets = New-Object Collections.Generic.List[object]
$n = $recs.Count

# ---------------------------------------------------------------------------------------
# 1. Summary
# ---------------------------------------------------------------------------------------
$disqBook = @($book | Where-Object { $_.Stage -eq 'Disqualified' })
$noCall   = @($recs | Where-Object { [int]$_.CallsBeforeDisq -eq 0 }).Count
$everConn = @($recs | Where-Object { [int]$_.ConnectedBefore -gt 0 }).Count
$lastConn = @($recs | Where-Object { $_.LastConnected -eq $true }).Count
$within1h = @($recs | Where-Object { $null -ne $_.HoursCallToDisq -and [double]$_.HoursCallToDisq -le 1 }).Count
$oneConn  = @($recs | Where-Object { [int]$_.ConnectedBefore -eq 1 }).Count
$meanCalls= [math]::Round((($recs | Measure-Object CallsBeforeDisq -Average).Average), 2)
$withT    = @($recs | Where-Object { "$($_.LastTranscript)" -ne '' }).Count

$sumRows = @(
    @("THE BOOK", "", ""),
    @("Contacts in CRM (live scan 13 Aug 2026)", $book.Count, ""),
    @("Disqualified", $disqBook.Count, "$(Pct $disqBook.Count $book.Count)% of book"),
    @("", "", ""),
    @("REP-MADE DISQUALIFICATIONS, 1-13 AUG", "", ""),
    @("Contacts (Kaustubh / Admin / bulk excluded)", $n, ""),
    @("Mean calls before disqualification", $meanCalls, "not 1.38 - that earlier figure was wrong"),
    @("No call at all before disqualification", $noCall, "$(Pct $noCall $n)%"),
    @("Ever connected before disqualification", $everConn, "$(Pct $everConn $n)%"),
    @("Disqualified straight after a CONNECTED call", $lastConn, "$(Pct $lastConn $n)%"),
    @("...within one hour of that call", $within1h, "$(Pct $within1h $n)%"),
    @("Exactly ONE connected call (Cohort B)", $oneConn, "$(Pct $oneConn $n)%"),
    @("Disqualifying call has a transcript", $withT, "$(Pct $withT $n)%"),
    @("", "", ""),
    @("TRANSCRIPTS", "", ""),
    @("Disqualifying calls sampled and downloaded", $manifest.Count, "100 Cohort B + 100 Cohort A"),
    @("Read in full and hand-coded", $coding.Count, "all 100 of B, 34 of A"),
    @("", "", ""),
    @("METHOD", "", ""),
    @("Population", "v_stage_history, current_stage=Disqualified, since 2026-08-01", "excludes Kaustubh Chauhan, Admin, System, blank actor"),
    @("Disqualifying call", "last call at or before the stage change (+2h grace)", "so the call is tied to the decision"),
    @("Transcript field", "mx_Custom_10 on EventCode 22", "mx_Custom_4 is the recording"),
    @("", "", ""),
    @("LIMITS", "", ""),
    @("Transcript coverage", "$(Pct $withT $n)%", "transcribed calls skew connected (99.6% vs 84.4%)"),
    @("Coding", "judgement, not a mechanical count", "structural figures above cover all $n"),
    @("Withdrawn", "the earlier 299-transcript analysis", "those calls were not the disqualifying call")
)
$sheets.Add(@{ Name = "Summary"; Grid = (New-Grid @("Metric","Value","Note") $sumRows); Width = 46 })

# ---------------------------------------------------------------------------------------
# 2. Reasons across the whole disqualified book
# ---------------------------------------------------------------------------------------
$rTally = @{}
foreach ($r in $disqBook) {
    $v = "$($r.Reason)".Trim(); if ($v -eq '') { $v = '(blank)' }
    if ($rTally.ContainsKey($v)) { $rTally[$v]++ } else { $rTally[$v] = 1 }
}
$rRows = @($rTally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    ,@($_.Name, $_.Value, (Pct $_.Value $disqBook.Count)) })
$sheets.Add(@{ Name = "Reasons (all)"; Grid = (New-Grid @("Disqualification Reason","Contacts","% of disqualified") $rRows); Width = 42 })

# ---------------------------------------------------------------------------------------
# 3. Reason vs the legacy stage it was derived from
# ---------------------------------------------------------------------------------------
$pTally = @{}
foreach ($r in $disqBook) {
    $v = "$($r.PrevStage)".Trim(); if ($v -eq '') { $v = '(blank)' }
    if ($pTally.ContainsKey($v)) { $pTally[$v]++ } else { $pTally[$v] = 1 }
}
$pRows = @($pTally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    ,@($_.Name, $_.Value, (Pct $_.Value $disqBook.Count)) })
$sheets.Add(@{ Name = "Previous stage"; Grid = (New-Grid @("Previous Contact Stage","Contacts","% of disqualified") $pRows); Width = 38 })

# ---------------------------------------------------------------------------------------
# 4. Every rep-made disqualification
# ---------------------------------------------------------------------------------------
$dRows = @(foreach ($r in ($recs | Sort-Object DisqAtUtc)) {
    ,@($r.ProspectId, $r.DisqBy, "$($r.DisqAtUtc)", $r.PreviousStage,
       [int]$r.CallsBeforeDisq, [int]$r.ConnectedBefore, [int]$r.TotalCalls,
       [int]$r.LastCallDur, $(if ($r.LastConnected) {"Yes"} else {"No"}),
       $(if ($null -ne $r.HoursCallToDisq) { [double]$r.HoursCallToDisq } else { "" }),
       "$($r.Disposition209)", "$($r.LastTranscript)") })
$sheets.Add(@{ Name = "Disqualifications (1520)"
    Grid = (New-Grid @("ProspectId","Disqualified by","Disqualified at (UTC)","Previous stage",
        "Calls before","Connected before","Total calls","Last call sec","Last call connected",
        "Hours call to disq","EC209 disposition","Transcript URL") $dRows); Width = 22 })

# ---------------------------------------------------------------------------------------
# 5. Full call timeline for those contacts
# ---------------------------------------------------------------------------------------
$tRows = New-Object Collections.Generic.List[object]
foreach ($r in ($recs | Sort-Object DisqAtUtc)) {
    $seq = 0
    foreach ($c in @($r.Calls)) {
        $seq++
        # No leading comma here: inside a method call it is a parse error, and .Add() already
        # takes the object[] as a single element.
        $row = @($r.ProspectId, $r.DisqBy, "$($r.DisqAtUtc)", $seq, "$($c.EventCode)",
            "$($c.WhenUtc)", [int]$c.DurationS, $(if ($c.Connected) {"Yes"} else {"No"}),
            "$($c.Status)", "$($c.Transcript)", "$($c.Recording)")
        $tRows.Add($row)
    }
}
Write-Output "  call timeline rows: $($tRows.Count)"
$sheets.Add(@{ Name = "Call timeline"
    Grid = (New-Grid @("ProspectId","Disqualified by","Disqualified at (UTC)","Call #","Event code",
        "Call time (UTC)","Duration sec","Connected","Status","Transcript URL","Recording URL") $tRows); Width = 22 })

# ---------------------------------------------------------------------------------------
# 6. Per rep
# ---------------------------------------------------------------------------------------
$repRows = @(foreach ($g in ($recs | Group-Object DisqBy | Sort-Object Count -Descending)) {
    $gg = $g.Group; $t = $gg.Count
    ,@($g.Name, $t,
       @($gg | Where-Object { [int]$_.CallsBeforeDisq -eq 0 }).Count,
       @($gg | Where-Object { [int]$_.ConnectedBefore -eq 0 }).Count,
       @($gg | Where-Object { [int]$_.ConnectedBefore -eq 1 }).Count,
       [math]::Round((($gg | Measure-Object CallsBeforeDisq -Average).Average), 2),
       [math]::Round((($gg | Measure-Object LastCallDur -Average).Average), 0),
       (Pct @($gg | Where-Object { $_.LastConnected -eq $true }).Count $t)) })
$sheets.Add(@{ Name = "By rep"
    Grid = (New-Grid @("Rep","Disqualifications","0 calls","0 connected","Exactly 1 connected",
        "Mean calls","Mean last call sec","% disq after a connected call") $repRows); Width = 24 })

# ---------------------------------------------------------------------------------------
# 7. Transcripts sampled, with the coding
# ---------------------------------------------------------------------------------------
$mRows = @(foreach ($m in $manifest) {
    $key = "$($m.Cohort)$($m.Idx)"
    ,@($m.Cohort, [int]$m.Idx, $(if ($coding.ContainsKey($key)) { $coding[$key] } else { "(not read)" }),
       $m.DisqBy, $m.DisqAtUtc, $m.PreviousStage, [int]$m.CallsBeforeDisq,
       [int]$m.ConnectedBefore, [int]$m.LastCallDur, $m.ProspectId, $m.Url) })
$sheets.Add(@{ Name = "Transcripts sampled"
    Grid = (New-Grid @("Cohort","#","Coded outcome","Rep","Disqualified at (UTC)","Previous stage",
        "Calls before","Connected before","Call sec","ProspectId","Transcript URL") $mRows); Width = 20 })

# ---------------------------------------------------------------------------------------
# 8. Coding tally
# ---------------------------------------------------------------------------------------
$cB = @{}; $cA = @{}
foreach ($k in $coding.Keys) {
    $v = $coding[$k]
    if ($k.StartsWith('B')) { if ($cB.ContainsKey($v)) { $cB[$v]++ } else { $cB[$v] = 1 } }
    else { if ($cA.ContainsKey($v)) { $cA[$v]++ } else { $cA[$v] = 1 } }
}
$allCodes = @(($cB.Keys + $cA.Keys) | Sort-Object -Unique)
$bTot = ($cB.Values | Measure-Object -Sum).Sum
$aTot = ($cA.Values | Measure-Object -Sum).Sum
$cRows = @(foreach ($k in ($allCodes | Sort-Object { -1 * ($(if($cB.ContainsKey($_)){$cB[$_]}else{0})) })) {
    $b = if ($cB.ContainsKey($k)) { $cB[$k] } else { 0 }
    $a = if ($cA.ContainsKey($k)) { $cA[$k] } else { 0 }
    ,@($k, $b, (Pct $b $bTot), $a, (Pct $a $aTot)) })
$sheets.Add(@{ Name = "Coding tally"
    Grid = (New-Grid @("Coded outcome","Cohort B (n=$bTot)","B %","Cohort A (n=$aTot)","A %") $cRows); Width = 34 })

# ---------------------------------------------------------------------------------------
# 9. Source x outcome, whole book
# ---------------------------------------------------------------------------------------
$srcAgg = @{}
foreach ($r in $book) {
    $s = "$($r.Source)".Trim(); if ($s -eq '') { $s = '(blank)' }
    if (-not $srcAgg.ContainsKey($s)) {
        $srcAgg[$s] = [pscustomobject]@{ T=0; D=0; Inv=0; NI=0; P=0; C=0 } }
    $a = $srcAgg[$s]; $a.T++
    if ($r.Stage -eq 'Disqualified') { $a.D++ }
    if ($r.Stage -eq 'Prospect')     { $a.P++ }
    if ($r.Stage -eq 'Customer')     { $a.C++ }
    if ($r.Reason -eq 'Invalid / Not a Business')          { $a.Inv++ }
    if ($r.Reason -eq 'Not Interested - No Reason Stated') { $a.NI++ }
}
$sRows = @($srcAgg.GetEnumerator() | Where-Object { $_.Value.T -ge 100 } |
    Sort-Object { -1 * $_.Value.T } | ForEach-Object {
        $a = $_.Value
        ,@($_.Name, $a.T, $a.D, (Pct $a.D $a.T), $a.Inv, (Pct $a.Inv $a.T), $a.NI, $a.P, $a.C) })
$sheets.Add(@{ Name = "Source x outcome"
    Grid = (New-Grid @("Source","Contacts","Disqualified","Disq %","Invalid/Not a Business",
        "Invalid %","No Reason Stated","Prospect","Customer") $sRows); Width = 28 })

# ---------------------------------------------------------------------------------------
# 10. Industry x outcome, whole book
# ---------------------------------------------------------------------------------------
$indAgg = @{}
foreach ($r in $book) {
    $s = "$($r.Industry)".Trim(); if ($s -eq '') { $s = '(blank)' }
    if (-not $indAgg.ContainsKey($s)) {
        $indAgg[$s] = [pscustomobject]@{ T=0; D=0; P=0; C=0 } }
    $a = $indAgg[$s]; $a.T++
    if ($r.Stage -eq 'Disqualified') { $a.D++ }
    if ($r.Stage -eq 'Prospect')     { $a.P++ }
    if ($r.Stage -eq 'Customer')     { $a.C++ }
}
$iRows = @($indAgg.GetEnumerator() | Where-Object { $_.Value.T -ge 100 } |
    Sort-Object { -1 * $_.Value.T } | ForEach-Object {
        $a = $_.Value
        ,@($_.Name, $a.T, $a.D, (Pct $a.D $a.T), $a.P, $a.C, (Pct ($a.P + $a.C) $a.T)) })
$sheets.Add(@{ Name = "Industry x outcome"
    Grid = (New-Grid @("Industry (mx_Category)","Contacts","Disqualified","Disq %","Prospect",
        "Customer","Prospect+Customer %") $iRows); Width = 32 })

# ---------------------------------------------------------------------------------------
# Write the workbook
Write-Output ""
Write-Output "Writing $($sheets.Count) sheets..."

$specs = @()
foreach ($s in $sheets) {
    $specs += @{
        Name      = $s.Name
        Headers   = $s.Grid.Headers
        Rows      = $s.Grid.Rows
        ColWidths = @(1..($s.Grid.Headers.Count) | ForEach-Object { $s.Width })
    }
    Write-Output ("  {0,-26} {1,7} rows x {2} cols" -f $s.Name, $s.Grid.Rows.Count, $s.Grid.Headers.Count)
    Write-LsqLog "  sheet '$($s.Name)': $($s.Grid.Rows.Count) rows" $logPath
}

New-XlsxWorkbook -Sheets $specs -Path $OutPath | Out-Null
Write-Output ""
Write-Output "Workbook: $OutPath"
Write-Output ("Size: {0:N0} KB" -f ((Get-Item $OutPath).Length / 1KB))
Write-LsqLog "saved $OutPath" $logPath
