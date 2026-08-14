<#
.SYNOPSIS
  READ-ONLY. One full-book scan capturing every column the "why do leads not buy" analysis
  needs, tallied live rather than read from the 2-day-old warehouse book snapshot.

.DESCRIPTION
  Asked for 2026-08-13: of ~90k contacts, ~60k are Disqualified and 98% carry a reason.
  Is that a lead-quality/ICP problem, a prospecting problem, or a product/pricing problem?

  A single scan, not several. Every previous field enumeration in this repo paged all 91k
  leads to tally ONE field; the analysis below needs eleven, and the account-wide rate limit
  (20 calls / 5 sec) makes eleven scans eleven times the wall clock for no extra information.

  RECONCILIATION (hard rule 4). The tally is only trustworthy if the per-value counts sum to
  the record total, and the record total matches an independent figure. Both are asserted:
  the sum-vs-total check below, and the caller comparing TOTAL to the warehouse's 90,796.

  NEGATIVE CONTROL (hard rule 1). A filter that must return zero rows is run first. If it
  returns anything, the filter is not doing what it claims and no number below is safe.

  Writes one row per contact to data/ for the cross-tab work, plus console tallies.

.EXAMPLE
  powershell.exe -File .\scripts\reports\disqualification-deep-dive.ps1
#>

param(
    [int]$PageSize = 1000,
    [switch]$SkipNegativeControl
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$outPath = Join-Path $dataDir "disq_deep_dive_$stamp.json"
$logPath = Join-Path $dataDir "disq_deep_dive_log.txt"

Write-LsqLog "=== disqualification-deep-dive start ($stamp) ===" $logPath

# Every column the analysis needs. mx_Previous_Contact_Stage is what makes "disqualified
# from WHERE" answerable for the historic pile - the stage-history table only reaches back
# to 1 Aug, this field was backfilled across all 87,038 contacts by migration 09/10.
$cols = @(
    "ProspectID"
    "OwnerIdName"
    "ProspectStage"
    "mx_Previous_Contact_Stage"
    "mx_Disqualification_Reason"
    "mx_Disqualification_Category"
    "mx_Call_Disposition"
    "Source"
    "mx_Category"
    "mx_Ads"
    "mx_City"
    "CreatedOn"
    "ProspectActivityDate_Max"
    "ProspectActivityName_Max"
    "ModifiedOn"
) -join ","

# ---------------------------------------------------------------------------------------
# Negative control. A stage string that cannot exist must return zero rows. If this returns
# anything, the ProspectStage filter is being ignored (gotcha 1 - Leads.Get silently drops a
# Query wrapper and returns the whole account), and every count below would be the full book.
# ---------------------------------------------------------------------------------------
if (-not $SkipNegativeControl) {
    $nc = Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "ProspectStage"; LookupValue = "ZZ_NoSuchStage_ZZ"; SqlOperator = "="
    } -ColumnsCsv "ProspectID" -PageSize 10)
    if ($nc.Count -ne 0) {
        throw "NEGATIVE CONTROL FAILED: impossible stage returned $($nc.Count) rows. Filter is not applied - abort."
    }
    Write-LsqLog "Negative control passed (impossible stage -> 0 rows)." $logPath
}

# ---------------------------------------------------------------------------------------
# Full scan.
# ---------------------------------------------------------------------------------------
$rows  = New-Object System.Collections.Generic.List[object]
$page  = 1
$total = 0

Write-Output "Scanning full book, $PageSize/page..."
while ($true) {
    $resp = Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">"
    } -ColumnsCsv $cols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize $PageSize)

    if (-not $resp -or $resp.Count -eq 0) { break }

    foreach ($l in $resp) {
        $total++
        $rows.Add([pscustomobject]@{
            Id          = "$($l.ProspectID)"
            Owner       = "$($l.OwnerIdName)".Trim()
            Stage       = "$($l.ProspectStage)".Trim()
            PrevStage   = "$($l.mx_Previous_Contact_Stage)".Trim()
            Reason      = "$($l.mx_Disqualification_Reason)".Trim()
            Category    = "$($l.mx_Disqualification_Category)".Trim()
            Disposition = "$($l.mx_Call_Disposition)".Trim()
            Source      = "$($l.Source)".Trim()
            Industry    = "$($l.mx_Category)".Trim()
            Ads         = "$($l.mx_Ads)".Trim()
            City        = "$($l.mx_City)".Trim()
            CreatedOn   = "$($l.CreatedOn)"
            LastActAt   = "$($l.ProspectActivityDate_Max)"
            LastActName = "$($l.ProspectActivityName_Max)".Trim()
            ModifiedOn  = "$($l.ModifiedOn)"
        })
    }

    if ($total % 10000 -lt $PageSize) { Write-LsqLog "  ...$total contacts" $logPath }
    if ($resp.Count -lt $PageSize) { break }
    $page++
    Start-Sleep -Milliseconds 250
}

Write-LsqLog "Scan complete: $total contacts over $page pages." $logPath

# ---------------------------------------------------------------------------------------
# Tallies. Every one reconciles against $total.
# ---------------------------------------------------------------------------------------
function Tally($rows, $prop) {
    $h = @{}
    foreach ($r in $rows) {
        $v = "$($r.$prop)"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = "<BLANK>" }
        if ($h.ContainsKey($v)) { $h[$v]++ } else { $h[$v] = 1 }
    }
    return $h
}

function Show($title, $h, $denom) {
    Write-Output ""
    Write-Output "--- $title ---"
    $sum = 0
    $h.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        $sum += $_.Value
        Write-Output ("{0,8}  {1,6:N1}%  [{2}]" -f $_.Value, (100.0 * $_.Value / $denom), $_.Key)
    }
    Write-Output ("{0,8}  TOTAL (reconciles: {1})" -f $sum, ($sum -eq $denom))
}

Write-Output ""
Write-Output "TOTAL CONTACTS SCANNED: $total"

$stages = Tally $rows "Stage"
Show "Contact Stage, whole book" $stages $total

$disq = @($rows | Where-Object { $_.Stage -eq "Disqualified" })
Write-Output ""
Write-Output "DISQUALIFIED: $($disq.Count)  ($([math]::Round(100.0*$disq.Count/$total,1))% of book)"

Show "Disqualification Reason (disqualified only)"   (Tally $disq "Reason")      $disq.Count
Show "Disqualification Category (disqualified only)" (Tally $disq "Category")    $disq.Count
Show "Previous Contact Stage (disqualified only)"    (Tally $disq "PrevStage")   $disq.Count
Show "Call Disposition (disqualified only)"          (Tally $disq "Disposition") $disq.Count
Show "Last Activity Name (disqualified only)"        (Tally $disq "LastActName") $disq.Count

# Reason x Category, to expose reasons carrying more than one category (a sign the pair was
# entered by hand rather than derived, which is the whole question this run is asking).
Write-Output ""
Write-Output "--- Reason x Category (disqualified only) ---"
$rc = @{}
foreach ($r in $disq) {
    $k = "$(if($r.Reason){$r.Reason}else{'<BLANK>'})||$(if($r.Category){$r.Category}else{'<BLANK>'})"
    if ($rc.ContainsKey($k)) { $rc[$k]++ } else { $rc[$k] = 1 }
}
$rc.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    $p = $_.Key -split '\|\|', 2
    Write-Output ("{0,8}  [{1}]  ->  [{2}]" -f $_.Value, $p[0], $p[1])
}

$rows | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $outPath -Encoding UTF8
Write-LsqLog "Per-contact rows written to $outPath" $logPath
Write-Output ""
Write-Output "Per-contact rows: $outPath"
