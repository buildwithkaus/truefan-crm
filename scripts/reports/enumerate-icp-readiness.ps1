<#
.SYNOPSIS
  READ-ONLY. Fill rate and real value vocabulary for every candidate ICP field, in ONE pass
  over the book. The gate that decides whether ICP analysis is possible or whether the ICP
  work is really an enrichment project.

.DESCRIPTION
  Nothing in this repo has ever read mx_Ads, mx_Category, mx_Categoey, mx_Sub_Sector or
  mx_Business_Location. They are referenced by no script, no memory file and no doc. Their
  fill rate and value vocabulary are unknown, and mx_Ads in particular is a free-text
  Textbox(50) rather than the Yes/No dropdown it is assumed to be.

  Building an "ads vs no-ads conversion" view on a field that turns out to be 2% filled
  would produce a confident, wrong answer - the exact failure mode CLAUDE.md rule 2 exists
  to prevent. This script answers the question first.

  WHY ONE SCAN, NOT ONE PER FIELD. enumerate-lead-field-values.ps1 pages the whole book per
  field. Fourteen fields would be fourteen full scans (~1,270 API calls) for data that one
  scan can return, because Leads.Get takes an arbitrary column list. This is ~91 calls.

  THREE GUARDS, because a missing column and an empty column look identical:
    1. Every requested field is confirmed against live LeadsMetaData.Get first. The cached
       data/lead_fields_schema.json is dated 2026-07-27 and predates the migration fields.
    2. Every requested column is confirmed to have come back on a real row. Leads.Get
       silently returns FEWER columns rather than erroring on a name it does not know, so a
       typo would otherwise read as "this field is 0% filled" - a wrong finding that looks
       exactly like a real one.
    3. The scan is guarded against an absolute expected size from an independent source.

  For dropdown fields it also compares stored values against the live selectable options.
  LSQ stores values that are not in the dropdown; they read back fine over the API while
  being invisible to every rep filter. That once made 61,919 leads unfilterable.

.PARAMETER TopValues
  How many distinct values to report per field.

.EXAMPLE
  powershell.exe -File scripts\reports\enumerate-icp-readiness.ps1
  powershell.exe -File scripts\reports\enumerate-icp-readiness.ps1 -MaxPages 3   # smoke test

.NOTES
  ASCII only. Read-only. Do NOT run concurrently with another LSQ script - the rate limit is
  account-wide (20 calls / 5 sec) and a collision produces transient failures in both.
#>

