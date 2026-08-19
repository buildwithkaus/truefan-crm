<#
.SYNOPSIS
  Delete every OPEN opportunity that does not carry BOTH Expected Deal Size and Expected
  Closure Date, and move its contact back to Engaged. Requires -Execute; one record unless
  told otherwise.

.DESCRIPTION
  The rule (Kaustubh, 2026-08-17): an opportunity without a deal size AND a closure date is
  not a deal. Delete it, and put the contact back at Engaged where it can be worked.

  TWO CARVE-OUTS, BOTH DELIBERATE
  -------------------------------
  1. WON AND CONTRACTED DEALS ARE NEVER TOUCHED. Applied literally the rule would delete 158
     Won deals - every closed deal in the account - and demote 154 Customer contacts to
     Engaged, turning paying customers into mid-funnel prospects. Expected Deal Size is a
     FORECAST field; a closed or contracted deal has no need of it, so its absence says
     nothing about whether the deal was real.

     "Contract deal" is read broadly, because commercial progress shows up in more than one
     field. A deal is protected if ANY of these hold:

       Status is not Open                    Won or Lost, already resolved
       the contact is at Customer            they are paying; the deal is history, not forecast
       stage is Agreement Sent or beyond     a contract is in flight
       Actual Deal Size is filled            real money was recorded
       Contract Start / End Date is filled   there is a signed term
       Agreement Sent / Invoice Sent Date    paperwork has gone out

     The last four are only visible through GetOpportunityDetails, so they are checked on the
     live re-read immediately before deletion, not from the scan file.

  2. RECENTLY CREATED DEALS ARE EXEMPT. A deal created minutes ago necessarily has no forecast
     data, so the create rule ("every Prospect must have a deal") and this delete rule would
     otherwise fight: create a deal, delete it on the next pass, demote the contact, forever.
     Deals carrying this cleanup's own note prefix, or created within -GraceHours, are left
     alone so the rep has a chance to fill the fields in.

  WHY THE FORECAST IS RE-READ LIVE
  --------------------------------
  The scan file is a snapshot. A rep may have filled in the deal size since it was taken, and
  deleting their work because a file is an hour old is not acceptable. Every candidate is
  re-read through GetOpportunityDetails immediately before deletion, and skipped if the fields
  are now present. That read doubles as the field-level backup.

  THE CONTACT WRITE IS THE RISKY HALF
  -----------------------------------
  Deleting a deal touches an object reps barely use. Moving 718 contacts off Prospect is
  visible to every rep the moment they open their book, and it is the exact shape of the
  2026-08-11 incident, where 2,729 contacts were wrongly moved and had to be rolled back the
  next day. So the prior stage of every contact is recorded before the write, the first write
  of each run is proven by an independent re-fetch, and 99-restore-contact-stages.ps1 can put
  every one of them back.

.EXAMPLE
  powershell.exe -File scripts\remediation\06-delete-forecastless-and-demote.ps1
  powershell.exe -File scripts\remediation\06-delete-forecastless-and-demote.ps1 -Execute
  powershell.exe -File scripts\remediation\06-delete-forecastless-and-demote.ps1 -Execute -MaxRecords 0

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31). Two API calls per record plus the contact
  write; the opportunity limit is 25 calls / 5 s, so keep ThrottleMs >= 250 (gotcha 51).
#>

param(
    [string]$ScanFile = "",
    [switch]$Execute,
    [int]$MaxRecords = 1,
    [int]$ThrottleMs = 300,
    [int]$GraceHours = 24,
    [switch]$SkipDemote,

    # Drop the grace exemptions. The grace window exists to stop a create rule and a delete rule
    # thrashing against each other, but when the goal is a forecast-complete pipeline an empty
    # deal created an hour ago breaks the forecast exactly as much as one created in July.
    [switch]$IgnoreGrace,

    # Boxed-cleanup filters. Run one rep, one contact stage at a time, so the blast radius is
    # something a human can eyeball before and after.
    [string]$RepName = "",

    # Restrict to deals whose contact is at this stage. With 'Engaged' NOTHING is written to any
    # contact - the deal is simply removed from a contact that is already where it should be.
    # That is the safest form of this cleanup and the one to prefer.
    [string]$OnlyContactStage = ""
)
# There is deliberately NO switch to include Won or Customer deals. Kaustubh, 2026-08-17:
# "preserve won and customer contract deals". A flag that can destroy the record of closed
# business is a footgun regardless of its default, so it does not exist.

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_forecastless_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$cfg     = Import-LsqConfig

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Delete forecast-less opportunities + demote contacts [$mode] ===" $logPath

