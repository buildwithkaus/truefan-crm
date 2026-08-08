<#
.SYNOPSIS
  Diff ONE rep's calls for ONE day, activity id by activity id, between LeadSquared and the
  warehouse. Prints the specific rows that differ.

.DESCRIPTION
  verify-against-oracle.ps1 answers "do the totals match" across the whole team, at a cost of
  one API call per candidate lead - 4,834 for a single day. When it reports a rep off by two,
  re-running it to find WHICH two costs another 4,834 calls.

  This narrows the scan to one owner first, which is typically a couple of hundred leads, and
  then lists the actual activity ids on each side. That turns "off by 2" into two rows you
  can look at.

  READ-ONLY.

.PARAMETER Rep
  The rep's name exactly as LeadSquared stores it (OwnerIdName). Note that a name in a
  spreadsheet is not necessarily the name in LSQ - see memory/04.

.EXAMPLE
  pwsh ./scripts/pipeline/06-diff-rep-day.ps1 -Rep "Akshita Sharma" -TargetDate 2026-08-07

.NOTES
  ASCII only. Needs SUPABASE_URL and SUPABASE_SERVICE_KEY in config\.env.
#>

param(
    [Parameter(Mandatory)][string]$Rep,
    [Parameter(Mandatory)][string]$TargetDate
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$cfg = Import-LsqConfig
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']
$sbHead = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "pipeline_repdiff_log.txt"

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$dayIst    = [datetime]::ParseExact($TargetDate, "yyyy-MM-dd", $inv)
$startUtc  = $dayIst.AddHours(-5).AddMinutes(-30)
$endUtc    = $startUtc.AddDays(1)

Write-LsqLog "=== Rep diff: $Rep on $TargetDate ===" $logPath
Write-LsqLog "UTC window [$($startUtc.ToString('yyyy-MM-dd HH:mm:ss')), $($endUtc.ToString('yyyy-MM-dd HH:mm:ss')))" $logPath

# ---------------------------------------------------------------------------------------
# 1. The warehouse side. Cheap - no API calls.
#
# Attribution rule (memory/10, non-negotiable): a call belongs to a rep only when the
# DIALLER is the lead's current owner. The pipeline stores actor_owner_id; the join to
# dim_contact.owner_name is what makes it a named rep.
# ---------------------------------------------------------------------------------------
function Get-SbAll {
    param([string]$Query)
    $out = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $sep = if ($Query -match '\?') { '&' } else { '?' }
        # PostgREST caps a page at 1000 regardless of the limit asked for, and the Range
        # header is a restricted .NET header PowerShell 5.1 will not set from a hashtable -
        # so paging goes through limit/offset query params.
        $uri = "$sbUrl/rest/v1/$Query$sep" + "limit=1000&offset=$offset"
        $page = ((Invoke-WebRequest -Uri $uri -Headers $sbHead -UseBasicParsing).Content | ConvertFrom-Json)
        $n = @($page).Count
        if ($n -eq 0) { break }
        foreach ($r in $page) { [void]$out.Add($r) }
        if ($n -lt 1000) { break }
        $offset += 1000
    }
    return $out.ToArray()
}

$repEsc = [uri]::EscapeDataString($Rep)
# v_call_enriched names the owner contact_owner_name (there is no bare "rep" column), and
# is_owner_call carries the attribution rule itself - the dialler was the lead's current
# owner. Both are needed: filtering on the name alone would count a previous owner's calls
# on a lead this rep has since inherited.
$pipeRows = Get-SbAll ("v_call_enriched?select=activity_id,prospect_id,called_at_utc," +
                       "contact_owner_name,actor_name,direction,connected,duration_sec,status" +
                       "&call_date_ist=eq.$TargetDate&direction=eq.outbound" +
                       "&contact_owner_name=eq.$repEsc&is_owner_call=is.true" +
                       "&order=called_at_utc")
Write-LsqLog "Warehouse: $($pipeRows.Count) outbound calls" $logPath

# ---------------------------------------------------------------------------------------
# 2. Find the rep's owner GUID. Never match on name downstream - memory/04 records a
#    name-to-GUID mismatch that dragged 2,360 of the wrong rep's leads into a migration.
# ---------------------------------------------------------------------------------------
$repRow = Get-SbAll ("dim_contact?select=owner_id,owner_name&owner_name=eq.$repEsc&limit=1")
if (-not $repRow -or $repRow.Count -eq 0) { throw "No contact in dim_contact is owned by '$Rep'. Check the exact LSQ spelling." }
$ownerId = $repRow[0].owner_id
Write-LsqLog "Owner GUID: $ownerId" $logPath

