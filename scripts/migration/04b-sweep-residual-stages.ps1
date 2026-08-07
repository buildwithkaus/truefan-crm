<#
.SYNOPSIS
  Finds every Lead still sitting on a LEGACY ProspectStage value and migrates it. Run after
  04-migrate-leads.ps1, and re-run until it reports zero residue.

.DESCRIPTION
  04-migrate-leads.ps1 works from a worklist snapshot, so on its own it cannot reach zero:

    * 72 ProspectIds appear twice in the worklist (page-boundary overlap during enumeration).
      LeadSquared rejects a batch containing the same lead twice - "2 Duplicate Lead(s)
      provided" - so both copies fail and the lead is left behind. This script dedupes.
    * Leads created AFTER the worklist was built still land on the OLD default stage, because
      the legacy dropdown values are deliberately kept alive until the migration is verified.
      The account is live, so this set grows continuously while the migration runs.
    * Any transient write failure during the main run.

  This script works from LIVE state rather than a snapshot: it enumerates every lead, keeps the
  ones whose stage is not one of the five canonical values, maps them through $StageMap, and
  writes them. That makes it idempotent and safe to run repeatedly - each pass shrinks the
  residue, and a pass that reports zero is proof the migration is clean at that moment.

  ABORTS rather than guesses if a live stage value has no mapping (CLAUDE.md: an unmapped value
  must halt the migration, never be silently skipped).

.PARAMETER Execute
  Required to write. Without it, reports the residue and what it would do.

.NOTES
  pwsh ./scripts/leadsquared/migration/04b-sweep-residual-stages.ps1            # report only
  pwsh ./scripts/leadsquared/migration/04b-sweep-residual-stages.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_leads_sweep_log.txt"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Residual lead stage sweep [$mode] ===" $logPath

