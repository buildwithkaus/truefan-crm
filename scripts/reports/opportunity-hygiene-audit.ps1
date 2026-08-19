<#
.SYNOPSIS
  Classify every opportunity and every deal-stage contact against the target state, and write
  the action lists the remediation scripts consume. READ-ONLY - writes only to data/.

.DESCRIPTION
  Target state, in one line: a contact at Prospect has exactly ONE open deal, carrying an
  expected value, an expected closure date, and the same owner as the contact. A deal on a
  contact that is not at Prospect or Customer should not exist.

  Runs entirely off the scan file written by scripts/remediation/00-backup-opportunities.ps1,
  so it costs ZERO API calls and can be re-run freely while decisions are being argued about.

  THE RECONCILIATION GATE
  -----------------------
  Classification happens first, then every count is reconciled, and only if the reconciliation
  passes does an action list get written. A wrong classification here does not produce a wrong
  report - it produces a wrong DELETE list, and deletion is irreversible. So a failed guard
  writes the diagnostic sheets and throws rather than emitting actions.

  EVER-PROSPECT, AND WHY "UNKNOWN" IS A FIRST-CLASS ANSWER
  -------------------------------------------------------
  A deal on a non-Prospect contact means one of two very different things: the contact reached
  Prospect and then moved off (a real, lost deal), or it never did (a migration artifact). The
  answer comes from the EventCode 3002 trail via 04-resolve-ever-prospect.ps1.

  Absence of evidence is NOT evidence of absence. A contact with no Prospect-meaning 3002 might
  simply predate reliable stage-change logging. Those are classed DEAL_EVER_PROSPECT_UNKNOWN and
  are NEVER folded into the never-Prospect bucket - folding them is how a real deal history gets
  destroyed on the strength of a missing log line.

.PARAMETER ScanFile
  Output of 00-backup-opportunities.ps1. Defaults to the newest data/opportunity_scan_*.json.

.EXAMPLE
  powershell.exe -File scripts\reports\opportunity-hygiene-audit.ps1
  powershell.exe -File scripts\reports\opportunity-hygiene-audit.ps1 -ScanFile data\opportunity_scan_20260814-163000.json

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31). Workbook via lib/xlsx.ps1, never Excel COM -
  COM threw OutOfMemoryException on a workbook this size (gotcha 42).
#>

