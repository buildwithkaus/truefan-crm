<#
.SYNOPSIS
  Move contacts sitting at Prospect with NO opportunity back to Engaged. Requires -Execute;
  one contact unless told otherwise. NEVER deletes a contact.

.DESCRIPTION
  A contact at Prospect is asserting "there is a real deal here". With no opportunity behind it
  that assertion is empty: it inflates the Prospect count, breaks any Prospect-scoped forecast,
  and hides the real pipeline. Most of this population is the residue of the forecast-less
  cleanup - the deal was deleted because it carried no value or closure date, and with contact
  writes forbidden at the time the contact stayed put.

  This moves the contact back to Engaged, where a rep can work it and promote it again properly.
  Nothing is deleted. ProspectStage is the only field written.

  EXCLUDED OWNERS
  ---------------
  -ExcludeOwners is matched CASE-INSENSITIVELY and the run ABORTS if any named owner matches
  nothing. "adarsh pandey" is stored lower-case in this account; matching "Adarsh Pandey"
  exactly would quietly protect nobody and demote all 93 of his contacts. That is the gotcha-2
  failure mode - a filter that matches nothing and reads as success - and it is unacceptable in
  an exclusion list, where a miss is the whole point of the parameter.

  WHY EVERY CONTACT IS RE-CHECKED LIVE
  ------------------------------------
  "Has no deal" is the entire basis for this write, and GetOpportunitiesOfLead is index-backed:
  it returns 0 deals for a lead that demonstrably has one (gotcha 48). Believing it alone would
  demote contacts whose pipeline is real. So each candidate is checked twice - the opportunity
  endpoint AND the activity trail (EventCode 12000, authoritative and immediate) - and is
  skipped unless both agree there is nothing there.

.EXAMPLE
  powershell.exe -File scripts\remediation\08-demote-prospects-without-deal.ps1
  powershell.exe -File scripts\remediation\08-demote-prospects-without-deal.ps1 -Execute -MaxRecords 0

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31).
  Undo with 99-restore-contact-stages.ps1 -StageFile data\contact_stage_demoted_nodeal_<stamp>.json
#>

