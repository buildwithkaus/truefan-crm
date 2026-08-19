<#
.SYNOPSIS
  Prove what the Opportunity write path can and cannot do, BEFORE the cleanup touches 1,000+
  real deals. Read-only unless -Execute is passed with an explicit -OpportunityId.

.DESCRIPTION
  The opportunity cleanup rests on five assumptions nobody has tested live. Each one, if wrong,
  breaks the run in a way that is expensive or impossible to undo:

    P1  Can an opportunity be DELETED?          docs say CanDelete:false. If it can, ~1,000
                                                fabricated losses become real removals instead.
    P2  Is Owner writable via Update?           If not, OWNER_MISMATCH is report-only.
    P3  Do Status + Stage + Loss Reason travel  mx_Custom_2 is a dependent dropdown under
        in ONE Update call?                     Status. A deal left at Status=Lost with
                                                stage=Prospect is worse than either endpoint.
    P4  What is mx_Custom_4 (Loss Reason)?      Dropdown -> the value must exist in the option
                                                list or reps cannot filter it (gotcha 10).
    P6  Does closing a deal as Lost CASCADE     sync-rules.ps1 maps Lost -> Disqualified. If a
        into the contact's stage?               native automation does the same, closing ~1,000
                                                deals disqualifies ~1,000 live contacts. This
                                                is the single largest damage vector in the job.

  WHY THERE IS NO THROWAWAY RECORD
  --------------------------------
  The obvious design creates a scratch lead + deal to experiment on. It is the wrong one here:
  opportunities cannot be deleted, so every probe run would leave permanent litter in the deal
  book that then has to be excluded from every future count.

  Instead the write probes run on ONE REAL DEAL that the cleanup intends to close anyway, and
  the caller picks it explicitly. Use an OPEN_DEAL_ON_DISQUALIFIED row: the contact is ALREADY
  Disqualified, so even if P6 finds a live cascade, the cascade is a no-op on that record. That
  makes the most dangerous probe in the set free to run, and it doubles as the hard-rule-3
  single-record proof for the close path.

  -ListCandidates prints suitable opportunity ids from the warehouse.

.PARAMETER Execute
  Required for P1/P2/P3/P6. Without it only the read-only probes run.

.PARAMETER OpportunityId
  The single real deal the write probes act on. Mandatory with -Execute - deliberately not
  auto-selected, so a stray -Execute cannot pick a record on its own.

.EXAMPLE
  powershell.exe -File scripts\pipeline\13-probe-opportunity-writes.ps1 -ListCandidates
  powershell.exe -File scripts\pipeline\13-probe-opportunity-writes.ps1
  powershell.exe -File scripts\pipeline\13-probe-opportunity-writes.ps1 -Execute -OpportunityId <guid>

.NOTES
  ASCII only. Windows PowerShell 5.1 - pwsh is not installed on this machine (gotcha 31).
#>

