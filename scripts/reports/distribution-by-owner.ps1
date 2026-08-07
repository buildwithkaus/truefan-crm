<#
.SYNOPSIS
  READ-ONLY: Contact Stage, Call Disposition, Source, and Disqualification Reason
  distribution, cross-tabbed BY OWNER. Raw pivot tables, not a summarized report.

.DESCRIPTION
  One full paginated Lead scan, then four owner x value pivot tables (rows = owner as
  currently stored on the Lead record, columns = field value, cell = count). No sampling,
  no interpretation - this is the actual stored distribution, sliced by who owns the lead.

.NOTES
  pwsh ./scripts/leadsquared/migration/20-distribution-by-owner.ps1
#>

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "distribution_by_owner_log.txt"

Write-LsqLog "=== Distribution by owner (READ-ONLY) ===" $logPath

$MinExpectedLeads = 88000
$leadCols = "ProspectID,ProspectStage,mx_Call_Disposition,Source,mx_Disqualification_Reason,OwnerId,OwnerIdName"

$leads = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv $leadCols -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$leads.Add($l) }
    if ($page % 20 -eq 0) { Write-LsqLog "  leads scanned: $($leads.Count)..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Total leads scanned: $($leads.Count)" $logPath
if ($leads.Count -lt $MinExpectedLeads) { throw "Only $($leads.Count) leads enumerated (floor $MinExpectedLeads) - refusing to report from an incomplete scan." }

# owner x value pivot. Owner key = OwnerIdName as actually stored (blank -> <BLANK>), not
# normalized against the active-rep reference file - this is the raw current distribution.
function Build-Pivot {
    param([System.Collections.Generic.List[object]]$Items, [string]$Field)
    $pivot = @{}       # owner -> @{ value -> count }
    $ownerTotal = @{}  # owner -> total leads (incl. blank field value)
    $colTotal = @{}    # value -> total across all owners
    foreach ($it in $Items) {
        $owner = "$($it.OwnerIdName)"
        if ([string]::IsNullOrWhiteSpace($owner)) { $owner = "<BLANK OWNER>" }
        if (-not $ownerTotal.ContainsKey($owner)) { $ownerTotal[$owner] = 0 }
        $ownerTotal[$owner]++

        $v = "$($it.$Field)"
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        if (-not $pivot.ContainsKey($owner)) { $pivot[$owner] = @{} }
        if ($pivot[$owner].ContainsKey($v)) { $pivot[$owner][$v]++ } else { $pivot[$owner][$v] = 1 }
        if ($colTotal.ContainsKey($v)) { $colTotal[$v]++ } else { $colTotal[$v] = 1 }
    }
    return [pscustomobject]@{ Pivot = $pivot; OwnerTotal = $ownerTotal; ColTotal = $colTotal }
}

function Write-PivotCsv {
    param([pscustomobject]$P, [string]$Path, [int]$TopNCols = 0)
    $owners = $P.OwnerTotal.Keys | Sort-Object { -$P.OwnerTotal[$_] }
    $cols = $P.ColTotal.Keys | Sort-Object { -$P.ColTotal[$_] }
    if ($TopNCols -gt 0) { $cols = $cols | Select-Object -First $TopNCols }

    $lines = New-Object System.Collections.Generic.List[string]
    $header = @("Owner", "TotalLeads") + $cols
    [void]$lines.Add(($header -join ","))
    foreach ($o in $owners) {
        $row = New-Object System.Collections.Generic.List[string]
        [void]$row.Add('"' + ($o -replace '"', '""') + '"')
        [void]$row.Add("$($P.OwnerTotal[$o])")
        foreach ($c in $cols) {
            $cnt = 0
            if ($P.Pivot.ContainsKey($o) -and $P.Pivot[$o].ContainsKey($c)) { $cnt = $P.Pivot[$o][$c] }
            [void]$row.Add("$cnt")
        }
        [void]$lines.Add(($row -join ","))
    }
    $totalRow = New-Object System.Collections.Generic.List[string]
    [void]$totalRow.Add('"TOTAL"')
    [void]$totalRow.Add("$($leads.Count)")
    foreach ($c in $cols) { [void]$totalRow.Add("$($P.ColTotal[$c])") }
    [void]$lines.Add(($totalRow -join ","))

    $lines | Set-Content -Path $Path
    Write-LsqLog "  wrote $Path ($($owners.Count) owners x $($cols.Count) values)" $logPath
}

$stageP  = Build-Pivot $leads "ProspectStage"
$dispP   = Build-Pivot $leads "mx_Call_Disposition"
$sourceP = Build-Pivot $leads "Source"
$reasonP = Build-Pivot $leads "mx_Disqualification_Reason"

$stagePath  = Join-Path $dataDir "distribution_by_owner_contact_stage_$stamp.csv"
$dispPath   = Join-Path $dataDir "distribution_by_owner_call_disposition_$stamp.csv"
$sourcePath = Join-Path $dataDir "distribution_by_owner_source_$stamp.csv"
$reasonPath = Join-Path $dataDir "distribution_by_owner_disqualification_reason_$stamp.csv"

Write-LsqLog "" $logPath
Write-PivotCsv $stageP  $stagePath
Write-PivotCsv $dispP   $dispPath
Write-PivotCsv $sourceP $sourcePath 0
Write-PivotCsv $reasonP $reasonPath

Write-LsqLog "" $logPath
Write-LsqLog "=== Distribution by owner complete ===" $logPath