[CmdletBinding()]
param(
    [int]$TopValues = 25,
    [int]$MinExpectedLeads = 80000,
    [int]$MaxPages = 300
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "icp_readiness_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"

# ---------------------------------------------------------------------------------------
# The candidate ICP dimensions. Firmographics first, then the ones already known to be thin
# (kept in so the report states their fill rate rather than leaving a gap someone has to
# re-derive), then the geography and the two identifiers the funnel needs to join on.
# ---------------------------------------------------------------------------------------
$icpFields = @(
    "mx_Ads"
    "mx_Category"
    "mx_Categoey"                  # a real typo-duplicate field, not a mistake in this list
    "mx_Industry_Type"
    "mx_Sub_Sector"
    "mx_Business_Location"
    "mx_Company_revenue"
    "mx_Marketing_Budget_monthly"
    "mx_Budget"
    "mx_Business_Model"
    "mx_Qualified_Business"
    "mx_Segment"
    "mx_Designation"
    "mx_Selected_Product"
    "mx_City"
    "mx_State"
    "mx_Country"
)
# Carried for slicing, not measured as ICP fields in their own right.
$contextFields = @("ProspectID", "ProspectStage", "Source", "OwnerIdName", "RelatedCompanyId")

Write-LsqLog "" $logPath
Write-LsqLog "=== ICP field readiness $stamp (READ-ONLY) ===" $logPath


# =======================================================================================
# GUARD 1. Confirm every field exists live, and capture dropdown options while we are here.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- Live field metadata ---" $logPath

$cfg = Import-LsqConfig
$metaUri = "$($cfg['LSQ_API_HOST'])/LeadManagement.svc/LeadsMetaData.Get?accessKey=$($cfg['LSQ_ACCESS_KEY'])&secretKey=$($cfg['LSQ_SECRET_KEY'])"
# Invoke-WebRequest then ConvertFrom-Json, never Invoke-RestMethod (gotcha 19).
$metaRaw = Invoke-LsqWithRetry -What "LeadsMetaData.Get" -Action {
    Invoke-WebRequest -Uri $metaUri -Method Get -UseBasicParsing -ErrorAction Stop
}
$allFields = $metaRaw.Content | ConvertFrom-Json
Write-LsqLog "  live lead fields: $(@($allFields).Count)" $logPath

$meta = @{}
foreach ($f in $allFields) { $meta["$($f.SchemaName)"] = $f }

$missing = New-Object System.Collections.Generic.List[string]
foreach ($f in $icpFields) { if (-not $meta.ContainsKey($f)) { [void]$missing.Add($f) } }
if ($missing.Count -gt 0) {
    Write-LsqLog "  NOT PRESENT LIVE (dropped from the scan): $($missing.ToArray() -join ', ')" $logPath
}
$icpFields = @($icpFields | Where-Object { $meta.ContainsKey($_) })
Write-LsqLog "  measuring $($icpFields.Count) ICP fields" $logPath

foreach ($f in $icpFields) {
    $m = $meta[$f]
    Write-LsqLog ("    {0,-30} {1,-14} {2}" -f $f, "$($m.DataType)", "$($m.DisplayName)") $logPath
}

function Get-FieldOptions {
    <#
      PURE. Returns the selectable option strings for a dropdown field, or an empty array.
      LSQ hands the option list back in more than one shape depending on the field, so this
      tries each rather than assuming - an empty result here must mean "no options", not
      "we looked in the wrong place".
    #>
    param([Parameter(Mandatory)]$FieldMeta)
    $raw = $FieldMeta.Options
    if ($null -eq $raw) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    if ($raw -is [string]) {
        $s = $raw.Trim()
        if (-not $s) { return @() }
        # Either a JSON array of objects, or a plain delimited string.
        if ($s.StartsWith("[")) {
            try {
                foreach ($o in ($s | ConvertFrom-Json)) {
                    $v = "$($o.Value)"; if (-not $v) { $v = "$($o.Text)" }; if (-not $v) { $v = "$o" }
                    if ($v) { [void]$out.Add($v) }
                }
            } catch { }
        } else {
            foreach ($p in ($s -split "[;,|]")) { $t = $p.Trim(); if ($t) { [void]$out.Add($t) } }
        }
    } elseif ($raw -is [System.Collections.IEnumerable]) {
        foreach ($o in $raw) {
            $v = "$($o.Value)"; if (-not $v) { $v = "$($o.Text)" }; if (-not $v) { $v = "$o" }
            if ($v) { [void]$out.Add($v) }
        }
    }
    return $out.ToArray()
}


# =======================================================================================
# Negative control, then the scan.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- Scan ---" $logPath

$negRows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "CreatedOn"; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">"
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Write-LsqLog "  negative control: $($negRows.Count) rows -- must be 0" $logPath
if ($negRows.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the filter is being ignored." }

$cols = (@($contextFields) + @($icpFields)) -join ","

# tallies[field] = @{ Filled; Values = @{ value -> count }; IcpFilled }
$tallies = @{}
foreach ($f in $icpFields) { $tallies[$f] = @{ Filled = 0; IcpFilled = 0; Values = @{} } }

$total = 0
$icpTotal = 0
$page = 1
$columnsSeen = $null

while ($page -le $MaxPages) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "CreatedOn"; LookupValue = "2000-01-01 00:00:00"; SqlOperator = ">"
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }

    # GUARD 2, on the first real row only. A column Leads.Get did not recognise is simply
    # absent from the payload; without this it would tally as 0% filled and read as a real
    # finding rather than as a typo.
    if ($null -eq $columnsSeen) {
        $columnsSeen = @($rows[0].PSObject.Properties.Name)
        $absent = @($icpFields | Where-Object { $columnsSeen -notcontains $_ })
        if ($absent.Count -gt 0) {
            throw "Leads.Get did not return these requested columns: $($absent -join ', '). They would have tallied as 0% filled. Fix the names before trusting anything."
        }
        Write-LsqLog "  all $($icpFields.Count) requested columns present in the payload" $logPath
    }

    foreach ($r in $rows) {
        $total++
        $isIcp = ("$($r.Source)" -eq "Kaustubh ICP")
        if ($isIcp) { $icpTotal++ }

        foreach ($f in $icpFields) {
            $v = "$($r.$f)".Trim()
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            $t = $tallies[$f]
            $t.Filled++
            if ($isIcp) { $t.IcpFilled++ }
            if ($t.Values.ContainsKey($v)) { $t.Values[$v] = $t.Values[$v] + 1 } else { $t.Values[$v] = 1 }
        }
    }

    if ($page % 20 -eq 0) { Write-LsqLog "    page $page -> $total leads" $logPath }
    if ($rows.Count -lt 1000) { break }
    $page++
}