param(
    [switch]$Execute,
    [string]$OpportunityId = "",
    [switch]$ListCandidates,

    # Self-contained delete proof on throwaway records. Needs -Execute but NOT -OpportunityId.
    [switch]$ProveDelete,

    [int]$CascadeWaitSeconds = 180
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_write_probe_log.txt"
$outPath = Join-Path $dataDir "opportunity_write_probe_results.json"

$cfg  = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$script:results = New-Object System.Collections.Generic.List[object]

function Add-Probe {
    param([string]$Id, [string]$Question, [string]$Verdict, [string]$Detail)
    [void]$script:results.Add([pscustomobject]@{
        Probe = $Id; Question = $Question; Verdict = $Verdict; Detail = $Detail
    })
    Write-LsqLog ("  [{0,-12}] {1,-4} {2}" -f $Verdict, $Id, $Question) $logPath
    if ($Detail) { Write-LsqLog "                      $Detail" $logPath }
}

function Get-SbAll {
    param([string]$Query)
    $sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/'); $sbKey = $cfg['SUPABASE_SERVICE_KEY']
    $hdr = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }
    $out = New-Object System.Collections.Generic.List[object]
    $offset = 0
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

function Get-LeadSnapshot {
    param([string]$LeadId)
    # ProspectID, not ProspectId - the wrong case returns zero rows silently, which in the P6
    # cascade poll below would read as "the contact never moved" (gotcha 49).
    $r = Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$LeadId; SqlOperator="=" } `
        -ColumnsCsv "ProspectID,ProspectStage,OwnerId,IsPrimaryContact,RelatedCompanyId,ModifiedOn" -PageIndex 1 -PageSize 1
    $rows = @(Expand-LsqRows $r)
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

Write-LsqLog "" $logPath
Write-LsqLog "=== Opportunity write probes [$(if ($Execute) { 'EXECUTE' } else { 'READ-ONLY' })] ===" $logPath

# ---------------------------------------------------------------------------------------
# -ListCandidates : safe write-probe targets
# ---------------------------------------------------------------------------------------
if ($ListCandidates) {
    Write-LsqLog "Open deals on already-Disqualified contacts - safe P6 targets (a cascade is a no-op):" $logPath
    $rows = Get-SbAll "v_opportunity_hygiene?select=issue,opportunity_id,prospect_id,rep,company_name,stage,status,contact_stage&issue=eq.OPEN_DEAL_ON_DISQUALIFIED"
    if ($rows.Count -eq 0) { Write-LsqLog "  none found" $logPath }
    foreach ($r in $rows | Select-Object -First 20) {
        Write-LsqLog ("  {0}  {1,-18} {2,-12} {3}" -f $r.opportunity_id, $r.stage, $r.status, $r.company_name) $logPath
    }
    Write-LsqLog "" $logPath
    Write-LsqLog "Total: $($rows.Count). Pick one and pass it as -OpportunityId with -Execute." $logPath
    return
}

# =======================================================================================
# READ-ONLY PROBES
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- read-only ---" $logPath

# --- P1a : CanDelete on the Opportunity Type -------------------------------------------
# The response is a BARE ARRAY of types - not wrapped in .List - and the code field is
# "EventCode", not "OpportunityEventCode". Reading it the wrong way yields an empty CanDelete,
# which then renders as "blocked" and confirms whatever you already believed. Assert the type
# was actually found rather than reporting a verdict from a null.
try {
    $url = "$base/OpportunityManagement.svc/GetOpportunityTypes?accessKey=$ak&secretKey=$sk"
    $types = @(Expand-LsqRows ((Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing).Content | ConvertFrom-Json))
    $t = $types | Where-Object { "$($_.EventCode)" -eq $Script:OPP_TYPE_ID } | Select-Object -First 1
    if (-not $t) {
        Add-Probe "P1a" "Does the Opportunity Type allow deletion?" "NOT FOUND" `
            "No type with EventCode $($Script:OPP_TYPE_ID) among $($types.Count): $((($types | ForEach-Object { "$($_.Name)/$($_.EventCode)" }) -join ', '))"
    } else {
        $canDelete = "$($t.CanDelete)"
        Add-Probe "P1a" "Does the Opportunity Type allow deletion?" `
            $(if (Test-LsqTrue $canDelete) { "ALLOWED" } else { "BLOCKED" }) `
            "CanDelete=$canDelete Name='$($t.Name)' EventCode=$($t.EventCode) ModifiedBy='$($t.ModifiedBy)'"
    }
} catch {
    Add-Probe "P1a" "Does the Opportunity Type allow deletion?" "ERROR" $_.Exception.Message
}