if (-not $ScanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_scan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No scan file found. Run scripts\remediation\00-backup-opportunities.ps1 first." }
    $ScanFile = $newest.FullName
}
$scan = Read-Utf8Json $ScanFile
$deals = @($scan.Deals)
Write-LsqLog "Scan file: $ScanFile ($($deals.Count) deals, taken $($scan.GeneratedAtUtc) UTC)" $logPath

# ---------------------------------------------------------------------------------------
# Candidate selection
# ---------------------------------------------------------------------------------------
$graceCutoff = (Get-Date).ToUniversalTime().AddHours(-$GraceHours)
$targets = New-Object System.Collections.Generic.List[object]
$skipWon = 0; $skipCustomer = 0; $skipAdvanced = 0; $skipRecent = 0; $skipHasBoth = 0; $skipTest = 0; $skipRep = 0; $skipStage = 0

# Agreement Sent (rank 4) and beyond means a contract is in flight. Compared through
# Get-LsqOpportunityStageRank so an unknown stage returns $null and is treated as advanced
# rather than silently ranking 0 and being deleted (gotcha 46).
$AdvancedRank = Get-LsqOpportunityStageRank 'Agreement Sent'

foreach ($d in $deals) {
    if (Test-LsqOpportunityIsTestRecord $d) { $skipTest++; continue }

    # --- boxed-cleanup filters, applied first because they are the cheapest ---------------
    if ($RepName -and "$($d.ContactOwnerName)" -ne $RepName)              { $skipRep++;   continue }
    if ($OnlyContactStage -and "$($d.ContactStage)" -ne $OnlyContactStage) { $skipStage++; continue }

    # BOTH fields must be absent to qualify. Kaustubh, 2026-08-18: "expected deal size and
    # expected closure date - both are absent". A deal carrying EITHER one is evidence a rep
    # engaged with it, so it stays. This is deliberately stricter than the earlier reading,
    # which deleted on a single missing field.
    if ((Test-LsqForecastValue $d.ExpectedDealSize) -or (Test-LsqForecastDate $d.ExpectedCloseDate)) { $skipHasBoth++; continue }

    if ("$($d.Status)" -ne "Open")           { $skipWon++; continue }
    if ("$($d.ContactStage)" -eq "Customer") { $skipCustomer++; continue }

    $rank = Get-LsqOpportunityStageRank $d.OppStage -WarningAction SilentlyContinue
    if ($null -eq $rank -or $rank -ge $AdvancedRank) { $skipAdvanced++; continue }

    # Exempt this cleanup's own creations, and anything genuinely new.
    if (-not $IgnoreGrace -and "$($d.Note)" -like "*$($Script:OPP_CLEANUP_NOTE_PREFIX)*") { $skipRecent++; continue }
    if (-not $IgnoreGrace -and $d.CreatedOnUtc) {
        $c = $null
        try { $c = ([datetime]$d.CreatedOnUtc).ToUniversalTime() } catch { }
        if ($c -and $c -gt $graceCutoff) { $skipRecent++; continue }
    }
    [void]$targets.Add($d)
}

Write-LsqLog "" $logPath
Write-LsqLog "  carrying either forecast field (kept)       : $skipHasBoth" $logPath
if ($RepName)          { Write-LsqLog "  other reps (out of box)                     : $skipRep" $logPath }
if ($OnlyContactStage) { Write-LsqLog "  contact not at '$OnlyContactStage' (out of box)        : $skipStage" $logPath }
Write-LsqLog "  Won / not Open (protected)                  : $skipWon" $logPath
Write-LsqLog "  on Customer contacts (protected)            : $skipCustomer" $logPath
Write-LsqLog "  Agreement Sent or beyond / unknown (protected) : $skipAdvanced" $logPath
Write-LsqLog "  created within $GraceHours h or by cleanup (exempt) : $skipRecent" $logPath
Write-LsqLog "  test records                                : $skipTest" $logPath
Write-LsqLog "  --> TARGETS                                 : $($targets.Count)" $logPath