param(
    [switch]$Execute,
    [int]$MaxRecords = 1,
    [int]$ThrottleMs = 250,
    [string[]]$ExcludeOwners = @("Mayank Arora", "adarsh pandey"),
    [int]$MinExpectedProspects = 800
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "contact_demote_nodeal_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$cfg     = Import-LsqConfig

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Demote Prospect-with-no-deal to Engaged [$mode] ===" $logPath
Write-LsqLog "Excluded owners: $($ExcludeOwners -join ' | ')" $logPath

# ---------------------------------------------------------------------------------------
# 1. Every contact currently at Prospect, read live
# ---------------------------------------------------------------------------------------
$prospects = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectStage"; LookupValue="Prospect"; SqlOperator="=" } `
        -ColumnsCsv "ProspectID,ProspectStage,OwnerId,OwnerIdName,Company,FirstName,LastName" `
        -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn" -SortDirection "0"
    $rows = @(Expand-LsqRows $resp)
    if ($rows.Count -eq 0) { break }
    foreach ($r in $rows) { [void]$prospects.Add($r) }
    if ($rows.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 150
}
Write-LsqLog "Contacts at Prospect right now: $($prospects.Count)" $logPath
if ($prospects.Count -lt 200) {
    throw "Only $($prospects.Count) Prospect contacts found. That is far below expectation - refusing to act on what looks like a truncated scan."
}

# Negative control (hard rule 1): a stage that cannot exist must return nothing.
$nc = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectStage"; LookupValue="__NoSuchStage__"; SqlOperator="=" } -ColumnsCsv "ProspectID" -PageSize 10))
if ($nc.Count -ne 0) { throw "Negative control FAILED: ProspectStage='__NoSuchStage__' returned $($nc.Count) rows. The filter cannot be trusted." }
Write-LsqLog "Negative control passed (bogus stage -> 0 rows)" $logPath

# ---------------------------------------------------------------------------------------
# 2. Apply the owner exclusion, and PROVE it matched
# ---------------------------------------------------------------------------------------
$excluded = New-Object System.Collections.Generic.List[object]
$candidates = New-Object System.Collections.Generic.List[object]
foreach ($p in $prospects) {
    $owner = "$($p.OwnerIdName)"
    $isExcluded = $false
    foreach ($e in $ExcludeOwners) { if ($owner -and $owner.Trim().ToLower() -eq $e.Trim().ToLower()) { $isExcluded = $true; break } }
    if ($isExcluded) { [void]$excluded.Add($p) } else { [void]$candidates.Add($p) }
}
Write-LsqLog "" $logPath
Write-LsqLog "  protected by owner exclusion : $($excluded.Count)" $logPath
$excluded | Group-Object OwnerIdName | Sort-Object Count -Descending | ForEach-Object {
    Write-LsqLog ("    {0,-26} {1,5}" -f $_.Name, $_.Count) $logPath
}
foreach ($e in $ExcludeOwners) {
    $hit = @($excluded | Where-Object { "$($_.OwnerIdName)".Trim().ToLower() -eq $e.Trim().ToLower() }).Count
    if ($hit -eq 0) {
        throw "Owner exclusion '$e' matched ZERO contacts. That is almost certainly a name or case mismatch, and it would demote contacts you meant to protect. Check the exact stored spelling before re-running."
    }
    Write-LsqLog "    exclusion '$e' verified: $hit contact(s) protected" $logPath
}
Write-LsqLog "  candidates before the no-deal check : $($candidates.Count)" $logPath

# ---------------------------------------------------------------------------------------
# 3. Confirm - twice - that each candidate really holds no opportunity
# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- verifying 'no deal' against BOTH the opportunity endpoint and the activity trail ---" $logPath
$targets = New-Object System.Collections.Generic.List[object]
$hasDeal = 0; $checkFail = 0; $i = 0
foreach ($c in $candidates) {
    $i++
    $lid = "$($c.ProspectID)"
    $deals = $null
    try { $deals = @(Get-LsqOpportunitiesOfLead -ProspectId $lid -Config $cfg) }
    catch { $checkFail++; Write-LsqLog "  SKIP $lid - opportunity read failed: $($_.Exception.Message)" $logPath; Start-Sleep -Milliseconds $ThrottleMs; continue }
    if ($deals.Count -gt 0) { $hasDeal++; Start-Sleep -Milliseconds $ThrottleMs; continue }

    # The endpoint said zero. It lags, so ask the trail before believing it.
    try {
        $trail = @(Get-LeadActivities -ProspectId $lid -Config $cfg | Where-Object { "$($_.EventCode)" -eq $Script:OPP_TYPE_ID })
        if ($trail.Count -gt 0) {
            $hasDeal++
            Write-LsqLog "  SKIP $lid - endpoint said 0 deals but the trail shows $($trail.Count); not demoting" $logPath
            Start-Sleep -Milliseconds $ThrottleMs; continue
        }
    } catch {
        $checkFail++
        Write-LsqLog "  SKIP $lid - trail cross-check failed: $($_.Exception.Message)" $logPath
        Start-Sleep -Milliseconds $ThrottleMs; continue
    }
    [void]$targets.Add($c)
    if ($i % 100 -eq 0) { Write-LsqLog "  checked $i/$($candidates.Count) - $($targets.Count) confirmed dealless, $hasDeal have a deal, $checkFail unverifiable" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "" $logPath
Write-LsqLog "  confirmed with NO deal (targets) : $($targets.Count)" $logPath
Write-LsqLog "  actually hold a deal (left alone): $hasDeal" $logPath
Write-LsqLog "  could not verify (left alone)    : $checkFail" $logPath
$targets | Group-Object OwnerIdName | Sort-Object Count -Descending | ForEach-Object {
    Write-LsqLog ("    {0,-26} {1,5}" -f $_.Name, $_.Count) $logPath
}

if ($targets.Count -eq 0) { Write-LsqLog "Nothing to do." $logPath; return }

if (-not $Execute) {
    Write-LsqLog "" $logPath
    Write-LsqLog "DRY RUN - no contact written. Re-run with -Execute (one contact unless -MaxRecords is raised)." $logPath
    return
}

# ---------------------------------------------------------------------------------------
# 4. Write
# ---------------------------------------------------------------------------------------
$ckptPath  = Join-Path $dataDir "contact_demote_nodeal_checkpoint.txt"
$stagePath = Join-Path $dataDir "contact_stage_demoted_nodeal_$stamp.json"

$done = @{}
if (Test-Path $ckptPath) {
    foreach ($l in (Get-Content $ckptPath)) { $t = $l.Trim(); if ($t) { $done[$t] = $true } }
    Write-LsqLog "Checkpoint holds $($done.Count) already-demoted contact(s)." $logPath
}
$queue = @($targets | Where-Object { -not $done.ContainsKey("$($_.ProspectID)") })
if ($queue.Count -eq 0) { Write-LsqLog "All targets already processed." $logPath; return }
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }
Write-LsqLog "Demoting $($queue.Count) this run (of $($targets.Count))." $logPath

$moved = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0
$isFirst = $true

foreach ($t in $queue) {
    $lid = "$($t.ProspectID)"
    $before = "$($t.ProspectStage)"
    try {
        $null = Set-LsqLeadFields -ProspectId $lid -Fields @{ ProspectStage = "Engaged" }

        # The lead index lags a few seconds; a one-shot read reports landed writes as failures.
        $after = $null
        $deadline = (Get-Date).AddSeconds(25)
        while ($true) {
            Start-Sleep -Seconds 3
            $lr = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
            if ($lr.Count -gt 0) { $after = "$($lr[0].ProspectStage)" }
            if ($after -eq "Engaged" -or (Get-Date) -ge $deadline) { break }
        }
        if ($after -ne "Engaged") { throw "contact reads '$after' after the write, expected 'Engaged'" }

        [void]$moved.Add([pscustomobject]@{
            ProspectId = $lid; FromStage = $before; ToStage = "Engaged"
            Owner = "$($t.OwnerIdName)"; Company = "$($t.Company)"
            ContactName = "$($t.FirstName) $($t.LastName)".Trim()
            AppliedAtUtc = ([datetime]::UtcNow).ToString("s")
        })
        # Same key 99-restore-contact-stages.ps1 reads, so the undo works unchanged.
        [pscustomobject]@{ Stamp = $stamp; Demoted = $moved.ToArray() } |
            ConvertTo-Json -Depth 6 | Set-Content -Path $stagePath -Encoding UTF8

        if ($isFirst) { Write-LsqLog "  PROOF: contact $lid moved '$before' -> 'Engaged', verified by re-fetch." $logPath; $isFirst = $false }
        Add-Content -Path $ckptPath -Value $lid
        $ok++
    } catch {
        $failed++
        Write-LsqLog "  FAIL $lid -> $($_.Exception.Message)" $logPath
        if ($isFirst) { throw "The FIRST demotion failed or did not land. Nothing else has been touched." }
    }
    if (($ok + $failed) % 50 -eq 0) { Write-LsqLog "  demoted $ok, failed $failed" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

if ($moved.Count -gt 0) {
    [pscustomobject]@{ Stamp = $stamp; Demoted = $moved.ToArray() } |
        ConvertTo-Json -Depth 6 | Set-Content -Path $stagePath -Encoding UTF8
}

Write-LsqLog "" $logPath
Write-LsqLog "=== done: demoted=$ok failed=$failed ===" $logPath
if ($moved.Count -gt 0) {
    Write-LsqLog "Rollback -> scripts\remediation\99-restore-contact-stages.ps1 -StageFile $stagePath -Execute" $logPath
}
