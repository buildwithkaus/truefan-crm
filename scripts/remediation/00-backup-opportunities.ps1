<#
.SYNOPSIS
  Find every opportunity in the account and back up all 29 fields of each, plus the lead
  context needed to classify it. READ-ONLY against LeadSquared.

.DESCRIPTION
  This is the safety net the rest of the cleanup stands on. Opportunity deletion WORKS
  (gotcha 47) and is irreversible - there is no undelete - so the only thing that makes a
  bulk delete defensible is a backup complete enough to recreate any record from.
  It writes two files:

    data/opportunity_BACKUP_<stamp>.json   every field of every deal + its lead context.
                                           Input to 99-restore-opportunities.ps1.
    data/opportunity_scan_<stamp>.json     the same data shaped for the audit, so
                                           opportunity-hygiene-audit.ps1 can re-run offline
                                           at zero API cost via -ScanFile.

  WHY THE CANDIDATE SET IS A UNION, NEVER A SINGLE SOURCE
  ------------------------------------------------------
  There is no bulk opportunity read. Deals are reachable only per lead, so "every deal" means
  "every lead that might hold one" - and every available source of that list is incomplete in
  a DIFFERENT direction:

    fact_opportunity (Supabase)   its only feeder scopes to contacts CURRENTLY at Prospect or
                                  Customer (backfill.ps1 -DealStagesOnly), so it is structurally
                                  blind to deals on contacts that drifted off - which is exactly
                                  the population this cleanup exists to fix. 1,498 rows against
                                  4,404 deals created in Phase 3.
    the migration worklists       complete for July, blind to anything created since.
    a full-book Leads.Get scan    gives stage/owner/primary for everyone but says nothing about
                                  who holds a deal.
    ProspectActivityName_Max      holds ONE value, so it only sees leads whose LAST activity was
                                  the opportunity. Additive only - never an exclusion (gotcha 14).

  Unioned they cover each other. Subtracting one from another would reintroduce the blind spot.

  AND THE PER-LEAD READ ITSELF UNDER-REPORTS
  -----------------------------------------
  GetOpportunitiesOfLead is index-backed and returns 0 deals for a lead that demonstrably has
  one (gotcha 48). So any candidate that a source SAID holds a deal, but which reads back empty,
  is re-checked against the activity trail (EventCode 12000), which is authoritative and
  immediate. Those leads are counted and reported - a silent zero there would delete nothing and
  look like success.

.PARAMETER ExpectedOpportunityCount
  The total from the LeadSquared UI Opportunity grid - the only count independent of every API
  path AND of the warehouse (hard rule 4). Read from data/opportunity_census_expected.txt when
  not passed. The run REFUSES to write a backup that misses it by more than -TolerancePct.

.EXAMPLE
  powershell.exe -File scripts\remediation\00-backup-opportunities.ps1 -Limit 50
  powershell.exe -File scripts\remediation\00-backup-opportunities.ps1 -ExpectedOpportunityCount 1512

.NOTES
  ASCII only. Windows PowerShell 5.1 - pwsh is not installed (gotcha 31).
  One API call per lead. ~5-6k leads at 250ms is roughly an hour - run it overnight with no
  other LeadSquared script competing for the account-wide rate limit.
#>

