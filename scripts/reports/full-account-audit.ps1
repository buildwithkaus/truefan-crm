<#
.SYNOPSIS
  READ-ONLY full-account audit: current value distribution and cross-checks across Contact
  Stage, Company Stage, Opportunity Stage, the four migration-owned dropdowns (Call
  Disposition, Disqualification Reason, Disqualification Category, Segment), Needs Contact
  Resourcing, dropdown selectability (stored-value-vs-live-option), and owner/rep
  distribution across all three objects - in one pass, one point in time.

.DESCRIPTION
  Complements, does not replace, 11-audit-post-migration.ps1 (Lead-side stage/dropdown
  distribution, feeds 12/13) and 16-verify-dropdown-coverage.ps1 (selectability only).
  Neither covers Company Stage, Opportunity Stage distribution, or ownership. This script
  re-derives everything from a fresh live scan rather than reading either script's output,
  matching this repo's established idiom - each audit script independently re-derives from
  live data, common.ps1 only exposes request/pagination primitives, never tally logic.

  Four passes:
    A. Leads         - one full paginated scan. Contact Stage, Call Disposition,
                        Disqualification Reason/Category, Segment, Needs Contact
                        Resourcing distributions; legacy-value leakage; owner
                        distribution; builds the scope for pass D.
    B. Companies     - one full paginated scan. Company Stage distribution, legacy
                        leakage, owner distribution.
    C. Dropdown options - one LeadsMetaData.Get call. Cross-checks pass A's already
                        tallied values against the LIVE dropdown, never the hardcoded
                        list in 00-schema.ps1 - that drift is exactly how the Call
                        Disposition / Disqualification Reason mismatches happened
                        (CLAUDE.md gotcha #9).
    D. Opportunities - SCOPED to primary-contact leads at Prospect/Customer from pass A.
                        No bulk read endpoint exists for Opportunities - one API call
                        per lead - so this must stay bounded, never sweep the account.
                        Opportunity Stage distribution, missing/fragmented
                        Opportunities, owner distribution.

  Also flags any Lead/Company/Opportunity currently owned by a departed owner (a Phase 2
  regression) and any owner GUID that is neither a known active rep nor a known departed
  owner ("unknown owner").

  Writes nothing to the CRM. Every full scan reconciles against an absolute floor
  (a documented account size, not just internal sum-equals-total) before any tally is
  trusted - see CLAUDE.md's "enumerate values, never probe a guessed list" corollary.

.NOTES
  pwsh ./scripts/leadsquared/migration/18-full-account-audit.ps1

  Do not run alongside any other live-API script - this alone uses a meaningful share of
  the account-wide rate limit (20 calls/5 sec) for its roughly 8-12 minute runtime,
  dominated by the scoped per-lead Opportunity calls in pass D.
#>

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $dataDir "full_account_audit_log.txt"
$jsonPath = Join-Path $dataDir "full_account_audit_$stamp.json"
$summaryPath = Join-Path $dataDir "full_account_audit_summary_$stamp.md"

Write-LsqLog "=== Full account audit (READ-ONLY) ===" $logPath

# -----------------------------------------------------------------------------------------
# Reference data: active reps + departed owners, for the ownership regression check.
# -----------------------------------------------------------------------------------------
$activeRepPath = Join-Path $dataDir "active_rep_ids_temp.json"
$departedPath  = Join-Path $dataDir "departed_owner_ids.json"
if (-not (Test-Path $activeRepPath)) { throw "Missing $activeRepPath - needed for the owner regression check." }
if (-not (Test-Path $departedPath))  { throw "Missing $departedPath - needed for the owner regression check." }

$activeById = @{}
# Expand-LsqRows is required here, not just on API responses. Confirmed live 2026-07-31:
# once common.ps1 + 00-schema.ps1 are dot-sourced, ConvertFrom-Json on this same file in
# this same process returns a 1-element array wrapping the real 18-element array instead
# of the flat array an isolated process returns for byte-identical input - the same
# per-process nested-wrapping bug documented in common.ps1 for Invoke-RestMethod (gotcha
# #8), just triggered here by a local file read instead of an API call. Without this, the
# ownership regression check silently ran off 1 "active rep" instead of 18.
foreach ($r in @(Expand-LsqRows (Get-Content $activeRepPath -Raw | ConvertFrom-Json))) { $activeById[$r.OwnerId] = $r.Name }
Write-LsqLog "Active reps loaded: $($activeById.Count)" $logPath
# Guard against a truncated/corrupted read of the reference file (18 expected, see
# memory/04-active-rep-roster.md) rather than silently running the ownership regression
# check off bad reference data - same "abort on a short read" philosophy as the two full
# scans below.
if ($activeById.Count -lt 15) { throw "Only $($activeById.Count) active reps loaded from $activeRepPath (expected ~18) - refusing to run the ownership regression check from suspect reference data." }

$departedById = @{}
foreach ($p in (Get-Content $departedPath -Raw | ConvertFrom-Json).PSObject.Properties) { $departedById[$p.Value] = $p.Name }
Write-LsqLog "Departed owners loaded: $($departedById.Count)" $logPath

# Disjointness self-check (memory/05: departed_owner_ids.json once attached "Piyush Das
# Pattnaik" to Rishi Saraswat's REAL active OwnerId - the Phase 2 mixup). A hard abort here
# would make this read-only audit permanently unrunnable over a known, already-remediated-
# in-the-data issue, so instead: drop the overlapping id(s) from the departed set used
# below, and surface it loudly so the source file gets corrected.
$overlap = @($activeById.Keys | Where-Object { $departedById.ContainsKey($_) })
foreach ($id in $overlap) {
    Write-LsqLog ("WARNING: OwnerId $id is BOTH an active rep ('$($activeById[$id])') and in departed_owner_ids.json (labelled '$($departedById[$id])'). Excluding from the departed set for this audit. departed_owner_ids.json needs correcting - see memory/05.") $logPath
    $departedById.Remove($id)
}

function Get-OwnerClass {
    param([string]$OwnerId)
    if ([string]::IsNullOrWhiteSpace($OwnerId)) { return "BLANK" }
    if ($activeById.ContainsKey($OwnerId))   { return "ACTIVE" }
    if ($departedById.ContainsKey($OwnerId)) { return "DEPARTED" }
    return "UNKNOWN"
}

function Get-OwnerTally {
    param([System.Collections.Generic.List[object]]$Items, [string]$IdField, [string]$NameField)
    $t = @{}
    foreach ($it in $Items) {
        $id = "$($it.$IdField)"
        if ([string]::IsNullOrWhiteSpace($id)) { $id = "<BLANK>" }
        if (-not $t.ContainsKey($id)) {
            $t[$id] = [pscustomobject]@{
                OwnerId = $id
                Name    = "$($it.$NameField)"
                Class   = Get-OwnerClass $id
                Count   = 0
            }
        }
        $t[$id].Count++
    }
    return $t
}

# Deliberately split compute (pure, no I/O) from log (void, all output goes through
# Write-LsqLog). A function that both calls Write-LsqLog AND returns a value hands its
# caller the log lines bundled in with the real return value - every unredirected output
# statement in a PowerShell function becomes part of what it returns, not just the last
# explicit `return`. This is the exact bug 11-audit-post-migration.ps1's own comment
# warns about ("Tally ONLY - no logging inside... which is exactly what broke the first
# run of this script") - hit here on the first live run of this script too, corrupting
# $leadOwnerResult/etc into [log-line strings..., real object] and blowing up the
# $snapshot construction downstream.
function Get-OwnerTallyReport {
    param([hashtable]$T)
    $regressions = @($T.Values | Where-Object { $_.Class -eq "DEPARTED" })
    $unknown = @($T.Values | Where-Object { $_.Class -eq "UNKNOWN" })
    return [pscustomobject]@{ Regressions = $regressions; Unknown = $unknown }
}

function Write-OwnerTallyLog {
    param([string]$Title, [hashtable]$T, [string]$LogPath, [pscustomobject]$Report)
    Write-LsqLog "" $LogPath
    Write-LsqLog "=== $Title - owner distribution ===" $LogPath
    foreach ($k in ($T.Keys | Sort-Object { -$T[$_].Count })) {
        $o = $T[$k]
        Write-LsqLog ("   {0,-28} {1,-10} {2,-6} {3}" -f $o.Name, $o.Class, $o.Count, $o.OwnerId) $LogPath
    }
    if ($Report.Regressions.Count -gt 0) {
        Write-LsqLog "   REGRESSION - owned by a departed owner:" $LogPath
        foreach ($o in $Report.Regressions) { Write-LsqLog "      $($o.Name) ($($o.OwnerId)) = $($o.Count)" $LogPath }
    }
    if ($Report.Unknown.Count -gt 0) {
        Write-LsqLog "   UNKNOWN owner (neither active nor departed reference data):" $LogPath
        foreach ($o in $Report.Unknown) { Write-LsqLog "      $($o.Name) ($($o.OwnerId)) = $($o.Count)" $LogPath }
    }
}

# -----------------------------------------------------------------------------------------
# PASS A - Leads (one full paginated scan)
# -----------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- PASS A: leads ---" $logPath

# 89,845 leads confirmed live 2026-07-31 11:00 (docs/HANDOVER_2026-07-31.md). Floor set
# below that to tolerate ordinary lead creation between then and now, not to paper over a
# truncated scan.
$MinExpectedLeads = 88000

$leadCols = "ProspectID,ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason," +
            "mx_Disqualification_Category,mx_Segment,mx_Needs_Contact_Resourcing," +
            "RelatedCompanyId,IsPrimaryContact,OwnerId,OwnerIdName"

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
if ($leads.Count -lt $MinExpectedLeads) { throw "Only $($leads.Count) leads enumerated (floor $MinExpectedLeads) - refusing to audit from an incomplete scan." }

function Get-Tally {
    param([System.Collections.Generic.List[object]]$Items, [string]$Field)
    $t = @{}
    foreach ($it in $Items) {
        $v = "$($it.$Field)"
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        if ($t.ContainsKey($v)) { $t[$v]++ } else { $t[$v] = 1 }
    }
    return $t
}
function Write-Tally {
    param([string]$Title, [hashtable]$T, [int]$Total, [string]$LogPath, [string[]]$Canonical = $null)
    $counted = 0
    foreach ($k in $T.Keys) { $counted += $T[$k] }
    Write-LsqLog "" $LogPath
    Write-LsqLog "=== $Title ===" $LogPath
    Write-LsqLog ("   (set: {0}   blank/unset: {1})" -f $counted, ($Total - $counted)) $LogPath
    $legacyTotal = 0
    foreach ($k in ($T.Keys | Sort-Object { -$T[$_] })) {
        $flag = ""
        if ($Canonical -and $Canonical -notcontains $k) { $flag = "  <-- LEGACY/NON-CANONICAL"; $legacyTotal += $T[$k] }
        Write-LsqLog ("   {0,-42} {1,-8}{2}" -f $k, $T[$k], $flag) $LogPath
    }
    if ($Canonical -and $legacyTotal -gt 0) { Write-LsqLog "   TOTAL on a legacy/non-canonical value: $legacyTotal" $LogPath }
}

$stageT      = Get-Tally $leads "ProspectStage"
$dispT       = Get-Tally $leads "mx_Call_Disposition"
$reasonT     = Get-Tally $leads "mx_Disqualification_Reason"
$categoryT   = Get-Tally $leads "mx_Disqualification_Category"
$segmentT    = Get-Tally $leads "mx_Segment"
$resourcingT = Get-Tally $leads "mx_Needs_Contact_Resourcing"

Write-Tally "CONTACT STAGE"              $stageT      $leads.Count $logPath $Script:ContactStages
Write-Tally "CALL DISPOSITION"           $dispT       $leads.Count $logPath
Write-Tally "DISQUALIFICATION REASON"    $reasonT     $leads.Count $logPath
Write-Tally "DISQUALIFICATION CATEGORY"  $categoryT   $leads.Count $logPath $Script:DisqualificationCategories
Write-Tally "SEGMENT"                    $segmentT    $leads.Count $logPath
Write-Tally "NEEDS CONTACT RESOURCING"   $resourcingT $leads.Count $logPath

$leadOwnerT = Get-OwnerTally $leads "OwnerId" "OwnerIdName"
$leadOwnerResult = Get-OwnerTallyReport $leadOwnerT
Write-OwnerTallyLog "LEADS" $leadOwnerT $logPath $leadOwnerResult

# Opportunity-audit scope: primary-contact leads at a deal stage. Test-LsqTrue, not a direct
# $true/"true" comparison - IsPrimaryContact reads as the STRING "1"/"0" (gotcha #6).
$dealLeads = @($leads | Where-Object { $_.ProspectStage -in @("Prospect", "Customer") })
$oppScope = @($dealLeads | Where-Object { Test-LsqTrue $_.IsPrimaryContact })
$nonPrimaryDeal = @($dealLeads | Where-Object { -not (Test-LsqTrue $_.IsPrimaryContact) })
Write-LsqLog "" $logPath
Write-LsqLog "=== OPPORTUNITY AUDIT SCOPE ===" $logPath
Write-LsqLog "   Leads at Prospect/Customer: $($dealLeads.Count)" $logPath
Write-LsqLog "   ...primary contact (in scope for pass D): $($oppScope.Count)" $logPath
Write-LsqLog "   ...NOT primary contact (excluded by design - account fragmentation rule): $($nonPrimaryDeal.Count)" $logPath
if (($oppScope.Count + $nonPrimaryDeal.Count) -ne $dealLeads.Count) {
    throw "Internal check failed: primary($($oppScope.Count)) + non-primary($($nonPrimaryDeal.Count)) != deal-stage total($($dealLeads.Count))."
}

# -----------------------------------------------------------------------------------------
# PASS B - Companies (one full paginated scan)
# -----------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- PASS B: companies ---" $logPath

# 71,467 companies confirmed 2026-07-22 (PROJECT_PLAN.md Phase 0), minus 2 known junk
# duplicates still pending UI deletion (docs/HANDOVER_2026-07-31.md item 5). Floor kept well
# below that - this is 9-day-old data and Company creation volume is not this audit's concern.
$MinExpectedCompanies = 65000

$companies = New-Object System.Collections.Generic.List[object]
$page = 1
$loggedFields = $false
while ($true) {
    $resp = Invoke-LsqCompanySearch -CompanyTypeName "Company" -PageIndex $page -PageSize 1000
    $rows = @(Expand-LsqRows $resp.Companies)
    if ($rows.Count -eq 0) { break }
    foreach ($c in $rows) {
        $props = @{}
        foreach ($x in $c.companyPropertyList) { $props[$x.Attribute] = $x.Value }
        if (-not $loggedFields) {
            Write-LsqLog ("  company field names seen (first record): " + (($props.Keys | Sort-Object) -join ", ")) $logPath
            $loggedFields = $true
        }
        [void]$companies.Add([pscustomobject]@{
            CompanyId = "$($props.CompanyId)"
            Stage     = "$($props.Stage)"
            OwnerId   = "$($props.OwnerId)"
            OwnerName = "$($props.OwnerName)"
        })
    }
    if ($page % 20 -eq 0) { Write-LsqLog "  companies scanned: $($companies.Count)..." $logPath }
    if ($rows.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 300
}
Write-LsqLog "Total companies scanned: $($companies.Count)" $logPath
if ($companies.Count -lt $MinExpectedCompanies) { throw "Only $($companies.Count) companies enumerated (floor $MinExpectedCompanies) - refusing to audit from an incomplete scan." }

$companyStageT = Get-Tally $companies "Stage"
Write-Tally "COMPANY STAGE" $companyStageT $companies.Count $logPath $Script:CompanyStages

$companyOwnerT = Get-OwnerTally $companies "OwnerId" "OwnerName"
$companyOwnerResult = Get-OwnerTallyReport $companyOwnerT
Write-OwnerTallyLog "COMPANIES" $companyOwnerT $logPath $companyOwnerResult

# -----------------------------------------------------------------------------------------
# PASS C - live dropdown options (selectability check, reuses pass A's tallies - no second scan)
# -----------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- PASS C: dropdown selectability (live options, not 00-schema.ps1) ---" $logPath

$meta = Invoke-RestMethod -Uri (Get-LsqUrl "LeadManagement.svc/LeadsMetaData.Get") -Method Get
$dropdownFields = [ordered]@{
    "ProspectStage"                = $stageT
    "mx_Call_Disposition"          = $dispT
    "mx_Disqualification_Reason"   = $reasonT
    "mx_Disqualification_Category" = $categoryT
    "mx_Segment"                   = $segmentT
    "mx_Needs_Contact_Resourcing"  = $resourcingT
}
$dropdownReport = [ordered]@{}
foreach ($s in $dropdownFields.Keys) {
    $f = @($meta | Where-Object { "$($_.SchemaName)" -eq $s })
    if ($f.Count -eq 0) { Write-LsqLog "WARNING: field $s not found in live schema" $logPath; continue }
    $opts = @($f[0].Options | ForEach-Object { "$($_.Value)" } | Where-Object { $_ -ne "" })
    $tally = $dropdownFields[$s]

    $orphans = @(); $orphanCount = 0
    foreach ($v in $tally.Keys) { if ($opts -notcontains $v) { $orphans += $v; $orphanCount += $tally[$v] } }
    $unused = @($opts | Where-Object { -not $tally.ContainsKey($_) })

    Write-LsqLog "" $logPath
    Write-LsqLog "=== $s  ($($opts.Count) live dropdown options) ===" $logPath
    if ($orphans.Count -gt 0) {
        Write-LsqLog ("   STORED BUT NOT IN DROPDOWN - {0} value(s), {1} leads UNFILTERABLE:" -f $orphans.Count, $orphanCount) $logPath
        foreach ($v in ($orphans | Sort-Object { -$tally[$_] })) { Write-LsqLog ("      [{0}] = {1}" -f $v, $tally[$v]) $logPath }
    } else {
        Write-LsqLog "   OK - every stored value is a live dropdown option." $logPath
    }
    if ($unused.Count -gt 0) {
        Write-LsqLog "   live options with ZERO records ($($unused.Count)):" $logPath
        foreach ($u in $unused) { Write-LsqLog "      [$u]" $logPath }
    }
    $dropdownReport[$s] = [pscustomobject]@{ LiveOptionCount = $opts.Count; Orphans = $orphans; OrphanLeadCount = $orphanCount; DeadOptions = $unused }
}

# -----------------------------------------------------------------------------------------
# PASS D - Opportunities, scoped to the primary-contact deal-stage leads from pass A
# -----------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- PASS D: opportunities (scoped, $($oppScope.Count) calls) ---" $logPath

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$oppStageT = @{}
$oppOwnerItems = New-Object System.Collections.Generic.List[object]
$missingOpp = New-Object System.Collections.Generic.List[object]
$fragmented = New-Object System.Collections.Generic.List[object]
$nonCanonicalOppStage = New-Object System.Collections.Generic.List[object]
$oppChecked = 0

foreach ($l in $oppScope) {
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$($l.ProspectID)&opportunityType=12000"
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
        $oppChecked++
        if ($r.RecordCount -eq 0) {
            [void]$missingOpp.Add($l.ProspectID)
        } else {
            if ($r.RecordCount -gt 1) { [void]$fragmented.Add($l.ProspectID) }
            # Flat properties on r.List[i] - confirmed by a live smoke test 2026-07-31, NOT a
            # nested Fields array. validate-consistency.ps1 assumes r.List[0].Fields, which
            # this smoke test showed does not exist on a real response - that script's V1/V4
            # checks are silently broken (foreach over a null array does nothing), but it has
            # never been run against production, so this is a documentation note, not a live
            # incident. Worth fixing separately.
            foreach ($o in $r.List) {
                $st = "$($o.mx_Custom_2)"
                if ([string]::IsNullOrWhiteSpace($st)) { $st = "<BLANK>" }
                if ($oppStageT.ContainsKey($st)) { $oppStageT[$st]++ } else { $oppStageT[$st] = 1 }
                if ($Script:OpportunityStageRank.Keys -notcontains $st -and $st -ne "<BLANK>") {
                    [void]$nonCanonicalOppStage.Add([pscustomobject]@{ ProspectId = $l.ProspectID; OpportunityId = $o.OpportunityId; Stage = $st })
                }
                [void]$oppOwnerItems.Add([pscustomobject]@{ OwnerId = "$($o.Owner)"; OwnerName = "$($o.OwnerName)" })
            }
        }
    } catch {
        Write-LsqLog "  opportunity check failed for $($l.ProspectID) -> $($_.Exception.Message)" $logPath
    }
    if ($oppChecked % 100 -eq 0) { Write-LsqLog "  opportunities checked: $oppChecked/$($oppScope.Count)..." $logPath }
    Start-Sleep -Milliseconds 300
}

Write-LsqLog "" $logPath
Write-LsqLog "=== OPPORTUNITY STAGE (of $oppChecked primary deal-stage leads checked) ===" $logPath
foreach ($k in ($oppStageT.Keys | Sort-Object { -$oppStageT[$_] })) { Write-LsqLog ("   {0,-24} {1}" -f $k, $oppStageT[$k]) $logPath }
Write-LsqLog "   MISSING an Opportunity entirely: $($missingOpp.Count)" $logPath
Write-LsqLog "   FRAGMENTED (more than one Opportunity): $($fragmented.Count)" $logPath
Write-LsqLog "   Non-canonical Opportunity stage value: $($nonCanonicalOppStage.Count)" $logPath
foreach ($n in $nonCanonicalOppStage) { Write-LsqLog "      lead $($n.ProspectId) opp $($n.OpportunityId) stage [$($n.Stage)]" $logPath }

$oppOwnerT = Get-OwnerTally $oppOwnerItems "OwnerId" "OwnerName"
$oppOwnerResult = Get-OwnerTallyReport $oppOwnerT
Write-OwnerTallyLog "OPPORTUNITIES" $oppOwnerT $logPath $oppOwnerResult

# Reference-point sanity check (docs/HANDOVER_2026-07-31.md: 961/961 as of 2026-07-31 11:00).
# Not an abort condition - just flagged if wildly off, since that would suggest a broken
# scope or call rather than genuine business movement in a few hours.
$totalOppsFound = ($oppStageT.Values | Measure-Object -Sum).Sum
if ($totalOppsFound -lt 500) {
    Write-LsqLog "" $logPath
    Write-LsqLog "NOTE: only $totalOppsFound opportunities found vs a same-day reference point of 961 - investigate before trusting this pass." $logPath
}

# -----------------------------------------------------------------------------------------
# Output: JSON snapshot + markdown summary
# -----------------------------------------------------------------------------------------
$snapshot = [pscustomobject]@{
    RunAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Leads = [pscustomobject]@{
        Total = $leads.Count
        ContactStage = $stageT
        CallDisposition = $dispT
        DisqualificationReason = $reasonT
        DisqualificationCategory = $categoryT
        Segment = $segmentT
        NeedsContactResourcing = $resourcingT
        OwnerRegressions = @($leadOwnerResult.Regressions)
        OwnerUnknown = @($leadOwnerResult.Unknown)
    }
    Companies = [pscustomobject]@{
        Total = $companies.Count
        Stage = $companyStageT
        OwnerRegressions = @($companyOwnerResult.Regressions)
        OwnerUnknown = @($companyOwnerResult.Unknown)
    }
    DropdownCoverage = $dropdownReport
    Opportunities = [pscustomobject]@{
        ScopeSize = $oppScope.Count
        Checked = $oppChecked
        Stage = $oppStageT
        # .ToArray(), not @(...) - wrapping a System.Collections.Generic.List[object]
        # instance directly in @() throws "Argument types do not match" on this machine's
        # PowerShell 5.1 build (5.1.26100.8875), confirmed by isolated repro 2026-07-31,
        # even with an empty or single-item list, and even with no other project files
        # dot-sourced. common.ps1's Expand-LsqRows already avoids this pattern by
        # returning $out.ToArray() rather than @($out) - follow the same convention here.
        Missing = $missingOpp.ToArray()
        Fragmented = $fragmented.ToArray()
        NonCanonicalStage = $nonCanonicalOppStage.ToArray()
        OwnerRegressions = @($oppOwnerResult.Regressions)
        OwnerUnknown = @($oppOwnerResult.Unknown)
    }
    NonPrimaryAtDealStage = $nonPrimaryDeal.Count
}
$snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath
Write-LsqLog "" $logPath
Write-LsqLog "JSON snapshot written: $jsonPath" $logPath

# --- Markdown summary, meant to be read directly -----------------------------------------
$md = New-Object System.Collections.Generic.List[string]
[void]$md.Add("# Full account audit - $stamp")
[void]$md.Add("")
[void]$md.Add("Leads scanned: $($leads.Count)   Companies scanned: $($companies.Count)   Opportunities checked: $oppChecked (of $($oppScope.Count) in scope)")
[void]$md.Add("")
[void]$md.Add("## Contact Stage")
[void]$md.Add("")
[void]$md.Add("| Value | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($stageT.Keys | Sort-Object { -$stageT[$_] })) { [void]$md.Add("| $k | $($stageT[$k]) |") }
[void]$md.Add("")
[void]$md.Add("## Company Stage")
[void]$md.Add("")
[void]$md.Add("| Value | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($companyStageT.Keys | Sort-Object { -$companyStageT[$_] })) { [void]$md.Add("| $k | $($companyStageT[$k]) |") }
[void]$md.Add("")
[void]$md.Add("## Opportunity Stage (scoped)")
[void]$md.Add("")
[void]$md.Add("| Value | Count |")
[void]$md.Add("|---|---|")
foreach ($k in ($oppStageT.Keys | Sort-Object { -$oppStageT[$_] })) { [void]$md.Add("| $k | $($oppStageT[$k]) |") }
[void]$md.Add("| MISSING | $($missingOpp.Count) |")
[void]$md.Add("| FRAGMENTED (more than 1) | $($fragmented.Count) |")
[void]$md.Add("")
[void]$md.Add("## Dropdown selectability")
[void]$md.Add("")
[void]$md.Add("| Field | Live options | Orphan values | Leads affected | Dead options |")
[void]$md.Add("|---|---|---|---|---|")
foreach ($s in $dropdownReport.Keys) {
    $d = $dropdownReport[$s]
    [void]$md.Add("| $s | $($d.LiveOptionCount) | $($d.Orphans.Count) | $($d.OrphanLeadCount) | $($d.DeadOptions.Count) |")
}
[void]$md.Add("")
[void]$md.Add("## Ownership regressions (departed owner still holding records)")
[void]$md.Add("")
if (($leadOwnerResult.Regressions.Count + $companyOwnerResult.Regressions.Count + $oppOwnerResult.Regressions.Count) -eq 0) {
    [void]$md.Add("None found.")
} else {
    [void]$md.Add("| Object | Owner | Count |")
    [void]$md.Add("|---|---|---|")
    foreach ($o in $leadOwnerResult.Regressions)    { [void]$md.Add("| Lead | $($o.Name) | $($o.Count) |") }
    foreach ($o in $companyOwnerResult.Regressions) { [void]$md.Add("| Company | $($o.Name) | $($o.Count) |") }
    foreach ($o in $oppOwnerResult.Regressions)     { [void]$md.Add("| Opportunity | $($o.Name) | $($o.Count) |") }
}
[void]$md.Add("")
[void]$md.Add("## Unknown owners (GUID not in active-rep or departed-owner reference data)")
[void]$md.Add("")
if (($leadOwnerResult.Unknown.Count + $companyOwnerResult.Unknown.Count + $oppOwnerResult.Unknown.Count) -eq 0) {
    [void]$md.Add("None found.")
} else {
    [void]$md.Add("| Object | OwnerId | Count |")
    [void]$md.Add("|---|---|---|")
    foreach ($o in $leadOwnerResult.Unknown)    { [void]$md.Add("| Lead | $($o.OwnerId) | $($o.Count) |") }
    foreach ($o in $companyOwnerResult.Unknown) { [void]$md.Add("| Company | $($o.OwnerId) | $($o.Count) |") }
    foreach ($o in $oppOwnerResult.Unknown)     { [void]$md.Add("| Opportunity | $($o.OwnerId) | $($o.Count) |") }
}
[void]$md.Add("")
[void]$md.Add("Non-primary contacts sitting at a deal stage (excluded from Opportunity scope by design): $($nonPrimaryDeal.Count)")
$md | Set-Content -Path $summaryPath
Write-LsqLog "Markdown summary written: $summaryPath" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "=== Full account audit complete ===" $logPath