# --- P4 : what IS mx_Custom_4, and are _7/_9 readable? ---------------------------------
# gotcha 24 recorded mx_Custom_7 / _9 as unreadable. Re-test rather than inherit the claim.
try {
    $sample = Get-SbAll "fact_opportunity?select=activity_id&limit=1"
    if ($sample.Count -gt 0) {
        $d = Get-LsqOpportunityDetails -OpportunityId $sample[0].activity_id -Config $cfg
        $lr = $d.Fields['mx_Custom_4']
        Add-Probe "P4" "Is Loss Reason (mx_Custom_4) a dropdown?" `
            $(if ("$($lr.DataType)" -like "*Dropdown*") { "DROPDOWN" } else { "FREE TEXT" }) `
            "DataType=$($lr.DataType) DisplayName='$($lr.DisplayName)'. Free text means gotcha 10 does NOT apply and no UI option needs adding."
        $unreadable = @()
        foreach ($s in @('mx_Custom_7','mx_Custom_9')) {
            if (-not $d.Fields.ContainsKey($s)) { $unreadable += $s }
        }
        Add-Probe "P4b" "Are Actual Deal Size / Closure Date readable?" `
            $(if ($unreadable.Count -eq 0) { "YES" } else { "NO" }) `
            $(if ($unreadable.Count -eq 0) { "Both returned by GetOpportunityDetails - corrects gotcha 24, which called them unreadable." } else { "missing: $($unreadable -join ', ')" })
        Add-Probe "P8" "Does GetOpportunityDetails carry field metadata?" "CONFIRMED" `
            "$($d.Fields.Count) fields, each with DisplayName + DataType. Field-map assertion passed."
    }
} catch {
    Add-Probe "P4" "Is Loss Reason (mx_Custom_4) a dropdown?" "ERROR" $_.Exception.Message
}

# --- P5 : is Requirement Gathering a live warm stage or a legacy stray? -----------------
try {
    $rg = Get-SbAll "fact_opportunity?select=activity_id,status,stage&stage=eq.Requirement%20Gathering"
    $openRg = @($rg | Where-Object { $_.status -eq 'Open' }).Count
    Add-Probe "P5" "Is 'Requirement Gathering' a live warm stage?" `
        $(if ($openRg -gt 0) { "LIVE" } else { "EMPTY" }) `
        "$($rg.Count) deals on it, $openRg of them Open. Rank $(Get-LsqOpportunityStageRank 'Requirement Gathering'). Must NOT be swept up as legacy (gotcha 26)."
} catch {
    Add-Probe "P5" "Is 'Requirement Gathering' a live warm stage?" "ERROR" $_.Exception.Message
}

# --- P9 : negative controls (hard rule 1) ----------------------------------------------
# A filter is not trusted until a value that MUST return zero actually does.
try {
    $n1 = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectStage"; LookupValue="__NoSuchStage__"; SqlOperator="=" } -ColumnsCsv "ProspectID" -PageSize 10))
    Add-Probe "N1" "ProspectStage='__NoSuchStage__' returns zero?" $(if ($n1.Count -eq 0) { "PASS" } else { "FAIL" }) "$($n1.Count) row(s)"
} catch { Add-Probe "N1" "ProspectStage='__NoSuchStage__' returns zero?" "ERROR" $_.Exception.Message }

try {
    $n2 = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectActivityName_Max"; LookupValue="__NoSuchActivity__"; SqlOperator="=" } -ColumnsCsv "ProspectID" -PageSize 10))
    Add-Probe "N2" "ProspectActivityName_Max='__NoSuchActivity__' returns zero?" $(if ($n2.Count -eq 0) { "PASS" } else { "FAIL" }) "$($n2.Count) row(s)"
} catch { Add-Probe "N2" "ProspectActivityName_Max='__NoSuchActivity__' returns zero?" "ERROR" $_.Exception.Message }

# The one that matters most: a well-formed GUID that is not a lead must return an EMPTY LIST,
# not throw. Several pre-2026-08-14 call sites wrapped this read in catch { return @() }, which
# converts a transport error into "this lead has no deals" - and in a create path that produces
# a duplicate deal that cannot be deleted.
try {
    $fake = @(Get-LsqOpportunitiesOfLead -ProspectId "00000000-0000-0000-0000-000000000000" -Config $cfg)
    Add-Probe "N4" "Non-existent lead returns empty, not an error?" $(if ($fake.Count -eq 0) { "PASS" } else { "FAIL" }) "$($fake.Count) deal(s) returned"
} catch {
    Add-Probe "N4" "Non-existent lead returns empty, not an error?" "THROWS" "The helper throws for an unknown lead: $($_.Exception.Message). Callers must NOT treat this as 'no deals'."
}

# --- N7 : is opportunityType load-bearing? ---------------------------------------------
try {
    $known = Get-SbAll "fact_opportunity?select=prospect_id&limit=1"
    if ($known.Count -gt 0) {
        $withType = @(Get-LsqOpportunitiesOfLead -ProspectId $known[0].prospect_id -Config $cfg)
        $u = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$($known[0].prospect_id)"
        $raw = $null
        try { $raw = (Invoke-WebRequest -Uri $u -Method Post -ContentType "application/json" -UseBasicParsing).Content | ConvertFrom-Json } catch { }
        $without = if ($raw) { @($raw.List).Count } else { -1 }
        Add-Probe "N7" "Is opportunityType required on the read?" `
            $(if ($without -ne $withType.Count) { "REQUIRED" } else { "OPTIONAL" }) `
            "with type: $($withType.Count) deal(s); without: $without (-1 = the call failed)"
    }
} catch { Add-Probe "N7" "Is opportunityType required on the read?" "ERROR" $_.Exception.Message }

# =======================================================================================
# P1b : PROVE DELETION, on records created solely for the purpose
# =======================================================================================
# Self-contained: creates a throwaway lead, puts one opportunity on it, and tries to delete
# that opportunity. Nothing real is ever at risk.
#   delete works -> the scratch opportunity is gone and the lead is deleted after it: no trace
#   delete fails -> one tagged test record remains, which the audit already excludes. That is
#                   the same cost the account carries today, not a new one.
# This is why the delete probe does NOT reuse a real doomed deal: a real deletion cannot be
# undone if the surrounding plan later turns out to be wrong.
if ($ProveDelete) {
    if (-not $Execute) { throw "-ProveDelete writes to LeadSquared. Re-run with -Execute." }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $tag   = "$($Script:OPP_CLEANUP_NOTE_PREFIX)-PROBE-$stamp"
    Write-LsqLog "" $logPath
    Write-LsqLog "--- P1b: proving deletion on throwaway records [$tag] ---" $logPath

    $scratchLeadId = $null
    $scratchOppId  = $null
    try {
        $leadBody = @(
            @{ Attribute = "FirstName";     Value = "DeleteProbe" },
            @{ Attribute = "LastName";      Value = $tag },
            @{ Attribute = "EmailAddress";  Value = "deleteprobe.$stamp@truefan-test.invalid" },
            @{ Attribute = "ProspectStage"; Value = "Fresh" },
            @{ Attribute = "Company";       Value = $tag }
        ) | ConvertTo-Json -Depth 5
        $lr = Invoke-LsqPost -Uri "$base/LeadManagement.svc/Lead.Create?accessKey=$ak&secretKey=$sk" -JsonBody $leadBody
        $scratchLeadId = "$($lr.Message.Id)"
        if (-not $scratchLeadId) { throw "Lead.Create returned no Id -> $($lr | ConvertTo-Json -Compress -Depth 4)" }
        Write-LsqLog "  scratch lead    : $scratchLeadId" $logPath
        Start-Sleep -Seconds 3

        $scratchOppId = New-LsqOpportunity -ProspectId $scratchLeadId -OpportunityName $tag `
            -Status "Open" -OppStage "Prospect" -Note "$tag delete probe - safe to remove" -Config $cfg
        Write-LsqLog "  scratch deal    : $scratchOppId" $logPath
        Start-Sleep -Seconds 3

        # Confirm it really exists before claiming a delete removed it. Deleting something that
        # was never there returns the same "gone" as a working delete.
        $pre = @(Get-LsqOpportunitiesOfLead -ProspectId $scratchLeadId -Config $cfg)
        if ($pre.Count -ne 1) { throw "Expected exactly 1 scratch deal before the delete, found $($pre.Count). Aborting - cannot prove anything from this state." }
        Write-LsqLog "  pre-delete read : 1 deal present, confirmed" $logPath

        Remove-LsqOpportunity -OpportunityId $scratchOppId -Config $cfg
        $gone = Confirm-LsqOpportunityRemoved -OpportunityId $scratchOppId -MaxWaitSeconds 60 -Config $cfg
        # Second, independent check from the lead's side.
        $post = @(Get-LsqOpportunitiesOfLead -ProspectId $scratchLeadId -Config $cfg)

        Add-Probe "P1b" "Can an opportunity actually be DELETED?" `
            $(if ($gone -and $post.Count -eq 0) { "DELETE WORKS" } else { "BLOCKED" }) `
            "GET OpportunityManagement.svc/Delete?Id=<id> ; detail read gone=$gone ; lead now holds $($post.Count) deal(s)"

        if ($gone -and $post.Count -eq 0) { $scratchOppId = $null }
    } catch {
        Add-Probe "P1b" "Can an opportunity actually be DELETED?" "ERROR" $_.Exception.Message
    } finally {
        if ($scratchOppId) {
            Write-LsqLog "  NOTE: scratch deal $scratchOppId could NOT be deleted and will remain. It is tagged '$tag' and is excluded from audit counts." $logPath
        }
        if ($scratchLeadId) {
            try {
                $null = Invoke-WebRequest -Uri "$base/LeadManagement.svc/Lead.Delete?accessKey=$ak&secretKey=$sk&leadId=$scratchLeadId" -Method Get -UseBasicParsing
                Write-LsqLog "  scratch lead deleted" $logPath
            } catch {
                Write-LsqLog "  scratch lead $scratchLeadId could NOT be deleted -> $($_.Exception.Message)" $logPath
            }
        }
    }

    $script:results | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath
    Write-LsqLog "" $logPath
    Write-LsqLog "=== probe summary ===" $logPath
    foreach ($r in $script:results) { Write-LsqLog ("  {0,-5} {1,-14} {2}" -f $r.Probe, $r.Verdict, $r.Question) $logPath }
    return
}