param(
    [int]$ExpectedOpportunityCount = 0,
    [double]$TolerancePct = 2.0,
    [switch]$NoCensusGuard,
    [int]$Limit = 0,
    [int]$ThrottleMs = 250,
    [switch]$SkipDetails,
    [switch]$Resume
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_backup_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$ckptPath = Join-Path $dataDir "opportunity_backup_checkpoint.json"

$cfg = Import-LsqConfig

Write-LsqLog "" $logPath
Write-LsqLog "=== Opportunity backup + scan [$stamp] ===" $logPath

# ---------------------------------------------------------------------------------------
# The census guard, resolved BEFORE any work (hard rule 4)
# ---------------------------------------------------------------------------------------
$censusPath = Join-Path $dataDir "opportunity_census_expected.txt"
if ($ExpectedOpportunityCount -le 0 -and (Test-Path $censusPath)) {
    foreach ($line in (Get-Content $censusPath)) {
        if ($line -match '^\s*(\d+)') { $ExpectedOpportunityCount = [int]$matches[1]; break }
    }
}
if ($ExpectedOpportunityCount -gt 0) {
    Write-LsqLog "Census guard: expecting ~$ExpectedOpportunityCount opportunities (+/- $TolerancePct%)" $logPath
} elseif ($NoCensusGuard) {
    Write-LsqLog "WARNING: running with NO independent census guard. A truncated scan will look like a clean one." $logPath
} else {
    throw @"
No expected opportunity count available.

Open the Opportunity grid in the LeadSquared UI, read the total, and write it to:
  $censusPath

It is the only count independent of both the API paths this script uses and the warehouse,
which is the entire point of hard rule 4 - without it, a scan that quietly stops early
reports a complete backup. Pass -NoCensusGuard to override for an exploratory run.
"@
}

function Get-SbAll {
    param([string]$Query)
    $sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/'); $sbKey = $cfg['SUPABASE_SERVICE_KEY']
    $hdr = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }
    $out = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $sep = if ($Query -match '\?') { '&' } else { '?' }
        # PostgREST caps a page at 1000. Paging is not optional: a single unpaged read of
        # fact_opportunity returns exactly 1000 of 1498 rows and looks like the whole table.
        $page = (Invoke-WebRequest -Uri "$sbUrl/rest/v1/$Query$sep`limit=1000&offset=$offset" -Headers $hdr -UseBasicParsing).Content | ConvertFrom-Json
        $n = @($page).Count
        if ($n -eq 0) { break }
        foreach ($r in $page) { [void]$out.Add($r) }
        if ($n -lt 1000) { break }
        $offset += 1000
    }
    return ,$out.ToArray()
}

function Read-JsonIds {
    param([string]$Path, [string]$Property = "ProspectId")
    if (-not (Test-Path $Path)) { return @() }
    $raw = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
    $obj = $raw | ConvertFrom-Json
    return @($obj | ForEach-Object { "$($_.$Property)" } | Where-Object { $_ })
}

# =======================================================================================
# 1. Negative controls (hard rule 1) - before trusting a single filter
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- negative controls ---" $logPath
$controls = @()
foreach ($nc in @(
    @{ Id="N1"; Name="ProspectStage";            Value="__NoSuchStage__" },
    @{ Id="N2"; Name="ProspectActivityName_Max"; Value="__NoSuchActivity__" }
)) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName=$nc.Name; LookupValue=$nc.Value; SqlOperator="=" } -ColumnsCsv "ProspectID" -PageSize 10))
    $ok = ($rows.Count -eq 0)
    $controls += [pscustomobject]@{ Control=$nc.Id; Filter="$($nc.Name)='$($nc.Value)'"; Rows=$rows.Count; Pass=$ok }
    Write-LsqLog ("  [{0}] {1} {2} -> {3} row(s)" -f $(if($ok){"PASS"}else{"FAIL"}), $nc.Id, $nc.Name, $rows.Count) $logPath
    if (-not $ok) { throw "Negative control $($nc.Id) FAILED: a filter that must match nothing returned $($rows.Count) rows. Every filter in this script is now untrustworthy." }
}

