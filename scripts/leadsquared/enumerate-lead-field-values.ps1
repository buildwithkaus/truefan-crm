<#
.SYNOPSIS
  Read-only: enumerate the REAL stored values of any Lead field, by paginating every lead
  and tallying what is actually there. Never probes a guessed list of strings.

.DESCRIPTION
  Written after the 2026-07-28 incident in which a migration script probed
  ProspectStage = "Invalid/Junk" and "Just Enquiring No Intent", got 0 rows for both, and
  believed it. The real strings were "Invalid/ Junk" (space after the slash) and
  "Just Enquiring, No Intent" (comma) - 20,076 leads were silently skipped. See CLAUDE.md
  and memory/01-lead-schema-audit.md.

  The tally is only trustworthy if it reconciles to the total record count, so this script
  always reports the total and the blank count alongside the value distribution. If the sum
  of the per-value counts does not equal the total, something was missed - do not proceed.

  Use this to generate migration worklists. Do NOT hand-write stage strings into a script.

.PARAMETER FieldName
  Lead field schema name to enumerate, e.g. ProspectStage, mx_Call_Disposition, Source.

.PARAMETER GroupByOwner
  Also emit a Field x OwnerIdName cross-tab.

.EXAMPLE
  pwsh ./scripts/leadsquared/enumerate-lead-field-values.ps1 -FieldName ProspectStage -GroupByOwner
#>

param(
    [string]$FieldName = "ProspectStage",
    [switch]$GroupByOwner
)

. "$PSScriptRoot\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outPath = Join-Path $dataDir "field_values_$($FieldName)_$stamp.json"

$columns = "ProspectID,$FieldName"
if ($GroupByOwner) { $columns += ",OwnerIdName" }

$total = 0
$blank = 0
$counts = @{}
$pairs = @{}
$rows = @()
$page = 1

Write-Output "Enumerating '$FieldName' across all leads (paginated, 1000/page)..."
while ($true) {
    # Filter matches everything; Leads.Get needs the singular Parameter shape, not Query.
    $resp = Invoke-LsqLeadSearch -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv $columns -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000
    if (-not $resp -or $resp.Count -eq 0) { break }

    foreach ($lead in $resp) {
        $total++
        $v = $lead.$FieldName
        if ([string]::IsNullOrWhiteSpace($v)) { $blank++; $v = "<BLANK>" }
        if ($counts.ContainsKey($v)) { $counts[$v]++ } else { $counts[$v] = 1 }

        if ($GroupByOwner) {
            $o = $lead.OwnerIdName
            if ([string]::IsNullOrWhiteSpace($o)) { $o = "<NONE>" }
            $key = "$v||$o"
            if ($pairs.ContainsKey($key)) { $pairs[$key]++ } else { $pairs[$key] = 1 }
        }
        $rows += [pscustomobject]@{ ProspectId = $lead.ProspectID; Value = $v }
    }

    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}

$sum = 0
foreach ($k in $counts.Keys) { $sum += $counts[$k] }

Write-Output ""
Write-Output "TOTAL LEADS:      $total"
Write-Output "BLANK/NULL:       $blank"
Write-Output "DISTINCT VALUES:  $($counts.Count)"
Write-Output "SUM OF COUNTS:    $sum"
if ($sum -ne $total) {
    Write-Output "*** RECONCILIATION FAILED - sum ($sum) != total ($total). DO NOT TRUST THIS OUTPUT. ***"
} else {
    Write-Output "Reconciliation OK (sum == total)."
}

Write-Output ""
Write-Output "--- Distinct values, exact strings, descending ---"
$counts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Output ("{0,8}  [{1}]" -f $_.Value, $_.Key)
}

if ($GroupByOwner) {
    Write-Output ""
    Write-Output "--- Value x Owner ---"
    $pairs.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        $parts = $_.Key -split '\|\|', 2
        Write-Output ("{0,8}  [{1}]  {2}" -f $_.Value, $parts[0], $parts[1])
    }
}

# Square brackets above delimit each value so trailing/leading spaces are visible - the
# exact failure mode this script exists to catch.
$rows | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath
Write-Output ""
Write-Output "Per-record values written to $outPath (use this to build migration worklists)."