# ---------------------------------------------------------------------------------------
# Enumerate LIVE state (not the worklist snapshot).
# ---------------------------------------------------------------------------------------
$MinExpectedLeads = 80000
$all = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,ProspectStage,ProspectActivityDate_Max" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$all.Add($l) }
    if ($page % 20 -eq 0) { Write-LsqLog "  scanned $($all.Count) leads..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Total leads enumerated: $($all.Count)" $logPath
if ($all.Count -lt $MinExpectedLeads) {
    throw "Only $($all.Count) leads enumerated, expected ~86,900. Refusing to judge residue from an incomplete scan - a short read would report a falsely clean account."
}

# ---------------------------------------------------------------------------------------
# Anything not on one of the five canonical values is residue.
# ---------------------------------------------------------------------------------------
$canonical = @{}
foreach ($s in $Script:ContactStages) { $canonical[$s] = $true }

$residueCounts = @{}
$residue = New-Object System.Collections.Generic.List[object]
$blank = 0
foreach ($l in $all) {
    $s = "$($l.ProspectStage)"
    if ([string]::IsNullOrWhiteSpace($s)) { $blank++; $s = "<BLANK>" }
    if ($canonical.ContainsKey($s)) { continue }
    if ($residueCounts.ContainsKey($s)) { $residueCounts[$s]++ } else { $residueCounts[$s] = 1 }
    [void]$residue.Add($l)
}

Write-LsqLog "Leads already on a canonical stage: $($all.Count - $residue.Count)" $logPath
Write-LsqLog "RESIDUE (still on a legacy value) : $($residue.Count)" $logPath
foreach ($k in ($residueCounts.Keys | Sort-Object { -$residueCounts[$_] })) {
    Write-LsqLog ("   [{0}] = {1}" -f $k, $residueCounts[$k]) $logPath
}
if ($blank -gt 0) { Write-LsqLog "   (of which BLANK stage: $blank)" $logPath }

if ($residue.Count -eq 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "CLEAN - every lead is on a canonical contact stage." $logPath
    Write-LsqLog "=== Sweep complete [$mode] ===" $logPath
    return
}

# Every live value must have a mapping, or stop. Never guess.
$unmapped = @()
foreach ($k in $residueCounts.Keys) {
    if ($k -eq "<BLANK>") { continue }
    if (-not $Script:StageMap.ContainsKey($k)) { $unmapped += $k }
}
if ($unmapped.Count -gt 0) {
    foreach ($u in $unmapped) { Write-LsqLog "   UNMAPPED -> [$u] ($($residueCounts[$u]) leads)" $logPath }
    throw "$($unmapped.Count) live stage value(s) have no mapping in 00-schema.ps1. Add them and re-run - refusing to migrate a partial set."
}

# ---------------------------------------------------------------------------------------
# Resolve targets, deduping by ProspectId (the duplicate-batch bug that stranded leads in 04).
# ---------------------------------------------------------------------------------------
$seen = @{}
$work = New-Object System.Collections.Generic.List[object]
foreach ($l in $residue) {
    $id = "$($l.ProspectID)"
    if ([string]::IsNullOrWhiteSpace($id) -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true

    $old = "$($l.ProspectStage)"
    if ([string]::IsNullOrWhiteSpace($old)) {
        # A blank stage cannot be mapped; treat as Fresh (never contacted) - the same rule the
        # forward-going model uses for a lead with no activity.
        [void]$work.Add([pscustomobject]@{ ProspectId = $id; NewContactStage = "Fresh" })
        continue
    }
    $m = $Script:StageMap[$old]
    $contact = $null
    if ($m.Infer) {
        if (-not [string]::IsNullOrWhiteSpace($l.ProspectActivityDate_Max)) { $contact = "Engaged" } else { $contact = "Fresh" }
    } else {
        $contact = $m.Contact
    }
    [void]$work.Add([pscustomobject]@{
        ProspectId      = $id
        NewContactStage = $contact
        Reason          = $m.Reason
        Category        = $m.Category
        Disposition     = $m.Disposition
        Segment         = $m.Segment
        NeedsContactResourcing = [bool]$m.NeedsContactResourcing
    })
}
Write-LsqLog "Unique leads to fix: $($work.Count)" $logPath

if (-not $Execute) {
    $dist = $work | Group-Object NewContactStage | Sort-Object Count -Descending
    foreach ($g in $dist) { Write-LsqLog ("   would set {0,-14} {1}" -f $g.Name, $g.Count) $logPath }
    Write-LsqLog "REPORT ONLY - nothing written. Re-run with -Execute." $logPath
    return
}

function ConvertTo-JsonScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return ($Value | ConvertTo-Json)
}

$url = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
$batches = [Math]::Ceiling($work.Count / $BatchSize)
$okCount = 0; $failCount = 0
Write-LsqLog "Writing $($work.Count) leads in $batches batches of $BatchSize" $logPath

for ($b = 0; $b -lt $batches; $b++) {
    $slice = @($work[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $work.Count - 1))])
    $recJson = foreach ($row in $slice) {
        $fields = New-Object System.Collections.Generic.List[string]
        [void]$fields.Add('{"Attribute":"ProspectId","Value":'    + (ConvertTo-JsonScalar "$($row.ProspectId)") + '}')
        [void]$fields.Add('{"Attribute":"ProspectStage","Value":' + (ConvertTo-JsonScalar "$($row.NewContactStage)") + '}')
        if ($row.Reason)      { [void]$fields.Add('{"Attribute":"mx_Disqualification_Reason","Value":'   + (ConvertTo-JsonScalar "$($row.Reason)") + '}') }
        if ($row.Category)    { [void]$fields.Add('{"Attribute":"mx_Disqualification_Category","Value":' + (ConvertTo-JsonScalar "$($row.Category)") + '}') }
        if ($row.Disposition) { [void]$fields.Add('{"Attribute":"mx_Call_Disposition","Value":'          + (ConvertTo-JsonScalar "$($row.Disposition)") + '}') }
        if ($row.Segment)     { [void]$fields.Add('{"Attribute":"mx_Segment","Value":'                   + (ConvertTo-JsonScalar "$($row.Segment)") + '}') }
        if ($row.NeedsContactResourcing) { [void]$fields.Add('{"Attribute":"mx_Needs_Contact_Resourcing","Value":"Yes"}') }
        '{"Fields":[' + ($fields -join ',') + ']}'
    }
    $body = '{"SearchByKey":"ProspectId","Options":{"PushNonExistentLeadsToUnProcessedList":true},' +
            '"LeadPropertiesList":[' + (@($recJson) -join ',') + ']}'
    try {
        $r = Invoke-LsqPost -Uri $url -JsonBody $body
        $okCount   += [int]$r.Status.SuccessCount
        $failCount += [int]$r.Status.FailureCount
        if ([int]$r.Status.FailureCount -gt 0) {
            Write-LsqLog "Batch $b : $($r.Status.FailureCount) failure(s) -> $($r | ConvertTo-Json -Compress -Depth 4)" $logPath
        }
    } catch {
        $failCount += $slice.Count
        Write-LsqLog "Batch $b EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }
    if ($b % 20 -eq 0) { Write-LsqLog "Progress: batch $b/$batches ok=$okCount fail=$failCount" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Sweep DONE. ok=$okCount fail=$failCount of $($work.Count)." $logPath
Write-LsqLog "Re-run this script (report mode) to confirm the residue is now zero." $logPath
Write-LsqLog "=== Sweep complete [$mode] ===" $logPath