$demoteFrom = @($targets | Where-Object { "$($_.ContactStage)" -eq "Prospect" } | Group-Object ProspectId)
Write-LsqLog "" $logPath
Write-LsqLog ("  contacts to demote Prospect -> Engaged      : {0}" -f $(if ($SkipDemote) { "0  (SkipDemote: NO contact will be written; $($demoteFrom.Count) would otherwise have moved)" } else { "$($demoteFrom.Count)" })) $logPath
Write-LsqLog "  targets already on Engaged (no stage write) : $(@($targets | Where-Object { "$($_.ContactStage)" -eq 'Engaged' }).Count)" $logPath
$targets | Group-Object ContactStage | Sort-Object Count -Descending | ForEach-Object {
    Write-LsqLog ("    from {0,-18} {1,6}" -f $(if($_.Name){$_.Name}else{'<blank>'}), $_.Count) $logPath
}

# Process the contacts that need DEMOTING first. The risky half of this script is the contact
# write, not the deletion - and the natural scan order front-loads Engaged contacts, which need
# no stage write at all. Left unsorted, the run deletes ~2,200 deals before it ever attempts a
# demotion, so a broken Lead/Bulk/UpdateV2 would be discovered at the very end instead of on
# record one. Sorting puts the unproven operation first, where the abort guard can act on it.
$targets = New-Object System.Collections.Generic.List[object] -ArgumentList @(,@(
    $targets | Sort-Object @{ Expression = { if ("$($_.ContactStage)" -eq 'Prospect') { 0 } else { 1 } } }
))
Write-LsqLog "  queue ordered: Prospect-stage contacts first, so the contact write is proven on record 1" $logPath

if ($targets.Count -eq 0) { Write-LsqLog "Nothing to do." $logPath; return }

if (-not $Execute) {
    Write-LsqLog "" $logPath
    Write-LsqLog "DRY RUN - nothing deleted, no contact moved. First 10 targets:" $logPath
    foreach ($t in ($targets | Select-Object -First 10)) {
        Write-LsqLog ("    {0}  {1,-14} value='{2}' date='{3}'  {4}" -f $t.OpportunityId, $t.ContactStage, $t.ExpectedDealSize, $t.ExpectedCloseDate, $t.CompanyName) $logPath
    }
    Write-LsqLog "" $logPath
    Write-LsqLog "Re-run with -Execute. It processes ONE record unless -MaxRecords is raised." $logPath
    return
}

# ---------------------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------------------
$ckptPath    = Join-Path $dataDir "opportunity_forecastless_checkpoint.txt"
$appliedPath = Join-Path $dataDir "opportunity_forecastless_deleted_$stamp.json"
$stagePath   = Join-Path $dataDir "contact_stage_demoted_$stamp.json"
$leadUpdateUrl = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"

$done = @{}
if (Test-Path $ckptPath) {
    foreach ($l in (Get-Content $ckptPath)) { $t = $l.Trim(); if ($t) { $done[$t] = $true } }
    Write-LsqLog "Checkpoint holds $($done.Count) already-processed id(s)." $logPath
}
$queue = @($targets | Where-Object { -not $done.ContainsKey("$($_.OpportunityId)") })
if ($queue.Count -eq 0) { Write-LsqLog "All targets already processed." $logPath; return }
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }
Write-LsqLog "Processing $($queue.Count) this run (of $($targets.Count))." $logPath

$deleted = New-Object System.Collections.Generic.List[object]
$demoted = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0; $skippedNowFilled = 0; $demoteFail = 0; $skippedContracted = 0
$isFirst = $true
$firstDemote = $true      # the first Prospect->Engaged write, wherever it falls in the queue

function Set-ContactStage {
    param([string]$LeadId, [string]$Stage)
    $body = @{
        SearchByKey = "ProspectId"
        Options = @{ PushNonExistentLeadsToUnProcessedList = $true }
        LeadPropertiesList = @(, @(@{ Fields = @(
            @{ Attribute = "ProspectId";    Value = $LeadId },
            @{ Attribute = "ProspectStage"; Value = $Stage }
        ) }))
    } | ConvertTo-Json -Depth 8
    return Invoke-LsqPost -Uri $leadUpdateUrl -JsonBody $body
}

