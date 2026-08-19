<#
.SYNOPSIS
  Make fact_opportunity match what LeadSquared actually holds: drop rows for deals that no
  longer exist, and insert the deals the warehouse has never seen.

.DESCRIPTION
  Two independent problems, both of which leave every downstream view wrong.

  1. DELETED DEALS LINGER. No Opportunity_Post_Delete webhook is registered (verified
     2026-08-14) - which is what makes bulk deletion quota-safe, but it also means nothing
     tells the warehouse a deal is gone. Without this pass, deleted deals keep appearing in
     v_deal_board, v_forecast and every rep scorecard.

  2. THE WAREHOUSE NEVER SAW MOST OF THE BOOK. fact_opportunity's only feeder is
     backfill.ps1, whose deal discovery is scoped to contacts CURRENTLY at Prospect or
     Customer (-DealStagesOnly). Deals on contacts that drifted off were never ingested at
     all. That is why the warehouse held ~1,498 rows against a live book several times
     larger - it is a structural blind spot, not drift.

  This is the reconciler that gotcha 11 requires: bulk writes that bypass the event system
  must be paired with something that re-derives state.

  Insert payloads are projected through a FIXED key set. PostgREST rejects a bulk insert
  whose objects do not all carry identical keys (PGRST102), and a hashtable built per row
  drifts the moment one field is missing (gotcha 20).

.EXAMPLE
  powershell.exe -File scripts\remediation\98-reconcile-warehouse.ps1
  powershell.exe -File scripts\remediation\98-reconcile-warehouse.ps1 -Execute

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31). Reads the newest opportunity_scan_*.json.
#>

