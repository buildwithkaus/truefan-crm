<#
.SYNOPSIS
  Workbook for the "one connected call, then disqualified as Not Interested - No Reason Stated"
  sample: the 200 contacts, the reason found in each transcript, and a rep x reason summary.

.DESCRIPTION
  Sample definition, all four conditions together:
    - currently at Contact Stage = Disqualified
    - Disqualification Reason = exactly 'Not Interested - No Reason Stated'
    - EXACTLY ONE connected call across the contact's whole history, counting outbound
      (EventCode 22) and inbound (EventCode 21), connected meaning duration > 0
    - that call carries a transcript in mx_Custom_10

  314 contacts met all four; 200 were drawn at random with a fixed seed. Each transcript was
  read in full and coded to the reason the customer actually gave.

  Sheets: Sample set | Master (200 + reason) | Summary rep x reason | Summary by reason | Method.

.EXAMPLE
  powershell.exe -File .\scripts\reports\export-onecall-workbook.ps1
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
if (-not $OutPath) { $OutPath = Join-Path $dataDir "TrueFan_OneCall_NotInterested_200.xlsx" }
$logPath = Join-Path $dataDir "export_onecall_workbook_log.txt"
$utf8 = New-Object Text.UTF8Encoding($false)
Write-LsqLog "=== export-onecall-workbook start ===" $logPath

$man    = @(Import-Csv (Join-Path $ScratchDir "onecall_manifest.csv"))
$coding = @{}
foreach ($c in (Import-Csv (Join-Path $ScratchDir "coding200.csv"))) { $coding[[int]$c.Idx] = $c.Code }
$tDir   = Join-Path $ScratchDir "onecall_transcripts"
Write-Output "manifest: $($man.Count)   coded: $($coding.Count)"

# Plain-English label + family for each code, so the sheets are readable without a key.
$label = @{
    instant_refusal_no_reason      = @('Refused on the spot, no reason given',        'No reason obtainable')
    no_conversation                = @('No real conversation (call failed / cut / language)', 'No reason obtainable')
    no_current_requirement         = @('No requirement right now',                    'Genuine but soft')
    not_a_business_or_wrong_person = @('Wrong person / not a business at all',         'Should never have been called')
    no_marketing_spend             = @('Runs no marketing or ads at all',              'Should never have been called')
    has_agency_or_inhouse          = @('Already has an agency or in-house team',       'Genuine')
    business_closed_or_changed     = @('Business closed, saturated or moved on',       'Should never have been called')
    structurally_not_permitted     = @('Cannot advertise - regulated, B2B, franchisee','Should never have been called')
    too_small_or_local             = @('Too small or purely local for our pricing',    'Genuine')
    process_failure_live_thread    = @('Asked for material or a callback - we dropped it', 'Our own process')
    opt_out_or_dnd                 = @('Had asked not to be called / DND',             'Our own process')
    gatekeeper_wrong_contact       = @('Reached a gatekeeper, not the decision maker',  'Should never have been called')
    price_too_high                 = @('Price too high',                               'Genuine')
    lost_to_competitor             = @('Already booked with someone else',             'Genuine')
    rejects_premise_or_ai          = @('Rejects celebrity ads / thinks AI looks fake', 'Genuine')
    roster_gap                     = @('Our celebrities do not fit their brand',       'Genuine')
}

function Pct($n, $d) { if ($d -eq 0) { return 0 } return [math]::Round(100.0*$n/$d, 1) }