foreach ($t in $queue) {
    $oid = "$($t.OpportunityId)"
    $lid = "$($t.ProspectId)"

    # --- 1. re-read live: has a rep filled the fields since the scan? -------------------
    $det = $null
    try {
        $det = Get-LsqOpportunityDetails -OpportunityId $oid -Config $cfg
    } catch {
        $failed++
        Write-LsqLog "  FAIL $oid - detail read failed, not deleting: $($_.Exception.Message)" $logPath
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }
    $nowValue = $det.Fields['mx_Custom_6'].Value
    $nowDate  = $det.Fields['mx_Custom_8'].Value
    if ((Test-LsqForecastValue $nowValue) -and (Test-LsqForecastDate $nowDate)) {
        $skippedNowFilled++
        Write-LsqLog "  SKIP $oid - forecast has been filled in since the scan (value='$nowValue' date='$nowDate')" $logPath
        Add-Content -Path $ckptPath -Value $oid
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }
    if ("$($det.Status)" -ne "Open") {
        Write-LsqLog "  SKIP $oid - status is now '$($det.Status)', not Open" $logPath
        Add-Content -Path $ckptPath -Value $oid
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }

    # The contract evidence that only the full record carries. Any one of these means real
    # commercial progress, and a missing FORECAST field says nothing about a deal that has
    # already produced paperwork or money.
    $contractEvidence = @()
    foreach ($ev in @(
        @{ F='mx_Custom_7';  Label='Actual Deal Size' },
        @{ F='mx_Custom_9';  Label='Actual Closure Date' },
        @{ F='mx_Custom_14'; Label='Contract Start Date' },
        @{ F='mx_Custom_15'; Label='Contract End Date' },
        @{ F='mx_Custom_16'; Label='Agreement Sent Date' },
        @{ F='mx_Custom_17'; Label='Invoice Sent Date' }
    )) {
        $v = "$($det.Fields[$ev.F].Value)".Trim()
        if ($v -and $v -ne '0') { $contractEvidence += "$($ev.Label)='$v'" }
    }
    if ($contractEvidence.Count -gt 0) {
        Write-LsqLog "  SKIP $oid - contracted deal, protected: $($contractEvidence -join ', ')" $logPath
        Add-Content -Path $ckptPath -Value $oid
        $skippedContracted++
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }

    # --- 2. back it up before touching anything -----------------------------------------
    $flat = @{}
    foreach ($k in $det.Fields.Keys) { $flat[$k] = $det.Fields[$k].Value }
    [void]$deleted.Add([pscustomobject]@{
        OpportunityId = $oid; ProspectId = $det.ProspectId; Class = "FORECASTLESS"
        Note = $det.Note; ContactStage = $t.ContactStage; Company = $t.CompanyName; Rep = $t.ContactOwnerName
        Fields = $flat; DeletedAtUtc = ([datetime]::UtcNow).ToString("s")
    })
    [pscustomobject]@{ Stamp=$stamp; Class="FORECASTLESS"; ScanFile=$ScanFile; Deleted=$deleted.ToArray() } |
        ConvertTo-Json -Depth 8 | Set-Content -Path $appliedPath -Encoding UTF8

    # --- 3. demote the contact FIRST -----------------------------------------------------
    # Deliberately before the delete. The contact write goes through Lead/Bulk/UpdateV2, whose
    # attribute naming has never been proven to land on this account - and LeadSquared returns
    # 200 for a write that changes nothing (the gotcha-49 family). If it silently fails, doing
    # it first means the deal is still there and nothing is lost. The other order would leave a
    # deleted deal on a contact still sitting at Prospect.
    $stageMoved = $false
    if (-not $SkipDemote) {
        $before = $null
        try {
            $lr = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
            if ($lr.Count -gt 0) { $before = "$($lr[0].ProspectStage)" }
        } catch { }

        # Only Prospect moves. A contact already Engaged needs no write, and Customer is never
        # touched - demoting a customer is not a hygiene fix, it is a factual error.
        if ($before -eq "Prospect") {
            try {
                $null = Set-ContactStage -LeadId $lid -Stage "Engaged"
                Start-Sleep -Seconds $(if ($firstDemote) { 6 } else { 1 })
                $after = $null
                $lr2 = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
                if ($lr2.Count -gt 0) { $after = "$($lr2[0].ProspectStage)" }
                if ($after -ne "Engaged") {
                    throw "contact reads '$after' after the write, expected 'Engaged'"
                }
                $stageMoved = $true
                [void]$demoted.Add([pscustomobject]@{
                    ProspectId = $lid; FromStage = $before; ToStage = "Engaged"
                    OpportunityId = $oid; Company = $t.CompanyName; Rep = $t.ContactOwnerName
                    AppliedAtUtc = ([datetime]::UtcNow).ToString("s")
                })
                [pscustomobject]@{ Stamp=$stamp; Demoted=$demoted.ToArray() } |
                    ConvertTo-Json -Depth 6 | Set-Content -Path $stagePath -Encoding UTF8
                if ($firstDemote) { Write-LsqLog "  PROOF: contact $lid moved Prospect -> Engaged, verified by re-fetch." $logPath; $firstDemote = $false }
            } catch {
                $demoteFail++
                Write-LsqLog "  SKIP $oid - contact demotion failed, so the deal is left in place: $($_.Exception.Message)" $logPath
                if ($firstDemote) { throw "The first contact demotion FAILED and nothing was deleted. Lead/Bulk/UpdateV2 is not landing on this account - fix that before running at scale." }
                Start-Sleep -Milliseconds $ThrottleMs
                continue
            }
        }
    }

    # --- 4. delete the deal ---------------------------------------------------------------
    try {
        $null = Remove-LsqOpportunity -OpportunityId $oid -Config $cfg
    } catch {
        $failed++
        Write-LsqLog "  FAIL $oid delete -> $($_.Exception.Message)" $logPath
        if ($stageMoved) { Write-LsqLog "       NOTE: contact $lid was already moved to Engaged; it now sits at Engaged holding a deal, which the next run will clear." $logPath }
        if ($isFirst) { throw "The first delete of this run FAILED. Stopping." }
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }
    if ($isFirst) {
        if (-not (Confirm-LsqOpportunityRemoved -OpportunityId $oid -MaxWaitSeconds 45 -Config $cfg)) {
            throw "Delete of $oid reported success but the record still reads back. Stopping before record 2."
        }
        Write-LsqLog "  PROOF: $oid confirmed gone by an independent read." $logPath
    }

    Add-Content -Path $ckptPath -Value $oid
    $ok++
    $isFirst = $false
    if ($ok % 50 -eq 0) { Write-LsqLog "  processed $ok/$($queue.Count) (deleted $ok, demoted $($demoted.Count), skipped-filled $skippedNowFilled, failed $failed)" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

[pscustomobject]@{ Stamp=$stamp; Class="FORECASTLESS"; ScanFile=$ScanFile; Deleted=$deleted.ToArray() } |
    ConvertTo-Json -Depth 8 | Set-Content -Path $appliedPath -Encoding UTF8
if ($demoted.Count -gt 0) {
    [pscustomobject]@{ Stamp=$stamp; Demoted=$demoted.ToArray() } |
        ConvertTo-Json -Depth 6 | Set-Content -Path $stagePath -Encoding UTF8
}

Write-LsqLog "" $logPath
Write-LsqLog "=== done ===" $logPath
Write-LsqLog "  deals deleted            : $ok" $logPath
Write-LsqLog "  contacts demoted         : $($demoted.Count)" $logPath
Write-LsqLog "  skipped (now filled in)  : $skippedNowFilled" $logPath
Write-LsqLog "  skipped (contracted)     : $skippedContracted" $logPath
Write-LsqLog "  delete failures          : $failed" $logPath
Write-LsqLog "  demote failures          : $demoteFail" $logPath
Write-LsqLog "" $logPath
Write-LsqLog "Deal backup     -> $appliedPath" $logPath
if ($demoted.Count -gt 0) { Write-LsqLog "Stage rollback  -> $stagePath" $logPath }
Write-LsqLog "Undo the stage moves with: scripts\remediation\99-restore-contact-stages.ps1 -StageFile $stagePath -Execute" $logPath
