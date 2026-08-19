<#
.SYNOPSIS
  For every Opportunity dropdown field, check that each STORED value is actually selectable -
  and report options nothing uses. READ-ONLY.

.DESCRIPTION
  Hard rule 8 says to run a dropdown-coverage check after writing any dropdown field. Until now
  that rule could not be satisfied for the Opportunity object at all:
  scripts/reports/verify-dropdown-coverage.ps1 reads LeadManagement.svc/LeadsMetaData.Get and
  covers LEAD fields only. It cannot see mx_Custom_2 (Stage) or Status.

  That is not a hypothetical gap - the stored-value-not-in-the-dropdown bug was FIRST PROVEN on
  Opportunity mx_Custom_2 on 2026-07-29. LeadSquared accepts the write, the API reads it back
  cleanly, and the record is invisible to any rep filtering on that dropdown.

  WHERE THE OPTION LIST COMES FROM
  --------------------------------
  There is no opportunity field-metadata endpoint in the usual sense, but GetOpportunityDetails
  returns DisplayName and DataType per field, which identifies which fields ARE dropdowns
  (DataType 'SearchableDropdown'). It does NOT return their option lists.

  So the selectable options come from the taxonomy this repo already maintains -
  $Script:OpportunityStages in scripts/lib/schema.ps1 - which is the set the UI is supposed to
  offer. A stored value outside it is either drift or a taxonomy that has moved on without
  schema.ps1 being updated; both need a human, and both are reported here rather than guessed at.

  NOTE 'Requirement Gathering' is a REAL current warm stage on the Opportunity (gotcha 26) even
  though it is absent from $Script:OpportunityStages, which describes the target taxonomy. It is
  treated as known-and-expected rather than as drift, and called out separately.

.EXAMPLE
  powershell.exe -File scripts\reports\verify-opportunity-dropdown-coverage.ps1

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31). Reads the warehouse, not the API - one query
  instead of one call per deal.
#>

param(
    [string]$ScanFile = "",
    [switch]$UseWarehouse
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_dropdown_coverage_log.txt"
$cfg = Import-LsqConfig

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

Write-LsqLog "" $logPath
Write-LsqLog "=== Opportunity dropdown coverage (READ-ONLY) ===" $logPath

# Selectable sets, from the maintained taxonomy.
$statusOptions = @($Script:OpportunityStages.Keys)
$stageOptions  = New-Object System.Collections.Generic.List[string]
foreach ($k in $Script:OpportunityStages.Keys) {
    foreach ($v in $Script:OpportunityStages[$k]) { [void]$stageOptions.Add($v) }
}
# Live-but-not-in-the-target-taxonomy. Known, expected, not drift.
$knownExtraStages = @("Requirement Gathering")

Write-LsqLog "Selectable Status : $($statusOptions -join ', ')" $logPath
Write-LsqLog "Selectable Stage  : $($stageOptions -join ', ')" $logPath
Write-LsqLog "Known extra stage : $($knownExtraStages -join ', ')  (live warm stage, gotcha 26)" $logPath

# ---------------------------------------------------------------------------------------
# Stored values
# ---------------------------------------------------------------------------------------
$rows = @()
if (-not $UseWarehouse) {
    if (-not $ScanFile) {
        $newest = Get-ChildItem (Join-Path $dataDir "opportunity_scan_*.json") -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) { $ScanFile = $newest.FullName }
    }
    if ($ScanFile -and (Test-Path $ScanFile)) {
        Write-LsqLog "Source: scan file $ScanFile" $logPath
        $rows = @((Read-Utf8Json $ScanFile).Deals | ForEach-Object {
            [pscustomobject]@{ stage = "$($_.OppStage)"; status = "$($_.Status)"; id = "$($_.OpportunityId)" } })
    }
}
if ($rows.Count -eq 0) {
    Write-LsqLog "Source: warehouse fact_opportunity" $logPath
    $sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/'); $sbKey = $cfg['SUPABASE_SERVICE_KEY']
    $hdr = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }
    $out = New-Object System.Collections.Generic.List[object]; $offset = 0
    while ($true) {
        $page = (Invoke-WebRequest -Uri "$sbUrl/rest/v1/fact_opportunity?select=activity_id,stage,status&limit=1000&offset=$offset" -Headers $hdr -UseBasicParsing).Content | ConvertFrom-Json
        $n = @($page).Count; if ($n -eq 0) { break }
        foreach ($r in $page) { [void]$out.Add([pscustomobject]@{ stage = "$($r.stage)"; status = "$($r.status)"; id = "$($r.activity_id)" }) }
        if ($n -lt 1000) { break }
        $offset += 1000
    }
    $rows = $out.ToArray()
}
Write-LsqLog "Opportunities examined: $($rows.Count)" $logPath
if ($rows.Count -eq 0) { throw "No opportunities to check - refusing to report 'all clear' from an empty read (a zero result is as suspicious as a weird one)." }

