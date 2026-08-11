<#
.SYNOPSIS
  Snapshot the whole lead book by owner and contact stage into Supabase. Read-only against
  LeadSquared. Run once a day.

.DESCRIPTION
  Answers "what does each rep HOLD", as opposed to every other report here which answers
  "what did each rep DO". A rep with 2,000 assigned contacts of which 1,900 are still Fresh
  is a completely different problem from one holding 200 all at Prospect, and no amount of
  call-volume reporting tells those apart.

  Why a full scan: LeadSquared has no count endpoint (Leads.Count, Leads.Get.Count and
  Leads/Count all 404 as of 2026-08-08) and Leads.Get returns no total, so the only way to
  get these numbers is to page the entire book - roughly 87 pages of 1,000. That is cheap in
  API calls (~90 of a 10,000/day budget) but far too slow for an Apps Script trigger.

  Snapshotting by date rather than overwriting is deliberate: how a book MOVES week to week
  is the more valuable half. A pipeline that has stopped draining looks identical to a
  healthy one in any single-day view.

.EXAMPLE
  pwsh ./scripts/pipeline/03-snapshot-book.ps1 -WhatIf
  pwsh ./scripts/pipeline/03-snapshot-book.ps1

.NOTES
  ASCII only. Needs SUPABASE_URL and SUPABASE_SERVICE_KEY in config\.env.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$MinExpectedLeads = 80000,
    [string]$SnapshotDate = ""
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "pipeline_book_snapshot_log.txt"

$cfg = Import-LsqConfig
foreach ($k in @("SUPABASE_URL", "SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']

# IST date - the book is "as of" a business day, not a UTC one.
if (-not $SnapshotDate) {
    $SnapshotDate = ([datetime]::UtcNow.AddHours(5).AddMinutes(30)).ToString("yyyy-MM-dd")
}

Write-LsqLog "=== Book snapshot for $SnapshotDate ===" $logPath

# ---------------------------------------------------------------------------------------
# Negative control before trusting the filter. A zero result is exactly as suspect as a
# wrong non-zero one - two unverified zeros once silently skipped 20,076 leads here.
# ---------------------------------------------------------------------------------------
$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "CreatedOn"; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">"
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Write-LsqLog "Negative control: $($neg.Count) rows -- must be 0" $logPath
if ($neg.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the filter is being ignored." }

# ---------------------------------------------------------------------------------------
# Full scan. Sorted by the IMMUTABLE CreatedOn: paging over a column that changes underneath
# you reshuffles rows between pages and silently drops some.
# ---------------------------------------------------------------------------------------
# OwnerIdEmailAddress is carried for dim_rep.email. EventCode 3001 (LeadAssigned) identifies
# owners ONLY as "Name (email)" - never as a GUID - so the email is the single safe join key
# back to a rep. Collected here rather than in a separate job because this scan already sees
# every owner in the account, and because a column filled "later" by something else is how
# dim_rep sat empty for a week.
$cols = "ProspectID,OwnerId,OwnerIdName,OwnerIdEmailAddress,ProspectStage,mx_Disqualification_Reason"
$tally = @{}      # "ownerId|ownerName|stage" -> count
$repEmail = @{}   # ownerId -> email
# "ownerId|ownerName|reason" -> count, for contacts at Disqualified only.
#
# Tallied here rather than from dim_contact because dim_contact holds only the ~17,800
# contacts the pipeline has enriched, of which 8,900 are Disqualified - against 61,375 in
# the real book. A per-rep percentage computed on that slice would describe whichever part
# of a rep's book happened to have been called recently, not their disqualified pile.
$disqTally = @{}
$total = 0
$page = 1

Write-LsqLog "Scanning the full book (about 87 pages)..." $logPath
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "CreatedOn"; LookupValue = "2000-01-01 00:00:00"; SqlOperator = ">"
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }

    foreach ($r in $rows) {
        $total++
        $ownerId = "$($r.OwnerId)"
        $ownerName = "$($r.OwnerIdName)"
        $stage = "$($r.ProspectStage)"
        if (-not $ownerId) { $ownerId = "<none>" }
        if (-not $ownerName) { $ownerName = "<unassigned>" }
        if (-not $stage) { $stage = "<blank>" }
        $key = "$ownerId|$ownerName|$stage"
        if ($tally.ContainsKey($key)) { $tally[$key]++ } else { $tally[$key] = 1 }

        $email = "$($r.OwnerIdEmailAddress)".Trim()
        if ($email -and -not $repEmail.ContainsKey($ownerId)) { $repEmail[$ownerId] = $email }

        if ($stage -eq "Disqualified") {
            $reason = "$($r.mx_Disqualification_Reason)".Trim()
            # A blank reason is stored as a real value, not skipped. A disqualification with
            # no reason is the one gap that destroys information permanently - it has to be
            # a countable row on the report rather than an absence that sums to nothing.
            if (-not $reason) { $reason = "<blank>" }
            $dk = "$ownerId|$ownerName|$reason"
            if ($disqTally.ContainsKey($dk)) { $disqTally[$dk]++ } else { $disqTally[$dk] = 1 }
        }
    }
    if ($page % 20 -eq 0) { Write-LsqLog "  page $page -> running total $total" $logPath }
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 300) { Write-LsqLog "  WARNING: stopped at 300 pages" $logPath; break }
}

