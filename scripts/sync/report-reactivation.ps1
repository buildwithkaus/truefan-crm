<#
.SYNOPSIS
  READ-ONLY. The standing re-activation report: parked accounts that become live again when
  something on OUR side changes, rather than requiring new prospecting.

.DESCRIPTION
  Two disqualification categories convert themselves:

    Supply Gap          - they wanted it, our celebrity roster did not cover them.
                          Sign a relevant celebrity and these are immediately workable.
    Commercial Mismatch - they wanted it, the price did not work.
                          Change pricing or package and these are workable.

  A third is operational rather than commercial:

    Unreachable / Bad Data - the BUSINESS is qualified, only the phone number was wrong.
                             These need a contact re-sourcing pass, not a sales pass.

  This is the payoff for making reps pick an honest disqualification category. Without the
  category the whole 62,000-record disqualified pile is undifferentiated and nobody mines it.

  Excludes 'Not ICP Fit' by design - those accounts are permanently out and must not clutter
  a working list.

.PARAMETER Category
  Limit to one category. Default: all re-activatable ones.

.PARAMETER OwnerFilter
  Limit to one owner's book, for handing a rep their own list.

.NOTES
  pwsh ./scripts/leadsquared/sync/report-reactivation.ps1
  pwsh ./scripts/leadsquared/sync/report-reactivation.ps1 -Category "Supply Gap"
#>

param(
    [string]$Category,
    [string]$OwnerFilter,
    [switch]$IncludeNotInterested
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "reactivation_log.txt"

# Ordered by how cheaply they convert. Not ICP Fit is deliberately absent.
$targets = @("Supply Gap", "Commercial Mismatch", "No Requirement", "Unreachable / Bad Data")
if ($IncludeNotInterested) { $targets += "Not Interested" }
if ($Category) { $targets = @($Category) }

Write-LsqLog "=== Re-activation report (READ-ONLY) ===" $logPath
Write-LsqLog "Categories: $($targets -join ', ')" $logPath

$cols = "ProspectID,FirstName,LastName,Company,EmailAddress,Phone,ProspectStage,OwnerIdName,RelatedCompanyId,mx_Disqualification_Category,mx_Disqualification_Reason,mx_Revisit_After,ProspectActivityDate_Max"
$rows = @()
$page = 1
while ($true) {
    $r = Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectStage"; LookupValue="Disqualified"; SqlOperator="=" } `
        -ColumnsCsv $cols -SortColumn "ProspectActivityDate_Max" -SortDirection "1" -PageIndex $page -PageSize 1000
    if (-not $r -or @($r).Count -eq 0) { break }
    foreach ($l in $r) {
        if ($targets -notcontains $l.mx_Disqualification_Category) { continue }
        if ($OwnerFilter -and $l.OwnerIdName -ne $OwnerFilter) { continue }
        $rows += [pscustomobject]@{
            ProspectId   = $l.ProspectID
            Name         = ("{0} {1}" -f $l.FirstName, $l.LastName).Trim()
            Company      = $l.Company
            CompanyId    = $l.RelatedCompanyId
            Phone        = $l.Phone
            Email        = $l.EmailAddress
            Owner        = $l.OwnerIdName
            Category     = $l.mx_Disqualification_Category
            Reason       = $l.mx_Disqualification_Reason
            RevisitAfter = $l.mx_Revisit_After
            LastActivity = $l.ProspectActivityDate_Max
        }
    }
    if (@($r).Count -lt 1000) { break }
    $page++; Start-Sleep -Milliseconds 250
}

Write-LsqLog "Re-activatable contacts found: $($rows.Count)" $logPath
Write-LsqLog "" $logPath
Write-LsqLog "--- By category ---" $logPath
foreach ($g in ($rows | Group-Object Category | Sort-Object Count -Descending)) {
    Write-LsqLog ("  {0,-24} {1,6}" -f $g.Name, $g.Count) $logPath
}
Write-LsqLog "" $logPath
Write-LsqLog "--- By owner (top 20) ---" $logPath
foreach ($g in ($rows | Group-Object Owner | Sort-Object Count -Descending | Select-Object -First 20)) {
    Write-LsqLog ("  {0,-24} {1,6}" -f $g.Name, $g.Count) $logPath
}

$jsonPath = Join-Path $dataDir "reactivation_report_$stamp.json"
$csvPath  = Join-Path $dataDir "reactivation_report_$stamp.csv"
$rows | ConvertTo-Json -Depth 4 | Set-Content -Path $jsonPath
$rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "Written: $csvPath (hand this to reps)" $logPath
Write-LsqLog "         $jsonPath" $logPath
Write-LsqLog "=== Re-activation report complete ===" $logPath