# =======================================================================================
# 2. Full-book scan: stage, owner, primary flag, company for EVERY lead
# =======================================================================================
# Not obtainable from Supabase - dim_contact_book has no is_primary_contact column, and the
# primary-contact rule decides whether a Prospect may be given a deal at all.
Write-LsqLog "" $logPath
Write-LsqLog "--- full book scan ---" $logPath
$book = @{}
$cols = "ProspectID,ProspectStage,OwnerId,OwnerIdName,Company,RelatedCompanyId,IsPrimaryContact,ProspectActivityDate_Max,ProspectActivityName_Max,FirstName,LastName"
$page = 1
$scanned = 0
while ($true) {
    # Sort on the IMMUTABLE CreatedOn: paging over a column that moves while you page
    # reshuffles rows between pages and silently drops some.
    #
    # The operator is "<>", not "!=". LeadSquared accepts only = LIKE > < <= >= <> IN, and "!="
    # returns HTTP 500 with MXInvalidEntityException - which the retry wrapper classifies as
    # transient and repeats four times before failing.
    $resp = Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=""; SqlOperator="<>" } `
        -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn" -SortDirection "0"
    $rows = @(Expand-LsqRows $resp)
    if ($rows.Count -eq 0) { break }
    foreach ($r in $rows) { $book["$($r.ProspectID)"] = $r }
    $scanned += $rows.Count
    if ($page % 10 -eq 0) { Write-LsqLog "  page $page, $scanned leads" $logPath }
    if ($rows.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 120
}
Write-LsqLog "Book scanned: $($book.Count) leads over $page page(s)" $logPath
if ($book.Count -lt 80000) {
    throw "Book scan returned only $($book.Count) leads. The account held ~91,000 on 2026-08-13. Refusing to build a candidate set from a truncated scan."
}

$stageTally = @{}
foreach ($l in $book.Values) {
    $s = "$($l.ProspectStage)"; if (-not $s) { $s = "<blank>" }
    if ($stageTally.ContainsKey($s)) { $stageTally[$s]++ } else { $stageTally[$s] = 1 }
}
Write-LsqLog "  contact stages:" $logPath
foreach ($kv in ($stageTally.GetEnumerator() | Sort-Object Value -Descending)) {
    Write-LsqLog ("    {0,-18} {1}" -f $kv.Key, $kv.Value) $logPath
}

# =======================================================================================
# 3. Candidate union
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- candidate union ---" $logPath
$candidates = New-Object 'System.Collections.Generic.HashSet[string]'
$sourceCounts = [ordered]@{}

function Add-Candidates {
    param([string]$Label, [string[]]$Ids)
    $before = $candidates.Count
    foreach ($id in $Ids) { if ($id) { [void]$candidates.Add($id) } }
    $sourceCounts[$Label] = @{ Supplied = @($Ids).Count; New = ($candidates.Count - $before) }
    Write-LsqLog ("  {0,-34} supplied {1,6}  new {2,6}  running {3,6}" -f $Label, @($Ids).Count, ($candidates.Count - $before), $candidates.Count) $logPath
}

Add-Candidates "backfill worklist (Phase 3)"   (Read-JsonIds (Join-Path $dataDir "opportunity_backfill_worklist.json"))
Add-Candidates "backfill stragglers"           (Read-JsonIds (Join-Path $dataDir "opportunity_backfill_stragglers.json"))
Add-Candidates "migration worklist"            (Read-JsonIds (Join-Path $dataDir "migration_worklist_opportunities.json"))

$sbDeals = Get-SbAll "fact_opportunity?select=activity_id,prospect_id"
Add-Candidates "warehouse fact_opportunity"    (@($sbDeals | ForEach-Object { "$($_.prospect_id)" }))

Add-Candidates "book: Prospect or Customer"    (@($book.Values | Where-Object { "$($_.ProspectStage)" -in @("Prospect","Customer") } | ForEach-Object { "$($_.ProspectID)" }))
Add-Candidates "book: last activity=Opportunity" (@($book.Values | Where-Object { "$($_.ProspectActivityName_Max)" -eq "Opportunity" } | ForEach-Object { "$($_.ProspectID)" }))
Add-Candidates "book: IsPrimaryContact"        (@($book.Values | Where-Object { Test-LsqTrue $_.IsPrimaryContact } | ForEach-Object { "$($_.ProspectID)" }))

# Leads named by a source but absent from the book scan would be invisible to classification.
$orphans = @($candidates | Where-Object { -not $book.ContainsKey($_) })
Write-LsqLog "Candidates: $($candidates.Count) leads ($($orphans.Count) not present in the book scan - deleted or merged leads)" $logPath

# The set of leads a source ASSERTS holds a deal. Used below to decide when an empty read
# deserves a trail cross-check rather than being believed.
$assertedDeal = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($d in $sbDeals) { [void]$assertedDeal.Add("$($d.prospect_id)") }
foreach ($f in @("opportunity_backfill_worklist.json","opportunity_backfill_stragglers.json","migration_worklist_opportunities.json")) {
    foreach ($id in (Read-JsonIds (Join-Path $dataDir $f))) { [void]$assertedDeal.Add($id) }
}

$todo = @($candidates)
if ($Limit -gt 0 -and $todo.Count -gt $Limit) {
    $todo = $todo[0..($Limit-1)]
    Write-LsqLog "LIMITED to the first $Limit candidates (smoke test - the census guard is skipped)" $logPath
}

# =======================================================================================
# 4. Per-lead opportunity read, with a trail fallback for the lagging endpoint
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- reading deals for $($todo.Count) candidates ---" $logPath

$deals       = New-Object System.Collections.Generic.List[object]
$startIdx    = 0
$readFails   = New-Object System.Collections.Generic.List[string]
$trailRescue = New-Object System.Collections.Generic.List[string]

if ($Resume -and (Test-Path $ckptPath)) {
    $ck = ([IO.File]::ReadAllText($ckptPath, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json
    $startIdx = [int]$ck.Index
    foreach ($d in @($ck.Deals)) { [void]$deals.Add($d) }
    Write-LsqLog "Resuming at index $startIdx with $($deals.Count) deals already read." $logPath
}

for ($i = $startIdx; $i -lt $todo.Count; $i++) {
    $leadId = $todo[$i]
    $found = @()
    try {
        $found = @(Get-LsqOpportunitiesOfLead -ProspectId $leadId -Config $cfg)
    } catch {
        [void]$readFails.Add($leadId)
        Write-LsqLog "  read FAILED for $leadId -> $($_.Exception.Message)" $logPath
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }

    # gotcha 48: the endpoint lags. If a source asserted a deal here and we read none, ask the
    # trail, which is authoritative. Believing the zero would silently drop a real deal from
    # the backup - and then from the audit, and then from the delete list.
    if ($found.Count -eq 0 -and $assertedDeal.Contains($leadId)) {
        try {
            $trailOpps = @(Get-LeadActivities -ProspectId $leadId -Config $cfg |
                Where-Object { "$($_.EventCode)" -eq $Script:OPP_TYPE_ID })
            if ($trailOpps.Count -gt 0) {
                [void]$trailRescue.Add($leadId)
                foreach ($t in $trailOpps) {
                    $found += [pscustomobject]@{
                        OpportunityId = "$(Get-LsqActivityId $t)"
                        ProspectId    = $leadId
                        Name          = "$($t.ActivityFields.mx_Custom_1)"
                        OppStage      = "$($t.ActivityFields.mx_Custom_2)"
                        Status        = "$($t.ActivityFields.Status)"
                        OwnerId       = "$($t.ActivityFields.Owner)"
                        OwnerName     = ""
                        ExpectedDealSize = $null
                        ExpectedCloseDate = $null
                        Note          = ""
                        CreatedOnUtc  = "$($t.CreatedOn)"
                        ModifiedOnUtc = ""
                        Source        = "trail"
                    }
                }
            }
        } catch {
            Write-LsqLog "  trail cross-check failed for $leadId -> $($_.Exception.Message)" $logPath
        }
        Start-Sleep -Milliseconds $ThrottleMs
    }

    foreach ($o in $found) {
        $lead = $book[$leadId]
        [void]$deals.Add([pscustomobject]@{
            OpportunityId     = $o.OpportunityId
            ProspectId        = $leadId
            Name              = $o.Name
            OppStage          = $o.OppStage
            Status            = $o.Status
            OwnerId           = $o.OwnerId
            OwnerName         = $o.OwnerName
            ExpectedDealSize  = $o.ExpectedDealSize
            ExpectedCloseDate = $o.ExpectedCloseDate
            Note              = $o.Note
            CreatedOnUtc      = $o.CreatedOnUtc
            ModifiedOnUtc     = $o.ModifiedOnUtc
            DiscoveredVia     = $(if ($o.PSObject.Properties.Name -contains 'Source') { $o.Source } else { "GetOpportunitiesOfLead" })
            ContactStage      = "$($lead.ProspectStage)"
            ContactOwnerId    = "$($lead.OwnerId)"
            ContactOwnerName  = "$($lead.OwnerIdName)"
            CompanyName       = "$($lead.Company)"
            CompanyId         = "$($lead.RelatedCompanyId)"
            IsPrimaryContact  = [bool](Test-LsqTrue $lead.IsPrimaryContact)
            ContactName       = "$($lead.FirstName) $($lead.LastName)".Trim()
            LastActivityUtc   = "$($lead.ProspectActivityDate_Max)"
            Details           = $null
        })
    }

    if ($i % 100 -eq 0) {
        Write-LsqLog "  $i/$($todo.Count) scanned, $($deals.Count) deals, $($readFails.Count) read failures, $($trailRescue.Count) trail rescues" $logPath
        @{ Index = $i; Deals = $deals.ToArray() } | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $ckptPath
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "" $logPath
Write-LsqLog "Deals found          : $($deals.Count)" $logPath
Write-LsqLog "Read failures        : $($readFails.Count)" $logPath
Write-LsqLog "Trail rescues        : $($trailRescue.Count)  (deals GetOpportunitiesOfLead did not return)" $logPath

# =======================================================================================
# 5. Guards - before anything is written (hard rule 4)
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- guards ---" $logPath
$guardFailures = @()

# G2: absolute floor from the migration worklists - deals that provably were created.
$floorIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($f in @("opportunity_backfill_worklist.json","opportunity_backfill_stragglers.json","migration_worklist_opportunities.json")) {
    foreach ($id in (Read-JsonIds (Join-Path $dataDir $f))) { [void]$floorIds.Add($id) }
}
Write-LsqLog "  G2 floor: $($floorIds.Count) leads were given a deal by the migration" $logPath

# G3: the warehouse count, from the server not from the rows.
Write-LsqLog "  G3 warehouse: $($sbDeals.Count) rows in fact_opportunity" $logPath
# Hash-set lookup, not -notin against a rebuilt array. The array form re-materialised all
# 1,558 warehouse ids for each of 3,567 deals - about 5.6 million string comparisons - and the
# run was still sitting in this single line when the session ended, after a clean 45-minute
# scan had already finished. A guard that cannot complete is not a guard.
$whIdSet = @{}
foreach ($w in $sbDeals) { $whIdSet["$($w.activity_id)"] = $true }
$missingFromWarehouse = @($deals | Where-Object { -not $whIdSet.ContainsKey("$($_.OpportunityId)") }).Count
Write-LsqLog "     live deals absent from the warehouse: $missingFromWarehouse (the blind spot backfill.ps1 cannot see)" $logPath

# G1: the independent census.
if ($ExpectedOpportunityCount -gt 0 -and $Limit -le 0) {
    $delta = [math]::Abs($deals.Count - $ExpectedOpportunityCount)
    $pct = if ($ExpectedOpportunityCount -gt 0) { 100.0 * $delta / $ExpectedOpportunityCount } else { 0 }
    Write-LsqLog ("  G1 census: found {0} vs expected {1} (delta {2}, {3:N1}%)" -f $deals.Count, $ExpectedOpportunityCount, $delta, $pct) $logPath
    if ($pct -gt $TolerancePct) {
        $guardFailures += "Census guard: found $($deals.Count) opportunities but the UI grid says $ExpectedOpportunityCount ($([math]::Round($pct,1))% off, tolerance $TolerancePct%)."
    }
}
if ($readFails.Count -gt 0) {
    $guardFailures += "$($readFails.Count) lead(s) could not be read. A backup with holes is worse than none - it looks complete. Re-run with -Resume."
}

if ($guardFailures.Count -gt 0) {
    Write-LsqLog "" $logPath
    foreach ($g in $guardFailures) { Write-LsqLog "  GUARD FAILED: $g" $logPath }
    throw "Refusing to write a backup that failed $($guardFailures.Count) guard(s). Nothing was written. See $logPath."
}
Write-LsqLog "  all guards passed" $logPath

# =======================================================================================
# 6. Full-detail pass - the 29 fields that make a restore possible
# =======================================================================================
if (-not $SkipDetails) {
    Write-LsqLog "" $logPath
    Write-LsqLog "--- full detail read for $($deals.Count) deals ---" $logPath
    $n = 0; $detailFails = 0
    foreach ($d in $deals) {
        $n++
        try {
            $det = Get-LsqOpportunityDetails -OpportunityId $d.OpportunityId -Config $cfg
            $flat = @{}
            foreach ($k in $det.Fields.Keys) { $flat[$k] = $det.Fields[$k].Value }
            $d.Details = $flat
            if (-not $d.Note) { $d.Note = $det.Note }
        } catch {
            $detailFails++
            Write-LsqLog "  detail read failed for $($d.OpportunityId) -> $($_.Exception.Message)" $logPath
        }
        if ($n % 200 -eq 0) { Write-LsqLog "  $n/$($deals.Count) detailed ($detailFails failed)" $logPath }
        Start-Sleep -Milliseconds $ThrottleMs
    }
    Write-LsqLog "Detail reads failed: $detailFails" $logPath
    if ($detailFails -gt 0) {
        Write-LsqLog "WARNING: $detailFails deal(s) have no field-level backup and MUST NOT be deleted - they cannot be restored." $logPath
    }
}

# =======================================================================================
# 7. Write
# =======================================================================================
$backupPath = Join-Path $dataDir "opportunity_BACKUP_$stamp.json"
$scanPath   = Join-Path $dataDir "opportunity_scan_$stamp.json"

$payload = [pscustomobject]@{
    Stamp                    = $stamp
    GeneratedAtUtc           = ([datetime]::UtcNow).ToString("s")
    ExpectedOpportunityCount = $ExpectedOpportunityCount
    BookLeadCount            = $book.Count
    CandidateCount           = $todo.Count
    DealCount                = $deals.Count
    ReadFailures             = $readFails.ToArray()
    TrailRescues             = $trailRescue.ToArray()
    NegativeControls         = $controls
    SourceCounts             = $sourceCounts
    ContactStageTally        = $stageTally
    Deals                    = $deals.ToArray()
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $backupPath -Encoding UTF8
Write-LsqLog "" $logPath
Write-LsqLog "Backup -> $backupPath" $logPath

# The scan file carries the book too, so the audit can classify Prospects with NO deal - which
# by definition do not appear in the deal list.
$scan = [pscustomobject]@{
    Stamp          = $stamp
    GeneratedAtUtc = $payload.GeneratedAtUtc
    Deals          = $deals.ToArray()
    Book           = @($book.Values | ForEach-Object {
        [pscustomobject]@{
            ProspectId       = "$($_.ProspectID)"
            ContactStage     = "$($_.ProspectStage)"
            OwnerId          = "$($_.OwnerId)"
            OwnerName        = "$($_.OwnerIdName)"
            CompanyName      = "$($_.Company)"
            CompanyId        = "$($_.RelatedCompanyId)"
            IsPrimaryContact = [bool](Test-LsqTrue $_.IsPrimaryContact)
            ContactName      = "$($_.FirstName) $($_.LastName)".Trim()
            LastActivityUtc  = "$($_.ProspectActivityDate_Max)"
        }
    })
}
$scan | ConvertTo-Json -Depth 8 | Set-Content -Path $scanPath -Encoding UTF8
Write-LsqLog "Scan   -> $scanPath" $logPath

Set-Content -Path (Join-Path $dataDir "opportunity_LAST_BACKUP_STAMP.txt") -Value $stamp
Remove-Item $ckptPath -ErrorAction SilentlyContinue

Write-LsqLog "" $logPath
Write-LsqLog "=== done. $($deals.Count) deals backed up across $($book.Count) leads ===" $logPath
Write-LsqLog "Next: scripts\reports\opportunity-hygiene-audit.ps1 -ScanFile $scanPath" $logPath