# Pull a short quote from the end of each transcript - that is where the refusal lands.
$rows = @()
foreach ($m in $man) {
    $i = [int]$m.Idx
    $body = ''
    $f = Join-Path $tDir $m.File
    if (Test-Path $f) {
        $t = [IO.File]::ReadAllText($f, $utf8)
        if ($t -match '(?s)TRANSCRIPT\s*-+\s*(.*)$') { $body = ($matches[1] -replace '\s+',' ').Trim() }
    }
    $quote = if ($body.Length -gt 300) { '...' + $body.Substring($body.Length - 300) } else { $body }
    $code  = if ($coding.ContainsKey($i)) { $coding[$i] } else { 'not_coded' }
    $lab   = if ($label.ContainsKey($code)) { $label[$code][0] } else { $code }
    $fam   = if ($label.ContainsKey($code)) { $label[$code][1] } else { '' }
    $rows += [pscustomobject]@{
        Idx=$i; Code=$code; Label=$lab; Family=$fam
        Rep=$m.DisqBy; Owner=$m.Owner; ProspectId=$m.ProspectId
        DisqAt=$m.DisqAtUtc; PrevStage=$m.PreviousStage
        Source=$m.Source; Industry=$m.Industry; City=$m.City
        TotalCalls=[int]$m.TotalCalls; Outbound=[int]$m.OutboundCalls; Inbound=[int]$m.InboundCalls
        CallAt=$m.CallWhenUtc; Direction=$m.CallDirection; Dur=[int]$m.CallDurationS
        Status=$m.CallStatus; Transcript=$m.Transcript; Recording=$m.Recording
        Quote=$quote; Chars=$body.Length
    }
}
$n = $rows.Count
Write-Output "rows: $n"

$sheets = @()

# ---- 1. Sample set -------------------------------------------------------------------
$s1 = @(foreach ($r in ($rows | Sort-Object Idx)) {
    ,@($r.Idx, $r.ProspectId, $r.Rep, $r.Owner, $r.DisqAt, $r.PrevStage,
       $r.TotalCalls, $r.Outbound, $r.Inbound, $r.Direction, $r.Dur, $r.Status,
       $r.CallAt, $r.Source, $r.Industry, $r.City, $r.Transcript, $r.Recording) })
$sheets += @{ Name='Sample set'
    Headers=@('#','ProspectId','Disqualified by','Owner','Disqualified at (UTC)','Stage before',
        'Total calls','Outbound','Inbound','The call','Duration sec','Status','Call at (UTC)',
        'Source','Industry','City','Transcript URL','Recording URL')
    Rows=$s1
    ColWidths=@(5,38,20,20,21,16,11,10,9,10,12,11,21,20,20,14,60,60) }

# ---- 2. Master: 200 contacts + the reason found ---------------------------------------
$s2 = @(foreach ($r in ($rows | Sort-Object Family, Label, Idx)) {
    ,@($r.Idx, $r.Rep, $r.Label, $r.Family, $r.Code, $r.Dur, $r.Direction,
       $r.PrevStage, $r.ProspectId, $r.Quote, $r.Transcript) })
$sheets += @{ Name='Master - 200 with reason'
    Headers=@('#','Rep','Reason found in the call','Family','Code','Call sec','Direction',
        'Stage before','ProspectId','What the customer actually said (end of call)','Transcript URL')
    Rows=$s2
    ColWidths=@(5,20,42,28,30,10,11,16,38,90,60) }

# ---- 3. Summary: rep x reason ---------------------------------------------------------
$reps    = @($rows | Group-Object Rep | Sort-Object Count -Descending | ForEach-Object { $_.Name })
$reasons = @($rows | Group-Object Label | Sort-Object Count -Descending | ForEach-Object { $_.Name })
$hdr = @('Rep') + $reasons + @('TOTAL')
$s3 = @()
foreach ($rep in $reps) {
    $sub = @($rows | Where-Object { $_.Rep -eq $rep })
    $line = @($rep)
    foreach ($rn in $reasons) { $line += @($sub | Where-Object { $_.Label -eq $rn }).Count }
    $line += $sub.Count
    $s3 += ,$line
}
$tot = @('TOTAL')
foreach ($rn in $reasons) { $tot += @($rows | Where-Object { $_.Label -eq $rn }).Count }
$tot += $n
$s3 += ,$tot
$pctLine = @('% of 200')
foreach ($rn in $reasons) { $pctLine += (Pct (@($rows | Where-Object { $_.Label -eq $rn }).Count) $n) }
$pctLine += 100
$s3 += ,$pctLine
$sheets += @{ Name='Summary - rep x reason'; Headers=$hdr; Rows=$s3
    ColWidths=@(22) + (1..$reasons.Count | ForEach-Object { 17 }) + @(10) }

