<#
.SYNOPSIS
  READ-ONLY (against the CRM). Re-derives the Contact Stage / Call Disposition /
  Disqualification Reason / Source distribution by owner from live data and writes it to a
  single Excel workbook at a FIXED path, overwriting the previous version each time.

.DESCRIPTION
  "One spreadsheet that updates with the latest numbers whenever run" - so this always
  writes to the same file (data/TrueFan_Lead_Distribution.xlsx), not a timestamped copy.
  Re-run this script any time to refresh it from live LSQ data.

  Uses Excel COM automation (this machine has Office installed - no extra module needed,
  consistent with CLAUDE.md's "nothing to install beyond PowerShell itself"). Excel is
  driven invisibly and closed in a finally block so no orphan EXCEL.EXE process is left
  running - same "confirm the old process actually exited" discipline CLAUDE.md applies to
  PowerShell scripts.

.NOTES
  pwsh ./scripts/leadsquared/migration/21-export-distribution-xlsx.ps1
#>

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "export_distribution_xlsx_log.txt"
$xlsxPath = Join-Path $dataDir "TrueFan_Lead_Distribution.xlsx"

Write-LsqLog "=== Export distribution to Excel (READ-ONLY against CRM) ===" $logPath

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
if ($leads.Count -lt $MinExpectedLeads) { throw "Only $($leads.Count) leads enumerated (floor $MinExpectedLeads) - refusing to export from an incomplete scan." }

function Build-Pivot {
    param([System.Collections.Generic.List[object]]$Items, [string]$Field)
    $pivot = @{}; $ownerTotal = @{}; $colTotal = @{}
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

$stageP  = Build-Pivot $leads "ProspectStage"
$dispP   = Build-Pivot $leads "mx_Call_Disposition"
$sourceP = Build-Pivot $leads "Source"
$reasonP = Build-Pivot $leads "mx_Disqualification_Reason"

Write-LsqLog "Pivots built. Writing workbook to $xlsxPath ..." $logPath

function New-ExcelArray {
    param([string[]]$Header, [System.Collections.Generic.List[object[]]]$Rows)
    $totalRows = $Rows.Count + 1
    $totalCols = $Header.Count
    $arr = New-Object 'object[,]' $totalRows, $totalCols
    for ($c = 0; $c -lt $totalCols; $c++) { $arr[0, $c] = $Header[$c] }
    for ($r = 0; $r -lt $Rows.Count; $r++) {
        $row = $Rows[$r]
        $destRow = $r + 1
        for ($c = 0; $c -lt $totalCols; $c++) {
            $val = if ($c -lt $row.Length) { $row[$c] } else { "" }
            $arr[$destRow, $c] = $val
        }
    }
    # Returning a true multi-dimensional array (object[,]) through a normal PowerShell
    # function `return`/pipeline output FLATTENS it to a 1-D System.Object[] (Rank drops
    # from 2 to 1, GetLength(1) then throws IndexOutOfRangeException) - confirmed live
    # 2026-08-03 building this script. Write-Output -NoEnumerate is required to hand a
    # multi-dim array back through a function boundary intact.
    Write-Output -NoEnumerate $arr
}

function Get-PivotArray {
    param([pscustomobject]$Pivot, [int]$TotalLeadsAll)
    $owners = $Pivot.OwnerTotal.Keys | Sort-Object { -$Pivot.OwnerTotal[$_] }
    $cols = $Pivot.ColTotal.Keys | Sort-Object { -$Pivot.ColTotal[$_] }
    $header = @("Owner", "TotalLeads") + $cols
    $rows = New-Object System.Collections.Generic.List[object[]]
    foreach ($o in $owners) {
        $row = New-Object System.Collections.Generic.List[object]
        [void]$row.Add($o)
        [void]$row.Add([int]$Pivot.OwnerTotal[$o])
        foreach ($c in $cols) {
            $cnt = 0
            if ($Pivot.Pivot.ContainsKey($o) -and $Pivot.Pivot[$o].ContainsKey($c)) { $cnt = $Pivot.Pivot[$o][$c] }
            [void]$row.Add([int]$cnt)
        }
        [void]$rows.Add($row.ToArray())
    }
    $totalRow = New-Object System.Collections.Generic.List[object]
    [void]$totalRow.Add("TOTAL"); [void]$totalRow.Add([int]$TotalLeadsAll)
    foreach ($c in $cols) { [void]$totalRow.Add([int]$Pivot.ColTotal[$c]) }
    [void]$rows.Add($totalRow.ToArray())
    Write-Output -NoEnumerate (New-ExcelArray -Header $header -Rows $rows)
}

$lastUpdated = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
try {
    $wb = $excel.Workbooks.Add()
    $sheetSpecs = @(
        @{ Name = "Contact Stage";           Pivot = $stageP  },
        @{ Name = "Call Disposition";        Pivot = $dispP   },
        @{ Name = "Disqualification Reason"; Pivot = $reasonP },
        @{ Name = "Source";                  Pivot = $sourceP }
    )

    while ($wb.Worksheets.Count -lt $sheetSpecs.Count) {
        $wb.Worksheets.Add([System.Reflection.Missing]::Value, $wb.Worksheets.Item($wb.Worksheets.Count)) | Out-Null
    }
    while ($wb.Worksheets.Count -gt $sheetSpecs.Count) {
        $wb.Worksheets.Item($wb.Worksheets.Count).Delete()
    }

    for ($i = 0; $i -lt $sheetSpecs.Count; $i++) {
        $spec = $sheetSpecs[$i]
        $ws = $wb.Worksheets.Item($i + 1)
        $ws.Name = $spec.Name
        $arr = Get-PivotArray -Pivot $spec.Pivot -TotalLeadsAll $leads.Count
        $rows = $arr.GetLength(0); $cols = $arr.GetLength(1)
        $ws.Cells(1, 1).Value2 = "Last refreshed (live LSQ data): $lastUpdated    Total leads scanned: $($leads.Count)"
        $range = $ws.Range($ws.Cells(2, 1), $ws.Cells(1 + $rows, $cols))
        $range.Value2 = $arr
        $ws.Rows.Item(2).Font.Bold = $true
        $ws.Rows.Item(2).Interior.ColorIndex = 15
        $ws.Range($ws.Cells($rows + 1, 1), $ws.Cells($rows + 1, $cols)).Font.Bold = $true
        $ws.Application.ActiveWindow.SplitRow = 2
        $ws.Application.ActiveWindow.FreezePanes = $true
        $ws.Columns.Item(1).ColumnWidth = 22
        [void]$ws.Columns.AutoFit()
        Write-LsqLog "  sheet '$($spec.Name)' written: $($rows - 1) owners x $($cols - 2) values" $logPath
    }

    $wb.Worksheets.Item(1).Activate()
    if (Test-Path $xlsxPath) { Remove-Item $xlsxPath -Force }
    $wb.SaveAs($xlsxPath, 51)  # 51 = xlOpenXMLWorkbook (.xlsx)
    $wb.Close($false)
    Write-LsqLog "Workbook saved: $xlsxPath" $logPath
} finally {
    $excel.Quit()
    [void][System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel)
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

Write-LsqLog "=== Export complete ===" $logPath