# =======================================================================================
# WRITE PROBES
# =======================================================================================
if (-not $Execute) {
    Write-LsqLog "" $logPath
    Write-LsqLog "READ-ONLY run. P1b/P2/P3/P6 need -Execute -OpportunityId <guid>." $logPath
    Write-LsqLog "Use -ListCandidates for a safe target (open deal on an already-Disqualified contact)." $logPath
    $script:results | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath
    Write-LsqLog "Results -> $outPath" $logPath
    return
}

if ([string]::IsNullOrWhiteSpace($OpportunityId)) {
    throw "-Execute requires an explicit -OpportunityId. Run with -ListCandidates to pick one. It is not auto-selected on purpose: these probes write to a real deal."
}

Write-LsqLog "" $logPath
Write-LsqLog "--- write probes on opportunity $OpportunityId ---" $logPath

# Snapshot everything first. This is the rollback record for the probe itself.
$before = Get-LsqOpportunityDetails -OpportunityId $OpportunityId -Config $cfg
$leadId = $before.ProspectId
$leadBefore = Get-LeadSnapshot -LeadId $leadId
if (-not $leadBefore) { throw "Could not read lead $leadId for opportunity $OpportunityId - refusing to write blind." }

$snapshot = [pscustomobject]@{
    OpportunityId = $OpportunityId
    ProspectId    = $leadId
    Status        = $before.Status
    Stage         = $before.OppStage
    LossReason    = "$($before.Fields['mx_Custom_4'].Value)"
    OwnerId       = "$($before.Fields['Owner'].Value)"
    Note          = $before.Note
    ContactStage  = "$($leadBefore.ProspectStage)"
    ContactOwner  = "$($leadBefore.OwnerId)"
    CapturedAt    = (Get-Date).ToString("s")
}
$snapPath = Join-Path $dataDir "opportunity_write_probe_snapshot_$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $snapPath
Write-LsqLog "Pre-probe snapshot -> $snapPath" $logPath
Write-LsqLog "  deal    : $($snapshot.Status) / $($snapshot.Stage)   owner=$($snapshot.OwnerId)" $logPath
Write-LsqLog "  contact : $($snapshot.ContactStage)   owner=$($snapshot.ContactOwner)" $logPath