Write-LsqLog "Scanned $total leads across $page pages into $($tally.Count) owner/stage buckets" $logPath

# Absolute guard against an INDEPENDENT expected size, never against a number derived from
# the same read. A truncated scan reconciles perfectly against itself - that is exactly how
# a one-page scan once reported as a complete account sweep.
if ($total -lt $MinExpectedLeads) {
    throw "Scanned only $total leads, expected at least $MinExpectedLeads. Refusing to write a partial snapshot - it would look like the book shrank overnight."
}

# ---------------------------------------------------------------------------------------
# Report before writing
# ---------------------------------------------------------------------------------------
function Get-StageTotals {
    # PURE - returns the tally, logs nothing.
    param([Parameter(Mandatory)][hashtable]$Tally)
    $byStage = @{}
    foreach ($k in $Tally.Keys) {
        $stage = $k.Split('|')[2]
        if ($byStage.ContainsKey($stage)) { $byStage[$stage] += $Tally[$k] } else { $byStage[$stage] = $Tally[$k] }
    }
    return $byStage
}

$byStage = Get-StageTotals -Tally $tally
Write-LsqLog "" $logPath
Write-LsqLog "--- whole account by contact stage ---" $logPath
$sum = 0
$byStage.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-LsqLog ("  {0,8}  {1}" -f $_.Value, $_.Name) $logPath
    $sum += $_.Value
}
Write-LsqLog ("  reconcile: {0} vs {1} scanned -> {2}" -f $sum, $total, $(if ($sum -eq $total) { "OK" } else { "MISMATCH" })) $logPath
if ($sum -ne $total) { throw "Tally does not reconcile to the scan total. Refusing to write." }

if ($WhatIfPreference) {
    Write-LsqLog "" $logPath
    Write-LsqLog "DRY RUN - nothing written. Would upsert $($tally.Count) rows for $SnapshotDate." $logPath
    return
}

# ---------------------------------------------------------------------------------------
# Write. Fixed key set per row - PostgREST rejects a bulk insert whose objects differ
# ("PGRST102: All object keys must match").
# ---------------------------------------------------------------------------------------
$rows = New-Object System.Collections.Generic.List[object]
foreach ($k in $tally.Keys) {
    $parts = $k.Split('|')
    [void]$rows.Add([ordered]@{
        snapshot_date = $SnapshotDate
        owner_id      = $parts[0]
        owner_name    = $parts[1]
        contact_stage = $parts[2]
        contacts      = $tally[$k]
    })
}

$all = $rows.ToArray()
$headers = @{ apikey = $sbKey; Authorization = "Bearer $sbKey"
              Prefer = "resolution=merge-duplicates,return=minimal" }
$written = 0
for ($i = 0; $i -lt $all.Count; $i += 500) {
    $slice = $all[$i..([Math]::Min($i + 499, $all.Count - 1))]
    $json = ConvertTo-Json -InputObject $slice -Depth 4
    if ($slice.Count -eq 1) { $json = "[$json]" }
    [void](Invoke-LsqWithRetry -What "upsert fact_book_snapshot" -Action {
        Invoke-RestMethod -Uri "$sbUrl/rest/v1/fact_book_snapshot" -Method Post `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -Headers $headers `
            -ContentType "application/json; charset=utf-8" -ErrorAction Stop
    })
    $written += $slice.Count
}

Write-LsqLog "" $logPath
Write-LsqLog "Wrote $written rows for $SnapshotDate." $logPath