# ---------------------------------------------------------------------------------------
# 3. The LSQ side, scoped to this owner. Negative control first - hard rule 1.
# ---------------------------------------------------------------------------------------
$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "OwnerId"; LookupValue = "00000000-0000-0000-0000-000000000000"; SqlOperator = "="
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Write-LsqLog "Negative control (OwnerId = all-zero GUID): $($neg.Count) rows -- must be 0" $logPath
if ($neg.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the OwnerId filter is being ignored." }

# Leads.Get takes a SINGLE Parameter - there is no way to AND OwnerId with a date server
# side. So: page the owner's book (cheap, one call per 1,000 leads), carrying
# ProspectActivityDate_Max, and narrow to recently-active leads in memory before spending an
# API call per trail.
#
# The date test is >= the START of the target day and is deliberately open-ended upward. That
# field holds a SINGLE value - the last activity - so a lead called on the target date and
# touched again afterwards must still qualify. Bounding it at the end of the day would drop
# exactly those leads and manufacture a disagreement.
#
# The first version of this script skipped the narrowing and pulled every trail in the book.
# For a rep holding 8,935 leads that is more API calls than the whole-team oracle it exists
# to be cheaper than.
$books = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "OwnerId"; LookupValue = $ownerId; SqlOperator = "="
    } -ColumnsCsv "ProspectID,ProspectActivityDate_Max" -PageIndex $page -PageSize 1000 `
      -SortColumn "ProspectActivityDate_Max"))
    if ($rows.Count -eq 0) { break }
    foreach ($r in $rows) { [void]$books.Add($r) }
    Write-LsqLog "  book page $page -> $($rows.Count) (total $($books.Count))" $logPath
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 60) { Write-LsqLog "  WARNING: stopped paging at 60 pages" $logPath; break }
}

$candidates = New-Object System.Collections.Generic.List[string]
$noDate = 0
foreach ($r in $books) {
    # ProspectActivityDate_Max carries MILLISECONDS where activity CreatedOn does not
    # (gotcha 17). ConvertFrom-LsqUtc handles both; a parser missing .fff returns null and
    # every lead silently drops out, which looks like a quiet day rather than a bug.
    $last = ConvertFrom-LsqUtc "$($r.ProspectActivityDate_Max)"
    if ($null -eq $last) { $noDate++; [void]$candidates.Add("$($r.ProspectID)"); continue }
    if ($last -ge $startUtc) { [void]$candidates.Add("$($r.ProspectID)") }
}
Write-LsqLog ("Book {0} leads -> {1} active since {2} ({3} with an unparseable date, kept)" -f `
    $books.Count, $candidates.Count, $startUtc.ToString('yyyy-MM-dd HH:mm'), $noDate) $logPath
if ($candidates.Count -eq 0) { throw "Zero candidates - refusing to report a clean diff against nothing." }

$lsqCalls = @{}
$done = 0; $failed = 0
foreach ($leadId in $candidates) {
    try { $acts = Get-LeadActivities -ProspectId $leadId -Config $cfg }
    catch { $failed++; continue }
    foreach ($a in @($acts)) {
        if ("$($a.EventCode)" -ne "22") { continue }
        $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
        if ($null -eq $when -or $when -lt $startUtc -or $when -ge $endUtc) { continue }
        # Owner-attribution: only count it when the DIALLER is the current owner.
        if ("$($a.ActivityFields.CreatedBy)" -ne $ownerId) { continue }
        $lsqCalls[(Get-LsqActivityId $a)] = [pscustomobject]@{
            activity_id = (Get-LsqActivityId $a)
            prospect_id = $leadId
            called_at_utc = $when
            duration = (Get-LsqCallDuration $a)
            status = "$($a.ActivityFields.Status)"
        }
    }
    $done++
    if ($done % 200 -eq 0) { Write-LsqLog "  trails $done/$($candidates.Count)" $logPath }
    Start-Sleep -Milliseconds 200
}
Write-LsqLog "LSQ: $($lsqCalls.Count) owner-attributed outbound calls ($failed trail failures)" $logPath

# ---------------------------------------------------------------------------------------
# 4. The diff.
# ---------------------------------------------------------------------------------------
$pipeSet = @{}
foreach ($p in $pipeRows) { $pipeSet["$($p.activity_id)"] = $p }

$missingFromPipe = @($lsqCalls.Keys | Where-Object { -not $pipeSet.ContainsKey($_) })
$extraInPipe     = @($pipeSet.Keys  | Where-Object { -not $lsqCalls.ContainsKey($_) })

Write-LsqLog "" $logPath
Write-LsqLog ("LSQ {0}   warehouse {1}   missing {2}   extra {3}" -f `
    $lsqCalls.Count, $pipeRows.Count, $missingFromPipe.Count, $extraInPipe.Count) $logPath

if ($missingFromPipe.Count -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "--- IN LSQ, NOT IN THE WAREHOUSE (missed ingestion) ---" $logPath
    foreach ($id in $missingFromPipe) {
        $c = $lsqCalls[$id]
        Write-LsqLog ("  {0}  lead {1}  {2}  {3}s  {4}" -f `
            $c.activity_id, $c.prospect_id, $c.called_at_utc.ToString('HH:mm:ss'), $c.duration, $c.status) $logPath
    }
}

if ($extraInPipe.Count -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "--- IN THE WAREHOUSE, NOT IN LSQ (attribution drift, not duplication) ---" $logPath
    Write-LsqLog "  The PK is the LSQ activity id, so these are real distinct activities. The" $logPath
    Write-LsqLog "  usual cause is that the lead has been REASSIGNED since the call: the" $logPath
    Write-LsqLog "  warehouse stored the owner at ingest time, the scan above uses the owner now." $logPath
    foreach ($id in $extraInPipe) {
        $c = $pipeSet[$id]
        Write-LsqLog ("  {0}  lead {1}  {2}  {3}s  {4}" -f `
            $c.activity_id, $c.prospect_id, $c.called_at_utc, $c.duration_sec, $c.status) $logPath
    }
}

if ($missingFromPipe.Count -eq 0 -and $extraInPipe.Count -eq 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "EXACT MATCH - every activity id agrees." $logPath
}