Write-LsqLog "  scanned $total leads across $page pages ($icpTotal on Source = 'Kaustubh ICP')" $logPath

# GUARD 3. Absolute floor from an independent source. A truncated scan reconciles perfectly
# against itself, which is exactly how a one-page scan once reported as a full sweep.
if ($MaxPages -ge 300 -and $total -lt $MinExpectedLeads) {
    throw "Scanned only $total leads, expected at least $MinExpectedLeads. Refusing to report fill rates from a partial scan."
}
if ($MaxPages -lt 300) {
    Write-LsqLog "  NOTE: -MaxPages $MaxPages - this is a SMOKE TEST, not a population measurement." $logPath
}


# =======================================================================================
# Report
# =======================================================================================
function ConvertTo-ReadinessRow {
    <#
      PURE. Turns one field's tally into a report row, including the dropdown-drift check.
      Writes nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][hashtable]$Tally,
        [Parameter(Mandatory)]$FieldMeta,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][int]$IcpTotal,
        [Parameter(Mandatory)][int]$TopValues
    )
    $options = Get-FieldOptions -FieldMeta $FieldMeta
    $stored  = @($Tally.Values.Keys)
    $notSelectable = @()
    if ($options.Count -gt 0) {
        $notSelectable = @($stored | Where-Object { $options -notcontains $_ })
    }

    $top = New-Object System.Collections.Generic.List[object]
    foreach ($kv in ($Tally.Values.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $TopValues)) {
        [void]$top.Add([pscustomobject]@{
            Value = $kv.Name
            Count = $kv.Value
            Selectable = $(if ($options.Count -eq 0) { "n/a" } elseif ($options -contains $kv.Name) { "yes" } else { "NO" })
        })
    }

    return [pscustomobject]@{
        Field           = $Field
        DisplayName     = "$($FieldMeta.DisplayName)"
        DataType        = "$($FieldMeta.DataType)"
        Filled          = $Tally.Filled
        FillPct         = $(if ($Total -gt 0) { [math]::Round(100.0 * $Tally.Filled / $Total, 2) } else { 0 })
        IcpFilled       = $Tally.IcpFilled
        IcpFillPct      = $(if ($IcpTotal -gt 0) { [math]::Round(100.0 * $Tally.IcpFilled / $IcpTotal, 2) } else { 0 })
        DistinctValues  = $Tally.Values.Count
        DropdownOptions = $options.Count
        NotSelectable   = $notSelectable.Count
        TopValues       = $top.ToArray()
    }
}

