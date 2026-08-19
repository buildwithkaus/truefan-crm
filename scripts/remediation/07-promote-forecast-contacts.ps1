<#
.SYNOPSIS
  Promote to Prospect the contacts that hold a real, forecasted deal but were never moved off
  Engaged. Requires -Execute; one contact unless told otherwise.

.DESCRIPTION
  The mirror image of 06. That script deletes deals with no forecast data; this one fixes the
  opposite defect - a deal carrying BOTH Expected Deal Size and Expected Closure Date, sitting
  on a contact still at Engaged (or Future Prospect, or Disqualified).

  These are not junk. A rep filled in a value and a closure date, which is the strongest signal
  in the system that a deal is real - 108 of them, INR 3.85 crore. What never happened is the
  contact stage moving to Prospect, so a Prospect-scoped forecast cannot see any of it. 90 of
  the 108 belong to one rep, which makes it a habit rather than an accident.

  Deleting them to satisfy "the tab holds Prospect contacts only" would destroy the best
  forecast data in the account in order to tidy a stage field. Promoting the contact fixes the
  same inconsistency from the correct end.

  THIS IS A CONTACT WRITE, AND THE MECHANISM IS UNPROVEN
  -----------------------------------------------------
  The contact write had never successfully run on this account: every previous attempt was
  either skipped by a bug or blocked by -SkipDemote. LeadSquared also returns 200 for a write
  that changes nothing (the gotcha-49 family), so a success response proves nothing on its own.
  The first write of every run is therefore verified by an independent re-fetch, and the run
  aborts if the stage did not actually move.

  Contacts are only promoted when their deal is confirmed still live, so a deal removed by a
  concurrent run cannot leave a contact promoted with nothing behind it.

.EXAMPLE
  powershell.exe -File scripts\remediation\07-promote-forecast-contacts.ps1
  powershell.exe -File scripts\remediation\07-promote-forecast-contacts.ps1 -Execute -MaxRecords 0

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31).
  Undo with 99-restore-contact-stages.ps1 -StageFile data\contact_stage_promoted_<stamp>.json
#>

param(
    [string]$ScanFile = "",
    [switch]$Execute,
    [int]$MaxRecords = 1,
    [int]$ThrottleMs = 300,
    [string]$RepName = "",
    [switch]$IncludeDisqualified
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_promote_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$cfg     = Import-LsqConfig

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Promote forecast-carrying contacts to Prospect [$mode] ===" $logPath

if (-not $ScanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_scan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No scan file found. Run scripts\remediation\00-backup-opportunities.ps1 first." }
    $ScanFile = $newest.FullName
}
$scan = Read-Utf8Json $ScanFile
$deals = @($scan.Deals)
Write-LsqLog "Scan file: $ScanFile ($($deals.Count) deals, taken $($scan.GeneratedAtUtc) UTC)" $logPath

# Candidates: an OPEN deal carrying BOTH forecast fields, on a contact not already at a deal
# stage. Both fields, not either - a half-filled forecast is not evidence enough to move a
# contact's stage on the rep's behalf.
$targets = New-Object System.Collections.Generic.List[object]
$seen = @{}
$skipStage = 0; $skipNoFc = 0; $skipRep = 0; $skipDup = 0; $skipDisq = 0
foreach ($d in $deals) {
    if ("$($d.Status)" -ne "Open") { continue }
    if ("$($d.ContactStage)" -eq "Prospect" -or "$($d.ContactStage)" -eq "Customer") { $skipStage++; continue }
    if (-not ((Test-LsqForecastValue $d.ExpectedDealSize) -and (Test-LsqForecastDate $d.ExpectedCloseDate))) { $skipNoFc++; continue }
    if ($RepName -and "$($d.ContactOwnerName)" -ne $RepName) { $skipRep++; continue }
    if ("$($d.ContactStage)" -eq "Disqualified" -and -not $IncludeDisqualified) { $skipDisq++; continue }
    if ($seen.ContainsKey("$($d.ProspectId)")) { $skipDup++; continue }
    $seen["$($d.ProspectId)"] = $true
    [void]$targets.Add($d)
}

Write-LsqLog "" $logPath
Write-LsqLog "  already at a deal stage (nothing to do)   : $skipStage" $logPath
Write-LsqLog "  no complete forecast (not evidence)       : $skipNoFc" $logPath
if ($RepName)      { Write-LsqLog "  other reps                                : $skipRep" $logPath }
if ($skipDisq -gt 0) { Write-LsqLog "  Disqualified (pass -IncludeDisqualified)  : $skipDisq" $logPath }
Write-LsqLog "  second deal on the same contact           : $skipDup" $logPath
Write-LsqLog "  --> CONTACTS TO PROMOTE                   : $($targets.Count)" $logPath

$targets | Group-Object ContactStage | Sort-Object Count -Descending | ForEach-Object {
    Write-LsqLog ("    from {0,-18} {1,5}" -f $(if ($_.Name) { $_.Name } else { "<blank>" }), $_.Count) $logPath
}
$val = 0
foreach ($t in $targets) { if (Test-LsqForecastValue $t.ExpectedDealSize) { $val += [double]$t.ExpectedDealSize } }
Write-LsqLog ("  pipeline value being made visible         : INR {0:N0}" -f $val) $logPath

if ($targets.Count -eq 0) { Write-LsqLog "Nothing to do." $logPath; return }

if (-not $Execute) {
    Write-LsqLog "" $logPath
    Write-LsqLog "DRY RUN - no contact written. First 10:" $logPath
    foreach ($t in ($targets | Select-Object -First 10)) {
        Write-LsqLog ("    {0}  {1,-16} -> Prospect   value={2} date={3}  {4}" -f $t.ProspectId, $t.ContactStage, $t.ExpectedDealSize, $t.ExpectedCloseDate, $t.CompanyName) $logPath
    }
    Write-LsqLog "" $logPath
    Write-LsqLog "Re-run with -Execute. It promotes ONE contact unless -MaxRecords is raised." $logPath
    return
}

$ckptPath  = Join-Path $dataDir "opportunity_promote_checkpoint.txt"
$stagePath = Join-Path $dataDir "contact_stage_promoted_$stamp.json"

$done = @{}
if (Test-Path $ckptPath) {
    foreach ($l in (Get-Content $ckptPath)) { $t = $l.Trim(); if ($t) { $done[$t] = $true } }
    Write-LsqLog "Checkpoint holds $($done.Count) already-promoted contact(s)." $logPath
}
$queue = @($targets | Where-Object { -not $done.ContainsKey("$($_.ProspectId)") })
if ($queue.Count -eq 0) { Write-LsqLog "All targets already processed." $logPath; return }
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }
Write-LsqLog "Promoting $($queue.Count) this run (of $($targets.Count))." $logPath