# PURE - returns a result object and logs NOTHING. Write-LsqLog emits to the console as well as
# to the file, so a function that logs and returns hands the caller its log lines bundled with
# the return value (gotcha 12). The caller does the logging.
function Get-CoverageResult {
    param([string]$Property, [string[]]$Options, [string[]]$KnownExtra)
    $tally = @{}
    foreach ($r in $rows) {
        $v = "$($r.$Property)"
        if ([string]::IsNullOrWhiteSpace($v)) { $v = "<BLANK>" }
        if ($tally.ContainsKey($v)) { $tally[$v]++ } else { $tally[$v] = 1 }
    }
    $lines = New-Object System.Collections.Generic.List[object]
    $bad = 0
    foreach ($kv in ($tally.GetEnumerator() | Sort-Object Value -Descending)) {
        $val = $kv.Key
        $verdict = "ok"
        if ($val -eq "<BLANK>") { $verdict = "BLANK" }
        elseif ($Options -contains $val) { $verdict = "ok" }
        elseif ($KnownExtra -contains $val) { $verdict = "known-extra" }
        else { $verdict = "NOT SELECTABLE"; $bad += $kv.Value }
        [void]$lines.Add([pscustomobject]@{ Verdict = $verdict; Value = $val; Count = $kv.Value })
    }
    return @{
        Lines  = $lines.ToArray()
        Bad    = $bad
        Unused = @($Options | Where-Object { -not $tally.ContainsKey($_) })
    }
}

function Write-CoverageReport {
    param([string]$FieldLabel, [hashtable]$Result)
    Write-LsqLog "" $logPath
    Write-LsqLog "--- $FieldLabel ---" $logPath
    foreach ($l in $Result.Lines) {
        Write-LsqLog ("  {0,-16} {1,-26} {2}" -f $l.Verdict, $l.Value, $l.Count) $logPath
    }
    if ($Result.Unused.Count -gt 0) { Write-LsqLog "  options with zero records: $($Result.Unused -join ', ')" $logPath }
    if ($Result.Bad -gt 0) {
        Write-LsqLog "  *** $($Result.Bad) record(s) hold a value reps cannot select or filter on (gotcha 10)." $logPath
    } else {
        Write-LsqLog "  every stored value is selectable." $logPath
    }
}

$stageResult  = Get-CoverageResult "stage"  $stageOptions.ToArray() $knownExtraStages
$statusResult = Get-CoverageResult "status" $statusOptions @()
Write-CoverageReport "Stage (mx_Custom_2)" $stageResult
Write-CoverageReport "Status (Deal Stage)" $statusResult
$badStage  = $stageResult.Bad
$badStatus = $statusResult.Bad

Write-LsqLog "" $logPath
Write-LsqLog "=== summary ===" $logPath
Write-LsqLog "  Stage  : $badStage record(s) not selectable" $logPath
Write-LsqLog "  Status : $badStatus record(s) not selectable" $logPath
if (($badStage + $badStatus) -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "Fix by adding the value in the LSQ UI, or by rewriting those records onto a" $logPath
    Write-LsqLog "canonical value. Until then those deals are invisible to a rep's dropdown filter." $logPath
}