# ---------------------------------------------------------------------------------------
# Keep dim_rep current, from the same scan.
#
# dim_rep is the owner_id -> name map every report joins through, and it sat EMPTY from
# migration 001 until 2026-08-09 because nothing ever populated it. The symptom was subtle:
# most views coalesce through dim_contact and looked fine, but anywhere that fallback did not
# apply - stage changes made by someone holding no contacts, for one - a raw GUID appeared on
# a rep-facing tab as though it were a person.
#
# This scan already sees every owner in the account, so it is the natural place to maintain
# it. Cheap: no extra API calls, one upsert.
# ---------------------------------------------------------------------------------------
$repRows = New-Object System.Collections.Generic.List[object]
$seenRep = @{}
foreach ($k in $tally.Keys) {
    $parts = $k.Split('|')
    $oid = $parts[0]; $nm = $parts[1]
    if (-not $oid -or -not $nm -or $seenRep.ContainsKey($oid)) { continue }
    $seenRep[$oid] = $true
    [void]$repRows.Add([ordered]@{
        owner_id     = $oid
        lsq_name     = $nm
        # Fixed key set on every row - PostgREST rejects a bulk insert whose objects differ
        # (PGRST102), so the email must be present on all of them or none.
        email        = $(if ($repEmail.ContainsKey($oid)) { $repEmail[$oid] } else { $null })
        is_active    = $true
        last_seen_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    })
}
if ($repRows.Count -gt 0) {
    $rj = ConvertTo-Json -InputObject $repRows.ToArray() -Depth 4
    if ($repRows.Count -eq 1) { $rj = "[$rj]" }
    [void](Invoke-LsqWithRetry -What "upsert dim_rep" -Action {
        Invoke-RestMethod -Uri "$sbUrl/rest/v1/dim_rep" -Method Post `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($rj)) -Headers $headers `
            -ContentType "application/json; charset=utf-8" -ErrorAction Stop
    })
    Write-LsqLog "Refreshed dim_rep: $($repRows.Count) owners." $logPath
}

# ---------------------------------------------------------------------------------------
# Disqualification reason snapshot, from the SAME scan - no extra API calls.
#
# Written last, and after the book snapshot and dim_rep have already been persisted, so a
# failure in this newer block cannot cost the day's book numbers.
# ---------------------------------------------------------------------------------------
$disqRows = New-Object System.Collections.Generic.List[object]
$disqTotal = 0
foreach ($dk in $disqTally.Keys) {
    $parts = $dk.Split('|')
    $disqTotal += $disqTally[$dk]
    [void]$disqRows.Add([ordered]@{
        snapshot_date = $SnapshotDate
        owner_id      = $parts[0]
        owner_name    = $parts[1]
        reason        = $parts[2]
        contacts      = $disqTally[$dk]
    })
}

# Reconcile against the stage tally from the same pass. These are two independent counts of
# the same population, so a mismatch means the reason branch missed rows - which would show
# up as a quietly small disqualified pile, not as an error.
$disqFromStages = 0
foreach ($kk in $tally.Keys) { if ($kk.Split('|')[2] -eq "Disqualified") { $disqFromStages += $tally[$kk] } }
Write-LsqLog "" $logPath
Write-LsqLog ("Disqualified reconcile: reason tally {0} vs stage tally {1} -> {2}" -f `
    $disqTotal, $disqFromStages, $(if ($disqTotal -eq $disqFromStages) { "OK" } else { "MISMATCH" })) $logPath
if ($disqTotal -ne $disqFromStages) { throw "Disqualification tally does not reconcile to the stage tally. Refusing to write." }

if ($disqRows.Count -gt 0) {
    $all2 = $disqRows.ToArray()
    $written2 = 0
    for ($i = 0; $i -lt $all2.Count; $i += 500) {
        $slice = $all2[$i..([Math]::Min($i + 499, $all2.Count - 1))]
        $j2 = ConvertTo-Json -InputObject $slice -Depth 4
        if ($slice.Count -eq 1) { $j2 = "[$j2]" }
        [void](Invoke-LsqWithRetry -What "upsert fact_disqualification_snapshot" -Action {
            Invoke-RestMethod -Uri "$sbUrl/rest/v1/fact_disqualification_snapshot" -Method Post `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($j2)) -Headers $headers `
                -ContentType "application/json; charset=utf-8" -ErrorAction Stop
        })
        $written2 += $slice.Count
    }
    Write-LsqLog "Wrote $written2 disqualification rows ($disqTotal contacts, $($disqRows.Count) owner/reason pairs)." $logPath
}

Write-LsqLog "Verify independently rather than trusting this line:" $logPath
Write-LsqLog "  GET /rest/v1/v_pipeline_state_wide?select=*" $logPath
Write-LsqLog "  GET /rest/v1/v_disqualified_by_rep?select=*" $logPath
