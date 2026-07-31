<#
.SYNOPSIS
  Read-only audit of the post-migration state of every Lead: lifecycle stage, call disposition,
  disqualification reason/category, segment, and previous (legacy) stage.

.DESCRIPTION
  Answers, from live data rather than from the write logs:
    * how many leads sit on a LEGACY stage value (reps reverting post-migration), and what the
      correct lifecycle stage + call disposition for each of those should be;
    * whether every disqualification reason in the taxonomy actually has records behind it -
      the "I filter on Supply Issue / Conflict and see zero contacts" question. Note the reason
      values were RENAMED by the migration ("Supply Issue" -> "Celebrity Supply Gap",
      "Conflict" -> "Legacy - Unclassified"), so filtering on the OLD name legitimately returns
      zero. This prints the live values so the difference is visible rather than guessed at;
    * which mapped fields are still empty where the mapping says they should have a value.

  Writes nothing. Everything it reports is derived from a full enumeration that must reconcile
  to the known account size, so a short read cannot produce a falsely clean picture.

.NOTES
  pwsh ./scripts/leadsquared/migration/11-audit-post-migration.ps1
#>

. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_audit_log.txt"
$outPath = Join-Path $dataDir "migration_audit_state.json"

Write-LsqLog "=== Post-migration audit (READ-ONLY) ===" $logPath

