<#
.SYNOPSIS
  Post-migration contact reconciliation. Brings every Lead to the locked model: canonical
  lifecycle stage, canonical Call Disposition, disqualification reason/category, segment.

.DESCRIPTION
  Reps were told to keep working the old way until per-call outcome logging exists, so two
  things drift daily:

    1. Contacts get pushed BACK to a legacy ProspectStage value. That legacy value encodes a
       call outcome, so it is translated: stage -> the mapped lifecycle stage, and the outcome
       it carried -> Call Disposition (plus reason/category/segment where the mapping defines
       them). Nothing is lost - the legacy value's meaning moves into the field built for it.

    2. Call Disposition gets set from the OLD dropdown options, because the canonical values
       were never added to that dropdown. The field now holds two vocabularies for the same
       outcomes ("Didn't Picked" alongside "Did Not Pick"). Those are normalised to the
       canonical name.

  The legacy-disposition -> canonical-disposition map is DERIVED from $StageMap, not typed out:
  each legacy dropdown option shares its name with a legacy stage value, and that stage value's
  mapping already names the canonical disposition. So there is exactly one place the naming is
  defined (00-schema.ps1) and no chance of the two drifting apart.

  Precedence rule where both signals exist: an explicit CANONICAL disposition already on the
  record WINS over one derived from a reverted stage. The rep chose that deliberately; a stage
  revert is habit. A legacy or empty disposition is overwritten.

  Works from the snapshot 11-audit-post-migration.ps1 writes, so it does not re-enumerate.

.PARAMETER Execute
  Required to write. Without it, reports exactly what it would change.

.NOTES
  pwsh ./scripts/leadsquared/migration/11-audit-post-migration.ps1     # refresh the snapshot
  pwsh ./scripts/leadsquared/migration/12-reconcile-contacts.ps1
  pwsh ./scripts/leadsquared/migration/12-reconcile-contacts.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_reconcile_log.txt"
$snapPath = Join-Path $dataDir "migration_audit_state.json"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Contact reconciliation [$mode] ===" $logPath

if (-not (Test-Path $snapPath)) { throw "Snapshot missing: $snapPath - run 11-audit-post-migration.ps1 first." }
$snap = @(Expand-LsqRows (Get-Content $snapPath -Raw | ConvertFrom-Json))
Write-LsqLog "Snapshot leads: $($snap.Count)" $logPath
if ($snap.Count -lt 80000) { throw "Snapshot has only $($snap.Count) leads - refusing to reconcile from a truncated snapshot." }

# --- canonical sets, all derived from 00-schema.ps1 -------------------------------------
$canonicalStage = @{}
foreach ($s in $Script:ContactStages) { $canonicalStage[$s] = $true }

# legacy disposition option -> canonical disposition, derived from $StageMap
$dispFix = @{}
$canonicalDisp = @{}
foreach ($k in $Script:StageMap.Keys) {
    $d = $Script:StageMap[$k].Disposition
    if ($d) {
        $canonicalDisp[$d] = $true
        if ($k -ne $d) { $dispFix[$k] = $d }   # the legacy option name differs from the canonical one
    }
}
Write-LsqLog "Canonical dispositions: $(($canonicalDisp.Keys | Sort-Object) -join ' | ')" $logPath
Write-LsqLog "Legacy disposition names that will be normalised:" $logPath
foreach ($k in ($dispFix.Keys | Sort-Object)) { Write-LsqLog ("   [{0}] -> [{1}]" -f $k, $dispFix[$k]) $logPath }

# Same idea for the disqualification reason. The Phase 5 backfill (2026-07-27) wrote reasons
# using the LEGACY stage names ("Low Budget", "Not Active After First Conversation"), which the
# migration never normalised because it only ever filled EMPTY fields. Those values are not in
# the L2 taxonomy, so a rep filtering by the real reason will not find them.
$reasonFix = @{}
$canonicalReason = @{}
foreach ($k in $Script:StageMap.Keys) {
    $r = $Script:StageMap[$k].Reason
    if ($r) {
        $canonicalReason[$r] = $true
        if ($k -ne $r) { $reasonFix[$k] = $r }
    }
}
Write-LsqLog "Legacy reason names that will be normalised:" $logPath
foreach ($k in ($reasonFix.Keys | Sort-Object)) { Write-LsqLog ("   [{0}] -> [{1}]" -f $k, $reasonFix[$k]) $logPath }

