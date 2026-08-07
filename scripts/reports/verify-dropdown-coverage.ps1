<#
.SYNOPSIS
  For every Lead field the migration writes, checks that each STORED value is actually an option
  in that field's own dropdown - and reports any option that has no records.

.DESCRIPTION
  LeadSquared stores a dropdown value that is not in the dropdown rather than rejecting it
  (proven on Opportunity mx_Custom_2, 2026-07-29). The consequence is silent: the record looks
  fine over the API, but reps cannot select the value and a dropdown filter will not offer it.
  Two fields were left in exactly that state by the migration and were only caught because
  Kaustubh tried to filter and saw nothing:

    * mx_Call_Disposition  - 20,274 leads holding values absent from the dropdown
    * mx_Disqualification_Reason - 62,546 leads, ZERO overlap with the dropdown

  Checking one field at a time by hand is how the second one got missed after the first was
  fixed. This checks them all, every time, in one pass.

  Read-only.

.NOTES
  pwsh ./scripts/leadsquared/migration/16-verify-dropdown-coverage.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_dropdown_coverage_log.txt"

# Every Lead field the migration writes that is backed by a dropdown.
$fields = @(
    "ProspectStage",
    "mx_Call_Disposition",
    "mx_Disqualification_Reason",
    "mx_Disqualification_Category",
    "mx_Segment",
    "mx_Needs_Contact_Resourcing"
)

Write-LsqLog "=== Dropdown coverage check (READ-ONLY) ===" $logPath

$meta = Invoke-RestMethod -Uri (Get-LsqUrl "LeadManagement.svc/LeadsMetaData.Get") -Method Get
$optionsOf = @{}
foreach ($s in $fields) {
    $f = @($meta | Where-Object { "$($_.SchemaName)" -eq $s })
    if ($f.Count -eq 0) { Write-LsqLog "WARNING: field $s not found in live schema" $logPath; continue }
    $optionsOf[$s] = @($f[0].Options | ForEach-Object { "$($_.Value)" } | Where-Object { $_ -ne "" })
}

# One full enumeration covering every field at once.
$MinExpectedLeads = 80000
$tally = @{}
foreach ($s in $fields) { $tally[$s] = @{} }
$total = 0
$page = 1
$cols = "ProspectID," + ($fields -join ",")
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv $cols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) {
        $total++
        foreach ($s in $fields) {
            $v = "$($l.$s)"
            if ([string]::IsNullOrWhiteSpace($v)) { continue }
            if ($tally[$s].ContainsKey($v)) { $tally[$s][$v]++ } else { $tally[$s][$v] = 1 }
        }
    }
    if ($page % 20 -eq 0) { Write-LsqLog "  scanned $total..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Leads scanned: $total" $logPath
if ($total -lt $MinExpectedLeads) { throw "Only $total leads enumerated - refusing to judge coverage from an incomplete scan." }

$problemFields = 0
foreach ($s in $fields) {
    if (-not $optionsOf.ContainsKey($s)) { continue }
    $opts = $optionsOf[$s]
    Write-LsqLog "" $logPath
    Write-LsqLog "=== $s  ($($opts.Count) dropdown options) ===" $logPath

    # Stored values that are NOT options - these are the unfilterable ones.
    $orphanCount = 0
    $orphans = @()
    foreach ($v in $tally[$s].Keys) {
        if ($opts -notcontains $v) { $orphans += $v; $orphanCount += $tally[$s][$v] }
    }
    if ($orphans.Count -gt 0) {
        $problemFields++
        Write-LsqLog ("   STORED BUT NOT IN DROPDOWN - {0} value(s), {1} leads UNFILTERABLE:" -f $orphans.Count, $orphanCount) $logPath
        foreach ($v in ($orphans | Sort-Object { -$tally[$s][$_] })) { Write-LsqLog ("      [{0}] = {1}" -f $v, $tally[$s][$v]) $logPath }
    } else {
        Write-LsqLog "   OK - every stored value is a dropdown option." $logPath
    }

    # Options with no records. Not a fault - just tells you which are dead, and explains a
    # filter that legitimately returns nothing.
    $unused = @($opts | Where-Object { -not $tally[$s].ContainsKey($_) })
    if ($unused.Count -gt 0) {
        Write-LsqLog ("   options with ZERO records ({0}) - a filter on these correctly returns nothing:" -f $unused.Count) $logPath
        foreach ($u in $unused) { Write-LsqLog ("      [{0}]" -f $u) $logPath }
    }
}

Write-LsqLog "" $logPath
if ($problemFields -eq 0) {
    Write-LsqLog "RESULT: every field is clean - all stored values exist in their dropdown." $logPath
} else {
    Write-LsqLog "RESULT: $problemFields field(s) hold values missing from their dropdown. Reps cannot filter those leads." $logPath
}
Write-LsqLog "=== Dropdown coverage check complete ===" $logPath