$MinExpectedLeads = 80000
$all = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $resp = @(Expand-LsqRows (Invoke-LsqLeadSearch `
        -Filter @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01"; SqlOperator = ">" } `
        -ColumnsCsv "ProspectID,ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason,mx_Disqualification_Category,mx_Segment,mx_Previous_Contact_Stage,RelatedCompanyId,IsPrimaryContact,ProspectActivityDate_Max,ModifiedOn" `
        -SortColumn "CreatedOn" -SortDirection "1" -PageIndex $page -PageSize 1000))
    if ($resp.Count -eq 0) { break }
    foreach ($l in $resp) { [void]$all.Add($l) }
    if ($page % 20 -eq 0) { Write-LsqLog "  scanned $($all.Count)..." $logPath }
    if ($resp.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 250
}
Write-LsqLog "Total leads: $($all.Count)" $logPath
if ($all.Count -lt $MinExpectedLeads) { throw "Only $($all.Count) leads enumerated - refusing to audit from an incomplete scan." }

# Tally ONLY - no logging inside. Write-LsqLog writes to the output stream, so a function that
# both logs and returns hands the caller the log lines instead of the hashtable (which is
# exactly what broke the first run of this script).
function Get-Tally {
    param([string]$Field)
    $t = @{}
    foreach ($l in $all) {
        $v = "$($l.$Field)"
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        if ($t.ContainsKey($v)) { $t[$v]++ } else { $t[$v] = 1 }
    }
    return $t
}
function Write-Tally {
    param([string]$Title, [hashtable]$T, [int]$Total)
    $counted = 0
    foreach ($k in $T.Keys) { $counted += $T[$k] }
    Write-LsqLog "" $logPath
    Write-LsqLog "=== $Title ===" $logPath
    Write-LsqLog ("   (set: {0}   blank/unset: {1})" -f $counted, ($Total - $counted)) $logPath
    foreach ($k in ($T.Keys | Sort-Object { -$T[$_] })) { Write-LsqLog ("   {0,-42} {1}" -f $k, $T[$k]) $logPath }
}

$stageT    = Get-Tally "ProspectStage"
$dispT     = Get-Tally "mx_Call_Disposition"
$reasonT   = Get-Tally "mx_Disqualification_Reason"
$categoryT = Get-Tally "mx_Disqualification_Category"
$segmentT  = Get-Tally "mx_Segment"

Write-Tally "CONTACT STAGE (live)"              $stageT    $all.Count
Write-Tally "CALL DISPOSITION (live)"           $dispT     $all.Count
Write-Tally "DISQUALIFICATION REASON (live)"    $reasonT   $all.Count
Write-Tally "DISQUALIFICATION CATEGORY (live)"  $categoryT $all.Count
Write-Tally "SEGMENT (live)"                    $segmentT  $all.Count

# Every L2 reason the taxonomy defines - including ones with zero records, which is the point.
Write-LsqLog "" $logPath
Write-LsqLog "=== TAXONOMY COVERAGE - every reason the design defines, and its live count ===" $logPath
$definedReasons = @{}
foreach ($k in $Script:StageMap.Keys) {
    $m = $Script:StageMap[$k]
    if ($m.Reason) { $definedReasons["$($m.Reason)"] = $k }
}
foreach ($r in ($definedReasons.Keys | Sort-Object)) {
    $live = if ($reasonT.ContainsKey($r)) { $reasonT[$r] } else { 0 }
    $flag = if ($live -eq 0) { "  <-- ZERO" } else { "" }
    Write-LsqLog ("   {0,-42} {1,-8} (from legacy [{2}]){3}" -f $r, $live, $definedReasons[$r], $flag) $logPath
}

# Leads on a legacy stage value - reps reverting after the migration.
$canonical = @{}
foreach ($s in $Script:ContactStages) { $canonical[$s] = $true }
$legacy = New-Object System.Collections.Generic.List[object]
foreach ($l in $all) {
    $s = "$($l.ProspectStage)"
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    if (-not $canonical.ContainsKey($s)) { [void]$legacy.Add($l) }
}
Write-LsqLog "" $logPath
Write-LsqLog "=== LEADS ON A LEGACY STAGE (rep reverts / new leads): $($legacy.Count) ===" $logPath
$byLegacy = @{}
foreach ($l in $legacy) { $v = "$($l.ProspectStage)"; if ($byLegacy.ContainsKey($v)) { $byLegacy[$v]++ } else { $byLegacy[$v] = 1 } }
foreach ($k in ($byLegacy.Keys | Sort-Object { -$byLegacy[$_] })) {
    $m = $Script:StageMap[$k]
    $target = if ($m) { if ($m.Infer) { "(infer)" } else { $m.Contact } } else { "UNMAPPED" }
    $disp = if ($m -and $m.Disposition) { $m.Disposition } else { "-" }
    Write-LsqLog ("   {0,-38} {1,-6} -> stage [{2}]  disposition [{3}]" -f $k, $byLegacy[$k], $target, $disp) $logPath
}

# How many of those already carry a disposition (rep followed the new instruction as well)?
$legacyWithDisp = @($legacy | Where-Object { -not [string]::IsNullOrWhiteSpace("$($_.mx_Call_Disposition)") }).Count
Write-LsqLog ("   of these, already have a Call Disposition set: {0}" -f $legacyWithDisp) $logPath

# Leads on a canonical stage whose Previous Contact Stage implies fields they do not have.
$missing = @{ Reason = 0; Category = 0; Disposition = 0; Segment = 0 }
$missingLeads = 0
foreach ($l in $all) {
    $prev = "$($l.mx_Previous_Contact_Stage)"
    if ([string]::IsNullOrWhiteSpace($prev) -or -not $Script:StageMap.ContainsKey($prev)) { continue }
    $m = $Script:StageMap[$prev]
    $any = $false
    if ($m.Reason      -and [string]::IsNullOrWhiteSpace("$($l.mx_Disqualification_Reason)"))   { $missing.Reason++;      $any = $true }
    if ($m.Category    -and [string]::IsNullOrWhiteSpace("$($l.mx_Disqualification_Category)")) { $missing.Category++;    $any = $true }
    if ($m.Disposition -and [string]::IsNullOrWhiteSpace("$($l.mx_Call_Disposition)"))          { $missing.Disposition++; $any = $true }
    if ($m.Segment     -and [string]::IsNullOrWhiteSpace("$($l.mx_Segment)"))                   { $missing.Segment++;     $any = $true }
    if ($any) { $missingLeads++ }
}
Write-LsqLog "" $logPath
Write-LsqLog "=== FIELD GAPS vs what Previous Contact Stage implies ===" $logPath
foreach ($k in $missing.Keys) { Write-LsqLog ("   missing {0,-14} {1}" -f $k, $missing[$k]) $logPath }
Write-LsqLog ("   leads needing at least one field: {0}" -f $missingLeads) $logPath

# Save state so the fixer scripts do not have to re-enumerate.
$snapshot = $all | ForEach-Object {
    [pscustomobject]@{
        ProspectId   = "$($_.ProspectID)"
        Stage        = "$($_.ProspectStage)"
        Disposition  = "$($_.mx_Call_Disposition)"
        Reason       = "$($_.mx_Disqualification_Reason)"
        Category     = "$($_.mx_Disqualification_Category)"
        Segment      = "$($_.mx_Segment)"
        PreviousStage= "$($_.mx_Previous_Contact_Stage)"
        CompanyId    = "$($_.RelatedCompanyId)"
        IsPrimary    = (Test-LsqTrue $_.IsPrimaryContact)
        LastActivity = "$($_.ProspectActivityDate_Max)"
    }
}
$snapshot | ConvertTo-Json -Depth 3 | Set-Content -Path $outPath
Write-LsqLog "" $logPath
Write-LsqLog "State snapshot written: $($snapshot.Count) leads -> $outPath" $logPath
Write-LsqLog "=== Audit complete ===" $logPath