# --- build the change set ---------------------------------------------------------------
$work = New-Object System.Collections.Generic.List[object]
$stat = @{ StageFixed = 0; DispFromStage = 0; DispNormalised = 0; ReasonFilled = 0; CategoryFilled = 0; SegmentFilled = 0; DispKeptRepValue = 0; Unmapped = 0; ReasonNormalised = 0 }
$unmappedVals = @{}

foreach ($l in $snap) {
    $id = "$($l.ProspectId)"
    if (-not $id) { continue }
    $stage = "$($l.Stage)"
    $disp  = "$($l.Disposition)"
    $fields = @{}

    # ---- 1. legacy stage -> canonical lifecycle stage (+ what that value encoded) ----
    if ($stage -and -not $canonicalStage.ContainsKey($stage)) {
        if (-not $Script:StageMap.ContainsKey($stage)) {
            $stat.Unmapped++
            if (-not $unmappedVals.ContainsKey($stage)) { $unmappedVals[$stage] = 0 }
            $unmappedVals[$stage]++
            continue
        }
        $m = $Script:StageMap[$stage]
        $target = $null
        if ($m.Infer) {
            $target = if (-not [string]::IsNullOrWhiteSpace("$($l.LastActivity)")) { "Engaged" } else { "Fresh" }
        } else {
            $target = $m.Contact
        }
        $fields["ProspectStage"] = $target
        $stat.StageFixed++

        # The outcome the legacy stage carried belongs in Call Disposition - unless the rep has
        # already set a canonical one, which is the more deliberate signal.
        if ($m.Disposition) {
            if ($disp -and $canonicalDisp.ContainsKey($disp) -and $disp -ne $m.Disposition) {
                $stat.DispKeptRepValue++
            } else {
                $fields["mx_Call_Disposition"] = $m.Disposition
                $stat.DispFromStage++
            }
        }
        if ($m.Reason   -and [string]::IsNullOrWhiteSpace("$($l.Reason)"))   { $fields["mx_Disqualification_Reason"]   = $m.Reason;   $stat.ReasonFilled++ }
        if ($m.Category -and [string]::IsNullOrWhiteSpace("$($l.Category)")) { $fields["mx_Disqualification_Category"] = $m.Category; $stat.CategoryFilled++ }
        if ($m.Segment  -and [string]::IsNullOrWhiteSpace("$($l.Segment)"))  { $fields["mx_Segment"]                   = $m.Segment;  $stat.SegmentFilled++ }
        if ($m.NeedsContactResourcing) { $fields["mx_Needs_Contact_Resourcing"] = "Yes" }
    }
    # ---- 2. legacy disposition vocabulary -> canonical ----
    elseif ($disp -and $dispFix.ContainsKey($disp)) {
        $fields["mx_Call_Disposition"] = $dispFix[$disp]
        $stat.DispNormalised++
    }

    # ---- 2b. legacy reason vocabulary -> canonical L2 taxonomy value ----
    $curReason = "$($l.Reason)"
    if ($curReason -and $reasonFix.ContainsKey($curReason) -and -not $fields.ContainsKey("mx_Disqualification_Reason")) {
        $fields["mx_Disqualification_Reason"] = $reasonFix[$curReason]
        $stat.ReasonNormalised++
        # Keep the L1 category consistent with the reason we just corrected.
        $srcKey = $curReason
        if ($Script:StageMap.ContainsKey($srcKey) -and $Script:StageMap[$srcKey].Category -and -not $fields.ContainsKey("mx_Disqualification_Category")) {
            $fields["mx_Disqualification_Category"] = $Script:StageMap[$srcKey].Category
        }
    }

    # ---- 3. reason/category implied by the pre-migration stage but still empty ----
    $prev = "$($l.PreviousStage)"
    if ($prev -and $Script:StageMap.ContainsKey($prev)) {
        $pm = $Script:StageMap[$prev]
        if ($pm.Reason   -and [string]::IsNullOrWhiteSpace("$($l.Reason)")   -and -not $fields.ContainsKey("mx_Disqualification_Reason"))   { $fields["mx_Disqualification_Reason"]   = $pm.Reason;   $stat.ReasonFilled++ }
        if ($pm.Category -and [string]::IsNullOrWhiteSpace("$($l.Category)") -and -not $fields.ContainsKey("mx_Disqualification_Category")) { $fields["mx_Disqualification_Category"] = $pm.Category; $stat.CategoryFilled++ }
        if ($pm.Segment  -and [string]::IsNullOrWhiteSpace("$($l.Segment)")  -and -not $fields.ContainsKey("mx_Segment"))                   { $fields["mx_Segment"]                   = $pm.Segment;  $stat.SegmentFilled++ }
    }

    if ($fields.Count -gt 0) { [void]$work.Add([pscustomobject]@{ ProspectId = $id; Fields = $fields }) }
}