param(
    [string]$ScanFile = "",
    [switch]$Execute,
    [switch]$SkipInserts,
    [switch]$SkipDeletes
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_warehouse_reconcile_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"

$cfg   = Import-LsqConfig
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']
$hdr   = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

function Get-SbAll {
    param([string]$Query)
    $out = New-Object System.Collections.Generic.List[object]; $offset = 0
    while ($true) {
        $sep = if ($Query -match '\?') { '&' } else { '?' }
        $page = (Invoke-WebRequest -Uri "$sbUrl/rest/v1/$Query$sep`limit=1000&offset=$offset" -Headers $hdr -UseBasicParsing).Content | ConvertFrom-Json
        $n = @($page).Count
        if ($n -eq 0) { break }
        foreach ($r in $page) { [void]$out.Add($r) }
        if ($n -lt 1000) { break }
        $offset += 1000
    }
    return ,$out.ToArray()
}

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Warehouse reconcile [$mode] ===" $logPath

if (-not $ScanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_scan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No scan file found. Run scripts\remediation\00-backup-opportunities.ps1 first." }
    $ScanFile = $newest.FullName
}
$scan = Read-Utf8Json $ScanFile
$live = @($scan.Deals)
Write-LsqLog "Scan file: $ScanFile" $logPath
Write-LsqLog "  live deals in scan : $($live.Count)  (generated $($scan.GeneratedAtUtc) UTC)" $logPath

# A scan that undercounts would delete real warehouse rows. Refuse an obviously short one.
if ($live.Count -lt 500) {
    throw "The scan holds only $($live.Count) deals. That is too few to reconcile against - a truncated scan would delete good warehouse rows. Re-run the full backup scan."
}

$wh = Get-SbAll "fact_opportunity?select=activity_id,prospect_id,stage,status"
Write-LsqLog "  rows in fact_opportunity : $($wh.Count)" $logPath

# ---------------------------------------------------------------------------------------
# TOMBSTONE GUARD - the scan file is a snapshot, and deletions happen after it is taken.
# ---------------------------------------------------------------------------------------
# Without this, reconciling against a scan older than the last delete run would read every
# deleted deal as "live, missing from the warehouse" and INSERT IT BACK. The warehouse would
# then confidently report deals that no longer exist in LeadSquared - worse than the staleness
# this script exists to fix, because it looks authoritative.
#
# Every delete run writes its ids to data/opportunity_*deleted_*.json, and every restore run
# writes old->new ids to data/opportunity_restore_map_*.json. An id that was deleted and NOT
# subsequently restored is a tombstone: it must never be inserted, and if it is still in the
# warehouse it belongs in the stale set regardless of what the scan says.
$tombstones = @{}
foreach ($f in (Get-ChildItem (Join-Path $dataDir "opportunity_deleted_*.json"),(Join-Path $dataDir "opportunity_forecastless_deleted_*.json") -ErrorAction SilentlyContinue)) {
    $j = Read-Utf8Json $f.FullName
    foreach ($d in @($j.Deleted)) { if ($d.OpportunityId) { $tombstones["$($d.OpportunityId)"] = $true } }
}
foreach ($f in (Get-ChildItem (Join-Path $dataDir "opportunity_restore_map_*.json") -ErrorAction SilentlyContinue)) {
    $j = Read-Utf8Json $f.FullName
    foreach ($r in @($j.Restored)) { if ($r.OldOpportunityId) { [void]$tombstones.Remove("$($r.OldOpportunityId)") } }
}
Write-LsqLog "  tombstoned ids (deleted, not restored) : $($tombstones.Count)" $logPath

$scanTombstoned = @($live | Where-Object { $tombstones.ContainsKey("$($_.OpportunityId)") })
if ($scanTombstoned.Count -gt 0) {
    Write-LsqLog "  WARNING: the scan still lists $($scanTombstoned.Count) deal(s) that have since been deleted." $logPath
    Write-LsqLog "           They are excluded from the live set - re-run the discovery scan for a clean picture." $logPath
    $live = @($live | Where-Object { -not $tombstones.ContainsKey("$($_.OpportunityId)") })
    Write-LsqLog "  live deals after tombstone exclusion   : $($live.Count)" $logPath
}

$liveIds = @{}
foreach ($d in $live) { $liveIds["$($d.OpportunityId)"] = $d }
$whIds = @{}
foreach ($r in $wh) { $whIds["$($r.activity_id)"] = $r }

# A tombstoned id is stale even if the scan still lists it - the scan may predate the delete.
$stale   = @($wh   | Where-Object { -not $liveIds.ContainsKey("$($_.activity_id)") -or $tombstones.ContainsKey("$($_.activity_id)") })
$missing = @($live | Where-Object { -not $whIds.ContainsKey("$($_.OpportunityId)") })

Write-LsqLog "" $logPath
Write-LsqLog "  stale   (in warehouse, gone from LSQ) : $($stale.Count)" $logPath
Write-LsqLog "  missing (in LSQ, never ingested)      : $($missing.Count)" $logPath

if (-not $Execute) {
    Write-LsqLog "" $logPath
    Write-LsqLog "DRY RUN - nothing written. Re-run with -Execute." $logPath
    if ($stale.Count -gt 0) {
        Write-LsqLog "  first 5 stale:" $logPath
        foreach ($s in ($stale | Select-Object -First 5)) { Write-LsqLog "    $($s.activity_id)  $($s.stage)/$($s.status)" $logPath }
    }
    if ($missing.Count -gt 0) {
        Write-LsqLog "  first 5 missing:" $logPath
        foreach ($m in ($missing | Select-Object -First 5)) { Write-LsqLog "    $($m.OpportunityId)  $($m.OppStage)/$($m.Status)  $($m.CompanyName)" $logPath }
    }
    return
}

# ---------------------------------------------------------------------------------------
# Deletes
# ---------------------------------------------------------------------------------------
$deleted = 0
if (-not $SkipDeletes -and $stale.Count -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "--- removing $($stale.Count) stale row(s) ---" $logPath
    $batch = New-Object System.Collections.Generic.List[string]
    foreach ($s in $stale) {
        [void]$batch.Add("$($s.activity_id)")
        if ($batch.Count -ge 100) {
            $inList = ($batch | ForEach-Object { '"' + $_ + '"' }) -join ','
            $null = Invoke-WebRequest -Uri "$sbUrl/rest/v1/fact_opportunity?activity_id=in.($inList)" -Method Delete -Headers $hdr -UseBasicParsing
            $deleted += $batch.Count; $batch.Clear()
            Write-LsqLog "  deleted $deleted/$($stale.Count)" $logPath
        }
    }
    if ($batch.Count -gt 0) {
        $inList = ($batch | ForEach-Object { '"' + $_ + '"' }) -join ','
        $null = Invoke-WebRequest -Uri "$sbUrl/rest/v1/fact_opportunity?activity_id=in.($inList)" -Method Delete -Headers $hdr -UseBasicParsing
        $deleted += $batch.Count
    }
    Write-LsqLog "  stale rows removed: $deleted" $logPath
}

# ---------------------------------------------------------------------------------------
# Inserts
# ---------------------------------------------------------------------------------------
$inserted = 0
if (-not $SkipInserts -and $missing.Count -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "--- inserting $($missing.Count) previously invisible deal(s) ---" $logPath

    function ConvertTo-SbTimestamp {
        param([AllowNull()]$Raw)
        if ([string]::IsNullOrWhiteSpace("$Raw")) { return $null }
        try { return ([datetime]"$Raw").ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") } catch { return $null }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($m in $missing) {
        $created = ConvertTo-SbTimestamp $m.CreatedOnUtc
        # created_at_utc is NOT NULL. A row whose timestamp will not parse is skipped rather
        # than given a made-up date that would then look authoritative in every cohort view.
        if (-not $created) { continue }
        # Fixed key set on EVERY object - PostgREST rejects a mixed bulk insert (PGRST102).
        [void]$rows.Add([ordered]@{
            activity_id      = "$($m.OpportunityId)"
            prospect_id      = "$($m.ProspectId)"
            opportunity_name = "$($m.Name)"
            stage            = "$($m.OppStage)"
            status           = "$($m.Status)"
            owner_id         = "$($m.OwnerId)"
            created_at_utc   = $created
            modified_at_utc  = (ConvertTo-SbTimestamp $m.ModifiedOnUtc)
            ingest_source    = "reconcile-$stamp"
        })
    }
    Write-LsqLog "  $($rows.Count) insertable (skipped $($missing.Count - $rows.Count) with an unparseable created date)" $logPath

    $chunk = New-Object System.Collections.Generic.List[object]
    $ins = { param($items)
        $body = ConvertTo-Json @($items) -Depth 5
        $h = $hdr + @{ 'Content-Type' = 'application/json'; Prefer = 'resolution=merge-duplicates' }
        $null = Invoke-WebRequest -Uri "$sbUrl/rest/v1/fact_opportunity" -Method Post -Headers $h -Body ([Text.Encoding]::UTF8.GetBytes($body)) -UseBasicParsing
    }
    foreach ($r in $rows) {
        [void]$chunk.Add($r)
        if ($chunk.Count -ge 200) { & $ins $chunk.ToArray(); $inserted += $chunk.Count; $chunk.Clear(); Write-LsqLog "  inserted $inserted/$($rows.Count)" $logPath }
    }
    if ($chunk.Count -gt 0) { & $ins $chunk.ToArray(); $inserted += $chunk.Count }
    Write-LsqLog "  rows inserted: $inserted" $logPath
}

# ---------------------------------------------------------------------------------------
# Verify independently
# ---------------------------------------------------------------------------------------
$after = Get-SbAll "fact_opportunity?select=activity_id"
Write-LsqLog "" $logPath
Write-LsqLog "=== reconcile done ===" $logPath
Write-LsqLog "  fact_opportunity before : $($wh.Count)" $logPath
Write-LsqLog "  removed                 : $deleted" $logPath
Write-LsqLog "  inserted                : $inserted" $logPath
Write-LsqLog "  fact_opportunity after  : $($after.Count)  (live scan held $($live.Count))" $logPath
if ($after.Count -ne $live.Count) {
    Write-LsqLog "  NOTE: still $([math]::Abs($after.Count - $live.Count)) apart - expected if inserts were skipped or dates failed to parse." $logPath
}
Write-LsqLog "" $logPath
Write-LsqLog "Newly inserted rows carry stage/status/owner only. Run this for the money fields:" $logPath
Write-LsqLog "  powershell.exe -File scripts\pipeline\08-load-opportunity-details.ps1 -OnlyMissing" $logPath