# ---- 4. Summary by reason -------------------------------------------------------------
$s4 = @(foreach ($g in ($rows | Group-Object Label | Sort-Object Count -Descending)) {
    $fam = ($g.Group | Select-Object -First 1).Family
    $md  = [math]::Round((($g.Group | Measure-Object Dur -Average).Average), 0)
    ,@($g.Name, $fam, $g.Count, (Pct $g.Count $n), $md,
       (($g.Group | Group-Object Rep | Sort-Object Count -Descending | Select-Object -First 1).Name)) })
$sheets += @{ Name='Summary - by reason'
    Headers=@('Reason found in the call','Family','Contacts','% of 200','Mean call sec','Most common rep')
    Rows=$s4; ColWidths=@(44,30,11,11,14,22) }

# Family rollup appended as its own small sheet - it is the number worth quoting.
$s4b = @(foreach ($g in ($rows | Group-Object Family | Sort-Object Count -Descending)) {
    ,@($g.Name, $g.Count, (Pct $g.Count $n)) })
$sheets += @{ Name='Summary - by family'
    Headers=@('Family','Contacts','% of 200'); Rows=$s4b; ColWidths=@(34,12,12) }

# ---- 5. Method -------------------------------------------------------------------------
$famNoReason = @($rows | Where-Object { $_.Family -eq 'No reason obtainable' }).Count
$famNever    = @($rows | Where-Object { $_.Family -eq 'Should never have been called' }).Count
$famOurs     = @($rows | Where-Object { $_.Family -eq 'Our own process' }).Count
$famGenuine  = @($rows | Where-Object { $_.Family -like 'Genuine*' }).Count
$m = @(
    @('SAMPLE DEFINITION','',''),
    @('Contact stage','Disqualified',''),
    @('Disqualification reason','Not Interested - No Reason Stated','the 25,626-contact bucket'),
    @('Connected calls','exactly 1','outbound EC22 + inbound EC21, duration > 0, whole history'),
    @('Transcript','present on that call','mx_Custom_10 on the call activity'),
    @('','',''),
    @('HOW THE POOL WAS BUILT','',''),
    @('Contacts on this reason','25626','from the live scan of all 91,056 contacts'),
    @('...whose LAST activity was a phone call since 1 Jul','1965','the affordable slice - no bulk activity read exists'),
    @('...trails scanned','1965','one API call each, 0 failures'),
    @('...with exactly 1 connected call','723',''),
    @('...and that call transcribed','314','the qualifying pool'),
    @('Sampled','200','random, fixed seed, reproducible'),
    @('','',''),
    @('WHAT THE 200 CALLS SHOW','',''),
    @('No reason was obtainable','' + $famNoReason, "$(Pct $famNoReason $n)% - refused on the spot, or no real conversation happened"),
    @('Should never have been called','' + $famNever, "$(Pct $famNever $n)% - wrong person, no marketing, closed, or cannot advertise"),
    @('A genuine commercial reason','' + $famGenuine, "$(Pct $famGenuine $n)% - price, fit, roster, competitor, agency"),
    @('Our own process lost it','' + $famOurs, "$(Pct $famOurs $n)% - asked for material or a callback, or had opted out"),
    @('','',''),
    @('LIMITS','',''),
    @('Transcription is not universal','314 of 723','so this reads the transcribed slice of the one-call population'),
    @('Rep mix is skewed by that','','4 reps carry most transcribed calls - read rep x reason as a profile, not a league table'),
    @('Coding is judgement','','each call was read in full; the quote column lets you check any row'),
    @('Direction','189 outbound / 11 inbound','inbound are returned missed calls')
)
$sheets += @{ Name='Method'; Headers=@('Item','Value','Note'); Rows=$m; ColWidths=@(50,36,62) }

New-XlsxWorkbook -Sheets $sheets -Path $OutPath | Out-Null
foreach ($s in $sheets) { Write-Output ("  {0,-26} {1,5} rows" -f $s.Name, $s.Rows.Count) }
Write-Output ""
Write-Output "Workbook: $OutPath"
Write-Output ("Size: {0:N0} KB" -f ((Get-Item $OutPath).Length / 1KB))
Write-LsqLog "saved $OutPath" $logPath
