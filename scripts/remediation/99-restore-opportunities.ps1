<#
.SYNOPSIS
  Recreate opportunities from the backup written by 01-delete-stray-opportunities.ps1.

.DESCRIPTION
  READ THIS BEFORE RELYING ON IT: this is a RECREATE, not an undelete.

  LeadSquared assigns a new GUID on create, so a restored deal is a NEW record:

    the OpportunityId CHANGES        anything referencing the old id - fact_opportunity rows,
                                     activity-trail entries, warehouse joins - will not match.
    CreatedOn becomes today          deal age, days-open and any created-date cohort analysis
                                     are lost for that record.
    the original 12000 trail entry   stays deleted. The account's history of that deal is gone.

  What IS faithfully restored: the lead it hangs off, and every writable field that had a value -
  name, stage, status, owner, both deal-size fields, both closure dates, loss reason, product,
  celebrity, and the contract/agreement/invoice dates.

  So this is a real safety net for "we deleted the wrong class" - it puts the pipeline back -
  and it is NOT a way to make a bad delete invisible. Prefer getting the audit right.

.EXAMPLE
  powershell.exe -File scripts\remediation\99-restore-opportunities.ps1 -AppliedFile data\opportunity_deleted_DUPLICATE_DEAL_X.json
  powershell.exe -File scripts\remediation\99-restore-opportunities.ps1 -AppliedFile ... -Execute

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31).
#>

param(
    [Parameter(Mandatory)][string]$AppliedFile,
    [switch]$Execute,
    [int]$MaxRecords = 0,
    [int]$ThrottleMs = 300
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_cleanup_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$cfg     = Import-LsqConfig

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Restore opportunities from backup [$mode] ===" $logPath

if (-not (Test-Path $AppliedFile)) { throw "Applied file not found: $AppliedFile" }
$applied = Read-Utf8Json $AppliedFile
$rows = @($applied.Deleted)
Write-LsqLog "Backup: $AppliedFile" $logPath
Write-LsqLog "  class $($applied.Class), $($rows.Count) deleted record(s), stamp $($applied.Stamp)" $logPath
if ($rows.Count -eq 0) { Write-LsqLog "Nothing to restore." $logPath; return }

# Fields worth carrying back. Status and mx_Custom_2 are set at create; the rest are written
# afterwards because Capture does not accept all of them.
$restoreFields = @(
    'mx_Custom_4','mx_Custom_5','mx_Custom_6','mx_Custom_7','mx_Custom_8','mx_Custom_9',
    'mx_Custom_10','mx_Custom_13','mx_Custom_14','mx_Custom_15','mx_Custom_16','mx_Custom_17'
)

if (-not $Execute) {
    Write-LsqLog "DRY RUN - nothing created. First 10 would be restored as:" $logPath
    foreach ($r in ($rows | Select-Object -First 10)) {
        Write-LsqLog ("    lead {0}  '{1}'  {2}/{3}" -f $r.ProspectId, $r.Fields.mx_Custom_1, $r.Fields.mx_Custom_2, $r.Fields.Status) $logPath
    }
    Write-LsqLog "" $logPath
    Write-LsqLog "NOTE: restored deals get NEW ids and today's creation date. See the header." $logPath
    return
}

$queue = $rows
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }

$out = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0
foreach ($r in $queue) {
    $lid  = "$($r.ProspectId)"
    $name = "$($r.Fields.mx_Custom_1)"
    $st   = "$($r.Fields.Status)";      if (-not $st) { $st = "Open" }
    $sg   = "$($r.Fields.mx_Custom_2)"; if (-not $sg) { $sg = "Prospect" }
    if (-not $name) { $failed++; Write-LsqLog "  FAIL $lid - backup has no Opportunity Name" $logPath; continue }
    try {
        # -SkipExistenceCheck: a restore deliberately re-adds a deal to a lead that may already
        # have another one, which the normal duplicate guard would refuse.
        $newId = New-LsqOpportunity -ProspectId $lid -OpportunityName $name -Status $st -OppStage $sg `
            -OwnerId "$($r.Fields.Owner)" -Config $cfg -SkipExistenceCheck `
            -Note "$($Script:OPP_CLEANUP_NOTE_PREFIX)-RESTORE-$stamp from $($r.OpportunityId) deleted $($r.DeletedAtUtc)"

        $extra = @{}
        foreach ($f in $restoreFields) {
            $v = "$($r.Fields.$f)"
            if (-not [string]::IsNullOrWhiteSpace($v)) { $extra[$f] = $v }
        }
        if ($extra.Count -gt 0) {
            Start-Sleep -Seconds 2
            $null = Set-LsqOpportunity -OpportunityId $newId -Fields $extra -Config $cfg `
                -Note "$($Script:OPP_CLEANUP_NOTE_PREFIX)-RESTORE-$stamp field restore"
        }
        [void]$out.Add([pscustomobject]@{ OldOpportunityId=$r.OpportunityId; NewOpportunityId=$newId; ProspectId=$lid; Company=$r.Company; FieldsRestored=$extra.Count })
        $ok++
    } catch {
        $failed++
        Write-LsqLog "  FAIL $lid ($($r.OpportunityId)) -> $($_.Exception.Message)" $logPath
    }
    if (($ok+$failed) % 25 -eq 0) { Write-LsqLog "  restored $ok, failed $failed" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

$mapPath = Join-Path $dataDir "opportunity_restore_map_$stamp.json"
[pscustomobject]@{ Stamp=$stamp; Source=$AppliedFile; Restored=$out.ToArray() } |
    ConvertTo-Json -Depth 6 | Set-Content -Path $mapPath -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "=== restore done: ok=$ok failed=$failed ===" $logPath
Write-LsqLog "old id -> new id map: $mapPath" $logPath
Write-LsqLog "The warehouse still holds the OLD ids. Run scripts\remediation\98-reconcile-warehouse.ps1." $logPath