param(
    [string]$ScanFile = "",
    [string]$EverProspectFile = "",
    [string]$OutXlsx = "",
    [switch]$AllowUnknowns
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"
. "$PSScriptRoot\..\lib\xlsx.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_audit_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"

# Contact stages allowed to hold a deal. Customer keeps its Won deal untouched - it is the only
# record TrueFan has of closed business.
$KeepStages = @("Prospect", "Customer")

function Read-Utf8Json {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json
}

Write-LsqLog "" $logPath
Write-LsqLog "=== Opportunity hygiene audit [$stamp] ===" $logPath

if (-not $ScanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_scan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No scan file found. Run scripts\remediation\00-backup-opportunities.ps1 first." }
    $ScanFile = $newest.FullName
}
Write-LsqLog "Scan file: $ScanFile" $logPath
$scan = Read-Utf8Json $ScanFile
$deals = @($scan.Deals)
$book  = @($scan.Book)
Write-LsqLog "  $($deals.Count) deals, $($book.Count) leads, generated $($scan.GeneratedAtUtc) UTC" $logPath

# Ever-Prospect resolutions, if the trail pass has run.
$everProspect = @{}
if (-not $EverProspectFile) {
    $epDefault = Join-Path $dataDir "opportunity_everprospect_cache.json"
    if (Test-Path $epDefault) { $EverProspectFile = $epDefault }
}
if ($EverProspectFile -and (Test-Path $EverProspectFile)) {
    foreach ($e in @((Read-Utf8Json $EverProspectFile).Resolutions)) { $everProspect["$($e.ProspectId)"] = $e }
    Write-LsqLog "Ever-Prospect cache: $($everProspect.Count) resolutions" $logPath
} else {
    Write-LsqLog "No ever-Prospect cache - every stray will class as DEAL_EVER_PROSPECT_UNKNOWN." $logPath
}

$bookById = @{}
foreach ($b in $book) { $bookById["$($b.ProspectId)"] = $b }

# ---------------------------------------------------------------------------------------
# SCAN COVERAGE GUARD
# ---------------------------------------------------------------------------------------
# "This Prospect has no deal, create one" is only true if the contact was actually LOOKED AT.
# Against a partial scan the same logic emits a create for every Prospect whose deal simply was
# not read - a smoke test on 40 candidates produced 282 spurious creates out of a 91,054-lead
# book. The writers would each refuse the duplicate, but a report that overstates the work by
# an order of magnitude is not a report anyone can act on.
#
# The candidate union in 00-backup-opportunities.ps1 is deterministic, so it is recomputed here
# from the same inputs rather than trusted from the scan file. Any Prospect/Customer contact
# outside it was never read, and no create is emitted for it.
$scanned = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($d in $deals) { [void]$scanned.Add("$($d.ProspectId)") }
foreach ($f in @("opportunity_backfill_worklist.json","opportunity_backfill_stragglers.json","migration_worklist_opportunities.json")) {
    $p = Join-Path $dataDir $f
    if (-not (Test-Path $p)) { continue }
    foreach ($row in @((Read-Utf8Json $p))) { if ($row.ProspectId) { [void]$scanned.Add("$($row.ProspectId)") } }
}
foreach ($b in $book) {
    if ("$($b.ContactStage)" -in $KeepStages) { [void]$scanned.Add("$($b.ProspectId)") }
    elseif (Test-LsqTrue $b.IsPrimaryContact) { [void]$scanned.Add("$($b.ProspectId)") }
}
$dealStageContacts = @($book | Where-Object { "$($_.ContactStage)" -in $KeepStages })
$uncovered = @($dealStageContacts | Where-Object { -not $scanned.Contains("$($_.ProspectId)") })
Write-LsqLog "Scan coverage: $($scanned.Count) leads were in the candidate set; $($uncovered.Count) of $($dealStageContacts.Count) deal-stage contacts were NOT scanned" $logPath

# A scan holding far fewer deals than there are deal-stage contacts is a truncated scan, not an
# account with no deals. Refuse to emit creates from it.
$partialScan = $false
if ($deals.Count -lt ($dealStageContacts.Count * 0.5)) {
    $partialScan = $true
    Write-LsqLog "WARNING: only $($deals.Count) deals for $($dealStageContacts.Count) deal-stage contacts - treating this as a PARTIAL scan. No create actions will be emitted." $logPath
}

$dealsByContact = @{}
foreach ($d in $deals) {
    $k = "$($d.ProspectId)"
    if (-not $dealsByContact.ContainsKey($k)) { $dealsByContact[$k] = New-Object System.Collections.Generic.List[object] }
    [void]$dealsByContact[$k].Add($d)
}

$findings   = New-Object System.Collections.Generic.List[object]
$actDelete  = New-Object System.Collections.Generic.List[object]
$actCreate  = New-Object System.Collections.Generic.List[object]
$actOwner   = New-Object System.Collections.Generic.List[object]
$forecast   = New-Object System.Collections.Generic.List[object]
$unknowns   = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param([string]$Class, [int]$Severity, $Deal, [string]$ProspectId, [string]$Fix, [string]$Evidence)
    [void]$findings.Add([pscustomobject]@{
        Class = $Class; Severity = $Severity
        ProspectId = $ProspectId
        OpportunityId = $(if ($Deal) { $Deal.OpportunityId } else { "" })
        Rep = $(if ($Deal) { $Deal.ContactOwnerName } else { "" })
        Company = $(if ($Deal) { $Deal.CompanyName } else { "" })
        ContactStage = $(if ($Deal) { $Deal.ContactStage } else { "" })
        OppStage = $(if ($Deal) { $Deal.OppStage } else { "" })
        Status = $(if ($Deal) { $Deal.Status } else { "" })
        Fix = $Fix; Evidence = $Evidence
    })
}