$report = New-Object System.Collections.Generic.List[object]
foreach ($f in $icpFields) {
    [void]$report.Add((ConvertTo-ReadinessRow -Field $f -Tally $tallies[$f] -FieldMeta $meta[$f] `
        -Total $total -IcpTotal $icpTotal -TopValues $TopValues))
}
$rows = $report.ToArray()

Write-LsqLog "" $logPath
Write-LsqLog ("  {0,-30} {1,10} {2,8} {3,9} {4,9} {5,8}" -f "field", "filled", "fill%", "ICP fill%", "distinct", "not-sel") $logPath
foreach ($r in ($rows | Sort-Object FillPct -Descending)) {
    Write-LsqLog ("  {0,-30} {1,10} {2,7}% {3,8}% {4,9} {5,8}" -f `
        $r.Field, $r.Filled, $r.FillPct, $r.IcpFillPct, $r.DistinctValues, $r.NotSelectable) $logPath
}

$jsonPath = Join-Path $dataDir "icp_readiness_$stamp.json"
$mdPath   = Join-Path $dataDir "icp_readiness_summary_$stamp.md"

@{
    Stamp = $stamp; ScannedLeads = $total; IcpSourceLeads = $icpTotal
    Partial = ($MaxPages -lt 300); Fields = $rows
} | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# ICP field readiness - $stamp")
[void]$md.Add("")
if ($MaxPages -lt 300) { [void]$md.Add("> **SMOKE TEST** - only $page pages scanned. Not a population measurement.") ; [void]$md.Add("") }
[void]$md.Add("Scanned **$total** leads, of which **$icpTotal** carry ``Source = 'Kaustubh ICP'``.")
[void]$md.Add("")
[void]$md.Add("A field below 20% fill cannot carry a conversion cut on its own. ``not-sel`` counts stored")
[void]$md.Add("values that are NOT selectable in the dropdown - those are invisible to every rep filter.")
[void]$md.Add("")
[void]$md.Add("| Field | Display | Type | Filled | Fill % | ICP fill % | Distinct | Options | Not selectable |")
[void]$md.Add("|---|---|---|---|---|---|---|---|---|")
foreach ($r in ($rows | Sort-Object FillPct -Descending)) {
    [void]$md.Add("| ``$($r.Field)`` | $($r.DisplayName) | $($r.DataType) | $($r.Filled) | $($r.FillPct)% | $($r.IcpFillPct)% | $($r.DistinctValues) | $($r.DropdownOptions) | $($r.NotSelectable) |")
}
[void]$md.Add("")
foreach ($r in ($rows | Sort-Object FillPct -Descending)) {
    [void]$md.Add("## ``$($r.Field)`` - $($r.DisplayName)")
    [void]$md.Add("")
    [void]$md.Add("$($r.Filled) filled ($($r.FillPct)%), $($r.DistinctValues) distinct values.")
    [void]$md.Add("")
    if ($r.TopValues.Count -eq 0) {
        [void]$md.Add("**Empty across the whole scan.** Not usable as an ICP dimension.")
    } else {
        [void]$md.Add("| Value | Leads | Selectable |")
        [void]$md.Add("|---|---|---|")
        foreach ($v in $r.TopValues) {
            [void]$md.Add("| $($v.Value) | $($v.Count) | $($v.Selectable) |")
        }
        if ($r.DistinctValues -gt $r.TopValues.Count) {
            [void]$md.Add("")
            [void]$md.Add("_...and $($r.DistinctValues - $r.TopValues.Count) more distinct values._")
        }
    }
    [void]$md.Add("")
}

($md.ToArray() -join "`r`n") | Set-Content -Path $mdPath -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "Wrote:" $logPath
Write-LsqLog "  $jsonPath" $logPath
Write-LsqLog "  $mdPath" $logPath