Write-LsqLog "" $logPath
Write-LsqLog "=== CHANGE SET ===" $logPath
foreach ($k in ($stat.Keys | Sort-Object)) { Write-LsqLog ("   {0,-18} {1}" -f $k, $stat[$k]) $logPath }
Write-LsqLog ("   leads to write   : {0}" -f $work.Count) $logPath
if ($unmappedVals.Count -gt 0) {
    Write-LsqLog "   UNMAPPED stage values (left untouched, need a decision):" $logPath
    foreach ($k in $unmappedVals.Keys) { Write-LsqLog ("      [{0}] {1}" -f $k, $unmappedVals[$k]) $logPath }
}

if ($work.Count -eq 0) { Write-LsqLog "Nothing to reconcile." $logPath; return }
if (-not $Execute) { Write-LsqLog "REPORT ONLY - nothing written. Re-run with -Execute." $logPath; return }

function ConvertTo-JsonScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return ($Value | ConvertTo-Json)
}

$url = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
$batches = [Math]::Ceiling($work.Count / $BatchSize)
$okCount = 0; $failCount = 0
Write-LsqLog "Writing $($work.Count) leads in $batches batches (~$([Math]::Round(($batches*$ThrottleMs)/60000,0)) min)" $logPath

for ($b = 0; $b -lt $batches; $b++) {
    $slice = @($work[($b * $BatchSize)..([Math]::Min(($b + 1) * $BatchSize - 1, $work.Count - 1))])
    $recJson = foreach ($row in $slice) {
        $f = New-Object System.Collections.Generic.List[string]
        [void]$f.Add('{"Attribute":"ProspectId","Value":' + (ConvertTo-JsonScalar "$($row.ProspectId)") + '}')
        foreach ($k in $row.Fields.Keys) {
            [void]$f.Add('{"Attribute":"' + $k + '","Value":' + (ConvertTo-JsonScalar "$($row.Fields[$k])") + '}')
        }
        '{"Fields":[' + ($f -join ',') + ']}'
    }
    $body = '{"SearchByKey":"ProspectId","Options":{"PushNonExistentLeadsToUnProcessedList":true},' +
            '"LeadPropertiesList":[' + (@($recJson) -join ',') + ']}'
    try {
        $r = Invoke-LsqPost -Uri $url -JsonBody $body
        $okCount   += [int]$r.Status.SuccessCount
        $failCount += [int]$r.Status.FailureCount
        if ([int]$r.Status.FailureCount -gt 0) { Write-LsqLog "Batch $b : $($r.Status.FailureCount) failure(s) -> $($r | ConvertTo-Json -Compress -Depth 4)" $logPath }
    } catch {
        $failCount += $slice.Count
        Write-LsqLog "Batch $b EXCEPTION -> $($_.Exception.Message)" $logPath
    }
    if ($b % 20 -eq 0) { Write-LsqLog "Progress: batch $b/$batches ok=$okCount fail=$failCount" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Reconciliation DONE. ok=$okCount fail=$failCount of $($work.Count)." $logPath
Write-LsqLog "Re-run 11-audit then this in report mode to confirm a clean state." $logPath
Write-LsqLog "=== Contact reconciliation complete [$mode] ===" $logPath