$promoted = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0; $skippedGone = 0
$isFirst = $true

foreach ($t in $queue) {
    $lid = "$($t.ProspectId)"

    # The deal must still exist. Promoting a contact whose deal was deleted elsewhere would
    # leave a Prospect with nothing behind it - the very state this cleanup is removing.
    try {
        $null = Get-LsqOpportunityDetails -OpportunityId $t.OpportunityId -Config $cfg -SkipMapAssert
    } catch {
        $skippedGone++
        Write-LsqLog "  SKIP $lid - its deal $($t.OpportunityId) no longer exists" $logPath
        Add-Content -Path $ckptPath -Value $lid
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }

    $before = $null
    try {
        $lr = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
        if ($lr.Count -gt 0) { $before = "$($lr[0].ProspectStage)" }
    } catch { }
    if ($null -eq $before) {
        $failed++
        Write-LsqLog "  FAIL $lid - could not read the contact, refusing to write blind" $logPath
        if ($isFirst) { throw "Could not read the first contact. Stopping before any write." }
        continue
    }
    if ($before -eq "Prospect" -or $before -eq "Customer") {
        Write-LsqLog "  SKIP $lid - already at '$before'" $logPath
        Add-Content -Path $ckptPath -Value $lid
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }

    try {
        # Lead.Update, not Lead/Bulk/UpdateV2 - see Set-LsqLeadFields in common.ps1 for why the
        # bulk shape this repo carried never worked.
        $null = Set-LsqLeadFields -ProspectId $lid -Fields @{ ProspectStage = "Prospect" }

        # A 200 is not proof, but nor is a single quick read a disproof: the lead index lags a
        # few seconds behind the write. A one-shot check here reported 14 writes as failures
        # that had in fact landed. Poll instead, and only call it a failure after the deadline.
        $after = $null
        $deadline = (Get-Date).AddSeconds(25)
        while ($true) {
            Start-Sleep -Seconds 3
            $lr2 = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
            if ($lr2.Count -gt 0) { $after = "$($lr2[0].ProspectStage)" }
            if ($after -eq "Prospect" -or (Get-Date) -ge $deadline) { break }
        }
        if ($after -ne "Prospect") { throw "contact reads '$after' after the write, expected 'Prospect'" }

        [void]$promoted.Add([pscustomobject]@{
            ProspectId = $lid; FromStage = $before; ToStage = "Prospect"
            OpportunityId = $t.OpportunityId; Company = $t.CompanyName; Rep = $t.ContactOwnerName
            DealValue = $t.ExpectedDealSize; CloseDate = $t.ExpectedCloseDate
            AppliedAtUtc = ([datetime]::UtcNow).ToString("s")
        })
        # Written under the key 99-restore-contact-stages.ps1 already reads, so the undo works
        # against this file unchanged.
        [pscustomobject]@{ Stamp = $stamp; Demoted = $promoted.ToArray() } |
            ConvertTo-Json -Depth 6 | Set-Content -Path $stagePath -Encoding UTF8

        if ($isFirst) {
            Write-LsqLog "  PROOF: contact $lid moved '$before' -> 'Prospect', verified by re-fetch." $logPath
            $isFirst = $false
        }
        Add-Content -Path $ckptPath -Value $lid
        $ok++
    } catch {
        $failed++
        Write-LsqLog "  FAIL $lid -> $($_.Exception.Message)" $logPath
        if ($isFirst) { throw "The FIRST contact write failed or did not land. The contact write is not landing on this account - fix that before running at scale. Nothing else has been touched." }
    }
    if (($ok + $failed) % 25 -eq 0) { Write-LsqLog "  promoted $ok, failed $failed, skipped $skippedGone" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

if ($promoted.Count -gt 0) {
    [pscustomobject]@{ Stamp = $stamp; Demoted = $promoted.ToArray() } |
        ConvertTo-Json -Depth 6 | Set-Content -Path $stagePath -Encoding UTF8
}

Write-LsqLog "" $logPath
Write-LsqLog "=== done: promoted=$ok failed=$failed skipped(deal gone)=$skippedGone ===" $logPath
if ($promoted.Count -gt 0) {
    Write-LsqLog "Rollback -> scripts\remediation\99-restore-contact-stages.ps1 -StageFile $stagePath -Execute" $logPath
}