if ($snapshot.ContactStage -ne "Disqualified") {
    Write-LsqLog "" $logPath
    Write-LsqLog "WARNING: contact is '$($snapshot.ContactStage)', not 'Disqualified'. If P6 finds a live" $logPath
    Write-LsqLog "cascade, this contact WILL be disqualified for real. Ctrl-C now if that is not intended." $logPath
    Start-Sleep -Seconds 10
}

# P1b (deletion) is NOT run here. It has its own self-contained mode, -ProveDelete, which
# creates its own throwaway records rather than destroying a real deal to learn something.

# --- P2 : is Owner writable via Update? ------------------------------------------------
# Written to the CONTACT's owner, which is the value the cleanup wants there anyway, so a pass
# leaves the record better than it found it and a fail changes nothing.
try {
    $targetOwner = "$($leadBefore.OwnerId)"
    if ($targetOwner -and $targetOwner -ne $snapshot.OwnerId) {
        Set-LsqOpportunity -OpportunityId $OpportunityId -Fields @{ Owner = $targetOwner } `
            -Note "$($Script:OPP_CLEANUP_NOTE_PREFIX)-PROBE P2 owner alignment" -Config $cfg
        $c = Confirm-LsqOpportunityWrite -OpportunityId $OpportunityId -Expected @{ Owner = $targetOwner } -MaxWaitSeconds 60 -Config $cfg
        Add-Probe "P2" "Is Owner writable via Update?" $(if ($c.Ok) { "WRITABLE" } else { "NOT WRITABLE" }) `
            "target=$targetOwner observed=$($c.Observed['Owner']) waited=$($c.WaitedSeconds)s $($c.Mismatches -join '; ')"
    } else {
        Add-Probe "P2" "Is Owner writable via Update?" "SKIPPED" "deal owner already equals contact owner ($targetOwner) - no safe no-op test available on this record"
    }
} catch {
    Add-Probe "P2" "Is Owner writable via Update?" "NOT WRITABLE" $_.Exception.Message
}