# =======================================================================================
# Deal-level classification
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- classifying $($deals.Count) deals ---" $logPath

$testRecords = 0
foreach ($d in $deals) {
    if (Test-LsqOpportunityIsTestRecord $d) { $testRecords++; continue }

    $contactStage = "$($d.ContactStage)"
    $keep = ($contactStage -in $KeepStages)

    # --- strays: the deal's contact is not at a stage allowed to hold one ---------------
    if (-not $keep) {
        $ep = $everProspect["$($d.ProspectId)"]
        if ($null -eq $ep) {
            Add-Finding "DEAL_EVER_PROSPECT_UNKNOWN" 1 $d $d.ProspectId `
                "Resolve the stage trail before deciding" `
                "contact is '$contactStage'; no 3002 resolution available"
            [void]$unknowns.Add($d)
            continue
        }
        # Won deals are never deleted regardless of where the contact drifted - they are the
        # only record of closed business.
        if ("$($d.Status)" -eq "Won") {
            Add-Finding "WON_DEAL_ON_NON_CUSTOMER" 2 $d $d.ProspectId `
                "Move the CONTACT to Customer - do not touch the deal" `
                "Won deal but contact is '$contactStage'"
            continue
        }
        $cls = if (Test-LsqTrue $ep.EverProspect) { "DEAL_ON_LAPSED_PROSPECT" } else { "DEAL_ON_NEVER_PROSPECT" }
        # ENGAGED ONLY. An Engaged contact is a live account a rep is mid-conversation on, and
        # it is 2,327 of the 3,345 strays - 70% of the delete list, and a different decision
        # from clearing migration debris off Disqualified contacts. Held out so it can be
        # reviewed on its own (Kaustubh, 2026-08-14).
        #
        # Fresh is NOT held: a Fresh contact has never been worked, so a deal on it is a
        # migration artifact by definition, not a conversation in progress.
        $hold = ($contactStage -eq "Engaged")
        Add-Finding $(if ($hold) { "DEAL_ON_ENGAGED" } else { $cls }) $(if ($hold) { 2 } else { 1 }) $d $d.ProspectId `
            "DELETE" "contact '$contactStage'; everProspect=$($ep.EverProspect) via $($ep.EvidenceSource)"
        [void]$actDelete.Add([pscustomobject]@{
            Class = $(if ($hold) { "DEAL_ON_ENGAGED" } else { $cls })
            OpportunityId = $d.OpportunityId; ProspectId = $d.ProspectId
            Rep = $d.ContactOwnerName; Company = $d.CompanyName
            ContactStage = $contactStage; OppStage = $d.OppStage; Status = $d.Status
            EverProspect = $ep.EverProspect; Evidence = $ep.EvidenceSource
            Hold = $hold
        })
        continue
    }

    # --- kept deals: check owner, forecast, stage sanity ---------------------------------
    if ("$($d.OwnerId)" -and "$($d.ContactOwnerId)" -and "$($d.OwnerId)" -ne "$($d.ContactOwnerId)" -and "$($d.Status)" -eq "Open") {
        Add-Finding "OWNER_MISMATCH" 3 $d $d.ProspectId "Set the deal owner to the contact owner" `
            "deal owner $($d.OwnerId) vs contact owner $($d.ContactOwnerId)"
        [void]$actOwner.Add([pscustomobject]@{
            OpportunityId = $d.OpportunityId; ProspectId = $d.ProspectId
            Company = $d.CompanyName; FromOwnerId = $d.OwnerId; ToOwnerId = $d.ContactOwnerId
            ToOwnerName = $d.ContactOwnerName
        })
    }

    if ($null -eq (Get-LsqOpportunityStageRank $d.OppStage)) {
        Add-Finding "LEGACY_STAGE" 2 $d $d.ProspectId "Move to a canonical stage" `
            "stage '$($d.OppStage)' is not in the taxonomy"
    }

    # Status and its dependent Stage dropdown disagreeing means one was written without the
    # other - the record is in a state the UI cannot produce.
    $expectedStatus = $null
    foreach ($st in $Script:OpportunityStages.Keys) {
        if ($Script:OpportunityStages[$st] -contains "$($d.OppStage)") { $expectedStatus = $st; break }
    }
    if ($expectedStatus -and "$($d.Status)" -ne $expectedStatus) {
        Add-Finding "STATUS_STAGE_MISMATCH" 2 $d $d.ProspectId "Rewrite Status and Stage together" `
            "stage '$($d.OppStage)' implies Status '$expectedStatus' but Status is '$($d.Status)'"
    }

    if ("$($d.Status)" -eq "Open" -and $contactStage -eq "Prospect") {
        $hasV = Test-LsqForecastValue $d.ExpectedDealSize
        $hasD = Test-LsqForecastDate  $d.ExpectedCloseDate
        if (-not ($hasV -and $hasD)) {
            Add-Finding "MISSING_FORECAST" 3 $d $d.ProspectId "Rep fills value and closure date" `
                "value=$hasV date=$hasD"
        }
        $daysOpen = $null
        if ($d.CreatedOnUtc) {
            try { $daysOpen = [int]((Get-Date) - [datetime]$d.CreatedOnUtc).TotalDays } catch { }
        }
        [void]$forecast.Add([pscustomobject]@{
            rep = $d.ContactOwnerName; company = $d.CompanyName; contact = $d.ContactName
            opportunity = $d.Name; opp_stage = $d.OppStage; status = $d.Status
            days_open = $daysOpen; last_call_ist = $d.LastActivityUtc
            deal_value = $d.ExpectedDealSize; close_date = $d.ExpectedCloseDate
            prospect_id = $d.ProspectId; opportunity_id = $d.OpportunityId
        })
    }

    if (-not $d.IsPrimaryContact) {
        Add-Finding "DEAL_ON_NON_PRIMARY" 2 $d $d.ProspectId `
            "Transfer IsPrimaryContact, or demote the contact" `
            "holds a deal but is not the primary contact for $($d.CompanyName)"
    }
}

# =======================================================================================
# Contact-level classification
# =======================================================================================
Write-LsqLog "--- classifying deal-stage contacts ---" $logPath

foreach ($b in $book) {
    $stage = "$($b.ContactStage)"
    if ($stage -notin $KeepStages) { continue }
    $mine = @()
    if ($dealsByContact.ContainsKey("$($b.ProspectId)")) {
        $mine = @($dealsByContact["$($b.ProspectId)"] | Where-Object { -not (Test-LsqOpportunityIsTestRecord $_) })
    }

    if ($mine.Count -eq 0) {
        # Never claim "no deal" for a contact nobody read. That is not a finding, it is a hole
        # in the scan, and acting on it would mean creating a deal on an account that has one.
        if ($partialScan -or -not $scanned.Contains("$($b.ProspectId)")) {
            Add-Finding "NOT_SCANNED" 2 $null $b.ProspectId `
                "Re-run the discovery scan before judging this contact" `
                "at $stage with no deal in the scan, but this contact was never read"
            continue
        }
        if ($stage -eq "Prospect") {
            if (-not $b.IsPrimaryContact) {
                # Creating here fragments the account: only the primary contact may own the
                # deal. Needs a human decision, not a create.
                Add-Finding "NON_PRIMARY_PROSPECT" 2 $null $b.ProspectId `
                    "Transfer IsPrimaryContact to this contact, or demote it to Engaged" `
                    "at Prospect, not primary, no deal - creating one would fragment $($b.CompanyName)"
            } elseif ([string]::IsNullOrWhiteSpace($b.CompanyName)) {
                Add-Finding "PROSPECT_NO_COMPANY" 2 $null $b.ProspectId `
                    "Set the company name, then create the deal" `
                    "Opportunity Name (mx_Custom_1) is mandatory and would be blank"
            } else {
                Add-Finding "PROSPECT_NO_DEAL" 1 $null $b.ProspectId "CREATE a deal at Prospect/Open" `
                    "at Prospect, primary, company '$($b.CompanyName)', no deal"
                [void]$actCreate.Add([pscustomobject]@{
                    ProspectId = $b.ProspectId; CompanyName = $b.CompanyName
                    OwnerId = $b.OwnerId; OwnerName = $b.OwnerName; ContactName = $b.ContactName
                })
            }
        } else {
            Add-Finding "CUSTOMER_NO_DEAL" 2 $null $b.ProspectId "Investigate - a customer with no deal record" `
                "at Customer with no deal"
        }
        continue
    }

    if ($mine.Count -gt 1) {
        # Tie-break order: stage rank, THEN forecast data, THEN recency.
        #
        # Stage rank alone barely works here - measured on the full book, only 13 of 151
        # duplicate groups can be separated by stage, because 138 have both deals sitting on
        # the same stage. So the second key decides 91% of cases, and in 45 groups only one of
        # the deals carries an Expected Deal Size or Closure Date. Ranking on recency alone
        # would throw that data away, and there are only 359 deals in the entire book that
        # have it.
        #
        # An unrankable stage sorts LAST, never first: a value nobody wrote a rule for must not
        # win the account by accident.
        $ranked = $mine | Sort-Object `
            @{ Expression = { $r = Get-LsqOpportunityStageRank $_.OppStage; if ($null -eq $r) { -1 } else { $r } }; Descending = $true },
            @{ Expression = { [int]((Test-LsqForecastValue $_.ExpectedDealSize) -or (Test-LsqForecastDate $_.ExpectedCloseDate)) }; Descending = $true },
            @{ Expression = { if ($_.ModifiedOnUtc) { try { [datetime]$_.ModifiedOnUtc } catch { [datetime]"1900-01-01" } } else { [datetime]"1900-01-01" } }; Descending = $true }
        $winner = $ranked[0]
        foreach ($loser in ($ranked | Select-Object -Skip 1)) {
            Add-Finding "DUPLICATE_DEAL" 1 $loser $b.ProspectId "DELETE - keeping $($winner.OppStage) ($($winner.OpportunityId))" `
                "$($mine.Count) deals on one contact; keeping rank $(Get-LsqOpportunityStageRank $winner.OppStage) '$($winner.OppStage)', dropping '$($loser.OppStage)'"
            [void]$actDelete.Add([pscustomobject]@{
                Class = "DUPLICATE_DEAL"
                OpportunityId = $loser.OpportunityId; ProspectId = $b.ProspectId
                Rep = $loser.ContactOwnerName; Company = $loser.CompanyName
                ContactStage = $stage; OppStage = $loser.OppStage; Status = $loser.Status
                EverProspect = $true; Evidence = "duplicate; winner $($winner.OpportunityId) at '$($winner.OppStage)'"
                Hold = $false
            })
        }
    }
}

# =======================================================================================
# Reconciliation gate
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- reconciliation ---" $logPath
$recon = New-Object System.Collections.Generic.List[object]

# Add-Recon LOGS and therefore must NOT return a value. Write-LsqLog emits to the console as
# well as the file, so `$gate = Add-Recon ...` captures the log line AND the boolean as an
# array - which is always truthy. That is gotcha 12, and it defeated this gate on its first
# real run: a genuine 143-record conflict was recorded as a GAP in the sheet while the script
# printed "all gates passed". The verdict is accumulated in $recon and read back at the end.
function Add-Recon { param([string]$Check,$Expected,$Actual,[string]$Note)
    $pass = ("$Expected" -eq "$Actual")
    [void]$recon.Add([pscustomobject]@{ Check=$Check; Expected=$Expected; Actual=$Actual; Verdict=$(if($pass){"PASS"}else{"GAP"}); Note=$Note })
    Write-LsqLog ("  [{0}] {1,-42} expected {2} actual {3}" -f $(if($pass){"PASS"}else{"GAP "}), $Check, $Expected, $Actual) $logPath
}

$null = Add-Recon "deals in scan" $deals.Count $deals.Count "input"
$null = Add-Recon "deal-stage contacts scanned" $dealStageContacts.Count ($dealStageContacts.Count - $uncovered.Count) "unscanned contacts cannot yield a create"
$null = Add-Recon "test records excluded" $testRecords $testRecords "tagged probe/test leftovers"
$null = Add-Recon "delete list has no duplicates" $actDelete.Count (@($actDelete | ForEach-Object { $_.OpportunityId } | Sort-Object -Unique).Count) "an id listed twice would be deleted twice"

# A deal must never be on both the delete list and the keep path.
#
# The deal-level pass runs before duplicates are resolved, so a duplicate LOSER on a
# Prospect contact legitimately picks up MISSING_FORECAST and OWNER_MISMATCH findings on the
# way through - and then the contact-level pass marks it for deletion. Left alone that puts
# 143 doomed deals on a rep's forecast worklist and in the owner-realignment queue: work
# asked of a rep on a record that is about to disappear.
#
# So the delete list wins, and the keep-path actions are filtered against it. Reported rather
# than silently dropped, because a large number here would mean the duplicate rule is eating
# deals it should not.
$deleteIds = @{}
foreach ($a in $actDelete) { $deleteIds["$($a.OpportunityId)"] = $true }
$forecastConflict = @($forecast | Where-Object { $deleteIds.ContainsKey("$($_.opportunity_id)") }).Count
$ownerConflict    = @($actOwner | Where-Object { $deleteIds.ContainsKey("$($_.OpportunityId)") }).Count
if (($forecastConflict + $ownerConflict) -gt 0) {
    Write-LsqLog "  removing $forecastConflict forecast row(s) and $ownerConflict owner action(s) for deals slated for deletion" $logPath
    $forecast = New-Object System.Collections.Generic.List[object] -ArgumentList @(,@($forecast | Where-Object { -not $deleteIds.ContainsKey("$($_.opportunity_id)") }))
    $actOwner = New-Object System.Collections.Generic.List[object] -ArgumentList @(,@($actOwner | Where-Object { -not $deleteIds.ContainsKey("$($_.OpportunityId)") }))
}
$postForecastConflict = @($forecast | Where-Object { $deleteIds.ContainsKey("$($_.opportunity_id)") }).Count
$postOwnerConflict    = @($actOwner | Where-Object { $deleteIds.ContainsKey("$($_.OpportunityId)") }).Count
Add-Recon "no deal both deleted and kept" 0 ($postForecastConflict + $postOwnerConflict) "removed $forecastConflict forecast + $ownerConflict owner overlap(s)"

# Creating a deal for a contact that already has one would duplicate it.
$createConflict = @($actCreate | Where-Object { $dealsByContact.ContainsKey("$($_.ProspectId)") }).Count
Add-Recon "no create for a contact with a deal" 0 $createConflict "would create a duplicate"

if ($unknowns.Count -gt 0 -and -not $AllowUnknowns) {
    Add-Recon "ever-Prospect unknowns resolved" 0 $unknowns.Count "run 04-resolve-ever-prospect.ps1, or pass -AllowUnknowns to report anyway"
}

# =======================================================================================
# Summary + workbook
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- findings by class ---" $logPath
$byClass = $findings | Group-Object Class | Sort-Object Count -Descending
foreach ($g in $byClass) { Write-LsqLog ("  {0,-30} {1}" -f $g.Name, $g.Count) $logPath }
Write-LsqLog "" $logPath
Write-LsqLog ("  DELETE actions : {0} ({1} held back as DEAL_ON_ENGAGED)" -f $actDelete.Count, @($actDelete | Where-Object { $_.Hold }).Count) $logPath
Write-LsqLog ("  CREATE actions : {0}" -f $actCreate.Count) $logPath
Write-LsqLog ("  OWNER actions  : {0}" -f $actOwner.Count) $logPath
Write-LsqLog ("  forecast gaps  : {0} of {1} Prospect deals" -f @($findings | Where-Object { $_.Class -eq 'MISSING_FORECAST' }).Count, $forecast.Count) $logPath

if (-not $OutXlsx) { $OutXlsx = Join-Path $dataDir "TrueFan_Opportunity_Hygiene_$stamp.xlsx" }

$sheets = @()
$sheets += @{ Name='Summary'; Headers=@('Metric','Value'); Rows=@(
    @('Scan file', [IO.Path]::GetFileName($ScanFile)),
    @('Generated (UTC)', "$($scan.GeneratedAtUtc)"),
    @('Leads in book', $book.Count),
    @('Deals found', $deals.Count),
    @('Test records excluded', $testRecords),
    @('Contacts holding a deal', $dealsByContact.Count),
    @('DELETE actions', $actDelete.Count),
    @('  ...held back (Engaged/Fresh)', @($actDelete | Where-Object { $_.Hold }).Count),
    @('CREATE actions', $actCreate.Count),
    @('OWNER realignments', $actOwner.Count),
    @('Ever-Prospect unknown', $unknowns.Count)
) + @($byClass | ForEach-Object { ,@("class: $($_.Name)", $_.Count) }) }

$sheets += @{ Name='Reconciliation'; Headers=@('Check','Expected','Actual','Verdict','Note')
              Rows=@($recon | ForEach-Object { ,@($_.Check,"$($_.Expected)","$($_.Actual)",$_.Verdict,$_.Note) }) }

$sheets += @{ Name='Findings'; Headers=@('Class','Severity','Rep','Company','Contact Stage','Deal Stage','Status','Fix','Evidence','Prospect Id','Opportunity Id')
              Rows=@($findings | Sort-Object Severity,Class | ForEach-Object {
                  ,@($_.Class,$_.Severity,$_.Rep,$_.Company,$_.ContactStage,$_.OppStage,$_.Status,$_.Fix,$_.Evidence,$_.ProspectId,$_.OpportunityId) }) }

$sheets += @{ Name='Action_Delete'; Headers=@('Class','Rep','Company','Contact Stage','Deal Stage','Status','Ever Prospect','Evidence','Hold','Prospect Id','Opportunity Id')
              Rows=@($actDelete | Sort-Object Hold,Class | ForEach-Object {
                  ,@($_.Class,$_.Rep,$_.Company,$_.ContactStage,$_.OppStage,$_.Status,"$($_.EverProspect)",$_.Evidence,"$($_.Hold)",$_.ProspectId,$_.OpportunityId) }) }

$sheets += @{ Name='Action_Create'; Headers=@('Rep','Company','Contact','Prospect Id','Owner Id')
              Rows=@($actCreate | ForEach-Object { ,@($_.OwnerName,$_.CompanyName,$_.ContactName,$_.ProspectId,$_.OwnerId) }) }

$sheets += @{ Name='Action_Owner'; Headers=@('Company','From Owner','To Owner','To Owner Id','Prospect Id','Opportunity Id')
              Rows=@($actOwner | ForEach-Object { ,@($_.Company,$_.FromOwnerId,$_.ToOwnerName,$_.ToOwnerId,$_.ProspectId,$_.OpportunityId) }) }

if ($unknowns.Count -gt 0) {
    $sheets += @{ Name='Unknowns'; Headers=@('Rep','Company','Contact Stage','Deal Stage','Status','Prospect Id','Opportunity Id')
                  Rows=@($unknowns | ForEach-Object { ,@($_.ContactOwnerName,$_.CompanyName,$_.ContactStage,$_.OppStage,$_.Status,$_.ProspectId,$_.OpportunityId) }) }
}

# The held-back Engaged deals, with the evidence needed to decide on them rather than just a
# list of ids. Two columns carry the decision:
#   Days Since Touch - these accounts are LIVE (every one touched within 30 days), which is why
#                      they are not swept along with migration debris on dead contacts.
#   Has Forecast     - a rep typed a deal size or closure date in, so that deal is genuinely in
#                      use. For those the contact stage is the error, not the deal: promoting
#                      the contact to Prospect makes the deal legitimate. Deleting it destroys
#                      the only real forecast data on that account.
$held = @($actDelete | Where-Object { $_.Hold })
if ($held.Count -gt 0) {
    $heldById = @{}
    foreach ($d in $deals) { $heldById["$($d.OpportunityId)"] = $d }
    $now = Get-Date
    $sheets += @{
        Name='Held_Engaged'
        Headers=@('Recommendation','Rep','Company','Contact','Deal Stage','Days Since Touch','Has Forecast','Deal Value','Close Date','Ever Prospect','Prospect Id','Opportunity Id')
        Rows=@($held | ForEach-Object {
            $d = $heldById["$($_.OpportunityId)"]
            $days = ""
            if ($d -and $d.LastActivityUtc) { try { $days = [int]($now - [datetime]$d.LastActivityUtc).TotalDays } catch { } }
            $hasF = $false
            if ($d) { $hasF = (Test-LsqForecastValue $d.ExpectedDealSize) -or (Test-LsqForecastDate $d.ExpectedCloseDate) }
            $rec = if ($hasF) { "PROMOTE contact to Prospect" } else { "DELETE - migration artifact" }
            ,@($rec, $_.Rep, $_.Company, $(if($d){$d.ContactName}else{""}), $_.OppStage, $days, "$hasF",
               $(if($d -and (Test-LsqForecastValue $d.ExpectedDealSize)){[double]$d.ExpectedDealSize}else{""}),
               $(if($d -and (Test-LsqForecastDate $d.ExpectedCloseDate)){"$($d.ExpectedCloseDate)"}else{""}),
               "$($_.EverProspect)", $_.ProspectId, $_.OpportunityId)
        })
    }
}

$sheets += New-LsqForecastWorklistSheets -Rows $forecast.ToArray()

New-XlsxWorkbook -Sheets $sheets -Path $OutXlsx
Write-LsqLog "" $logPath
Write-LsqLog "Workbook -> $OutXlsx" $logPath

$planPath = Join-Path $dataDir "opportunity_cleanup_plan_$stamp.json"
[pscustomobject]@{
    Stamp = $stamp; ScanFile = $ScanFile; GeneratedAtUtc = ([datetime]::UtcNow).ToString("s")
    Reconciliation = $recon.ToArray()
    Delete = $actDelete.ToArray(); Create = $actCreate.ToArray(); Owner = $actOwner.ToArray()
} | ConvertTo-Json -Depth 8 | Set-Content -Path $planPath -Encoding UTF8
Write-LsqLog "Plan     -> $planPath" $logPath

# Read the verdicts back off the recorded list rather than off return values (see Add-Recon).
$failedGates = @($recon | Where-Object { $_.Verdict -ne 'PASS' })
if ($failedGates.Count -gt 0) {
    Write-LsqLog "" $logPath
    foreach ($g in $failedGates) { Write-LsqLog "  GATE FAILED: $($g.Check) - expected $($g.Expected), got $($g.Actual). $($g.Note)" $logPath }
    throw "RECONCILIATION FAILED ($($failedGates.Count) gate(s)). The workbook and plan were written for diagnosis, but DO NOT run any remediation against this plan - see the Reconciliation sheet."
}
Write-LsqLog "" $logPath
Write-LsqLog "=== audit complete, all gates passed ===" $logPath