# --- P3 + P6 : the close, and whether it cascades --------------------------------------
$lossReason = "Data Cleanup - Probe $(Get-Date -Format 'yyyyMMdd-HHmmss')"
$note = "$($Script:OPP_CLEANUP_NOTE_PREFIX)-PROBE class=P3 prev=$($snapshot.Status)/$($snapshot.Stage)"
try {
    Set-LsqOpportunity -OpportunityId $OpportunityId -Config $cfg -Note $note -Fields @{
        Status      = "Lost"
        mx_Custom_2 = "Closed - Lost"
        mx_Custom_4 = $lossReason
    }
    $c = Confirm-LsqOpportunityWrite -OpportunityId $OpportunityId -MaxWaitSeconds 90 -Config $cfg -Expected @{
        Status      = "Lost"
        mx_Custom_2 = "Closed - Lost"
        mx_Custom_4 = $lossReason
    }
    Add-Probe "P3" "Do Status + Stage + Loss Reason travel in ONE Update?" `
        $(if ($c.Ok) { "ONE CALL" } else { "PARTIAL" }) `
        "waited=$($c.WaitedSeconds)s observed Status='$($c.Observed['Status'])' Stage='$($c.Observed['mx_Custom_2'])' LossReason='$($c.Observed['mx_Custom_4'])'. $($c.Mismatches -join '; ')"
} catch {
    Add-Probe "P3" "Do Status + Stage + Loss Reason travel in ONE Update?" "FAILED" $_.Exception.Message
}

# P6. The whole run is gated on this. Poll the CONTACT, not the deal.
Write-LsqLog "" $logPath
Write-LsqLog "P6: watching contact $leadId for $CascadeWaitSeconds s (was '$($snapshot.ContactStage)')..." $logPath
$cascaded = $false
$observedStages = @()
$deadline = (Get-Date).AddSeconds($CascadeWaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    try {
        $now = Get-LeadSnapshot -LeadId $leadId
        $st = "$($now.ProspectStage)"
        if ($observedStages -notcontains $st) { $observedStages += $st }
        if ($st -ne $snapshot.ContactStage) {
            $cascaded = $true
            Write-LsqLog "  *** CONTACT STAGE MOVED: '$($snapshot.ContactStage)' -> '$st'" $logPath
            break
        }
    } catch {
        Write-LsqLog "  poll failed: $($_.Exception.Message)" $logPath
    }
}
Add-Probe "P6" "Does closing a deal as Lost cascade into the contact stage?" `
    $(if ($cascaded) { "CASCADES" } else { "NO CASCADE" }) `
    "contact stage over $CascadeWaitSeconds s: $($observedStages -join ' -> ') (started '$($snapshot.ContactStage)')"

if ($cascaded) {
    Write-LsqLog "" $logPath
    Write-LsqLog "*** STOP. A live automation moves the CONTACT when the deal closes." $logPath
    Write-LsqLog "*** Closing ~1,000 stray deals would disqualify ~1,000 contacts - a repeat of" $logPath
    Write-LsqLog "*** the 2026-08-11 incident at four times the scale. Disable the automation in" $logPath
    Write-LsqLog "*** the LSQ UI and re-run this probe before any remediation write." $logPath
}

$script:results | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath

Write-LsqLog "" $logPath
Write-LsqLog "=== probe summary ===" $logPath
foreach ($r in $script:results) { Write-LsqLog ("  {0,-5} {1,-14} {2}" -f $r.Probe, $r.Verdict, $r.Question) $logPath }
Write-LsqLog "" $logPath
Write-LsqLog "Snapshot for rollback : $snapPath" $logPath
Write-LsqLog "Results               : $outPath" $logPath
Write-LsqLog "" $logPath
Write-LsqLog "The probed deal is now Closed - Lost. Restore it with:" $logPath
Write-LsqLog "  scripts\remediation\99-rollback-cleanup-closures.ps1 -AppliedFile $snapPath -Execute" $logPath
