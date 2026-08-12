<#
.SYNOPSIS
  Roll back the 2,729 contacts that 12-reconcile-contacts.ps1 moved from the legacy stage
  'Future Prospect' to 'Disqualified' on 2026-08-11.

.DESCRIPTION
  The reconciliation was correct against the locked model - 'Future Prospect' is a COMPANY
  stage and is not one of the five contact stages - but reps were working those 2,729
  accounts as a live revisit list, and nothing yet brings them back. Kaustubh chose to
  restore them (2026-08-12).

  THE SET IS EXACT, NOT INFERRED. It comes from fact_field_change, which is the only record
  of what the field held before: field ProspectStage, old 'Future Prospect', new
  'Disqualified', changed on 2026-08-11. That is 2,729 distinct contacts. Six more contacts
  made the same transition on OTHER dates and are deliberately excluded - they were not ours.

  A CONTACT IS SKIPPED IF IT HAS MOVED SINCE. Each one is re-read immediately before the
  write, and only those still sitting at 'Disqualified' are reverted. A rep who has since
  worked one of these - re-qualified it, or disqualified it deliberately with a fresh reason -
  must not have that overwritten by a rollback. The whole complaint here is about a bulk job
  changing records under people; repeating that in the fix would be worse than the original.

  ONLY THE STAGE IS REVERTED. The reconciliation also filled 181 disqualification reasons and
  183 categories on these records. Those are left in place: they are additive, they were
  mostly already correct, and removing them would destroy information to undo a stage change.

  PREREQUISITE - READ THIS FIRST. 'Future Prospect' is NOT currently a selectable
  ProspectStage option (verified 2026-08-12: 11 options, and every stored value is one of
  them). Writing it back puts 2,729 contacts on a value no rep can select or filter on -
  gotcha 10, the same condition that once made 61,919 leads invisible to every rep filter.
  ADD 'Future Prospect' TO THE ProspectStage DROPDOWN IN THE LSQ UI BEFORE RUNNING THIS,
  or the rollback restores the records without restoring the reps' ability to see them.

  The script checks that option list itself and refuses to run if it is missing.

.PARAMETER Execute
  Required to write. Without it, reports exactly what it would change.

.EXAMPLE
  powershell.exe -File scripts\migration\18-rollback-future-prospect.ps1
  powershell.exe -File scripts\migration\18-rollback-future-prospect.ps1 -Execute

.NOTES
  ASCII only. Do not run alongside another LSQ script - the rate limit is account-wide.
#>

[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$SkipDropdownCheck,
    [string]$MovedOn = "2026-08-11",
    [int]$BatchSize = 25,
    [int]$ThrottleMs = 1100
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "rollback_future_prospect_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"

$cfg = Import-LsqConfig
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/'); $sbKey = $cfg['SUPABASE_SERVICE_KEY']
$sbHead = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }

$TARGET_STAGE = "Future Prospect"
$FROM_STAGE   = "Disqualified"

Write-LsqLog "" $logPath
Write-LsqLog "=== Rollback '$TARGET_STAGE' $stamp ===" $logPath

# ---------------------------------------------------------------------------------------
# Prerequisite: the value must be selectable, or the rollback restores records without
# restoring anyone's ability to work them.
# ---------------------------------------------------------------------------------------
if (-not $SkipDropdownCheck) {
    $meta = (Invoke-LsqWithRetry -What "LeadsMetaData.Get" -Action {
        Invoke-WebRequest -Uri "$($cfg['LSQ_API_HOST'])/LeadManagement.svc/LeadsMetaData.Get?accessKey=$($cfg['LSQ_ACCESS_KEY'])&secretKey=$($cfg['LSQ_SECRET_KEY'])" -UseBasicParsing -ErrorAction Stop
    }).Content | ConvertFrom-Json
    $ps = @($meta | Where-Object { $_.SchemaName -eq 'ProspectStage' })
    # Options is an ARRAY of objects carrying .Value - NOT a string. String-coercing it
    # ("$($ps.Options)") yields an empty string, which then reads as "the option is absent"
    # for every value you test. That produced a confident, wrong "Future Prospect is not
    # selectable" on 2026-08-12. Read it the way verify-dropdown-coverage.ps1 does.
    $optionValues = @($ps[0].Options | ForEach-Object { "$($_.Value)" } | Where-Object { $_ -ne "" })
    $isOption = ($optionValues -contains $TARGET_STAGE)
    Write-LsqLog "Dropdown check: $($optionValues.Count) options; '$TARGET_STAGE' selectable = $isOption" $logPath
    Write-LsqLog "  options: $($optionValues -join ' | ')" $logPath
    if (-not $isOption) {
        Write-LsqLog "" $logPath
        Write-LsqLog "REFUSING TO RUN. '$TARGET_STAGE' is not a selectable ProspectStage option." $logPath
        Write-LsqLog "Writing it would leave 2,729 contacts on a value no rep can select or filter" $logPath
        Write-LsqLog "on - the same condition that made 61,919 leads invisible (gotcha 10)." $logPath
        Write-LsqLog "Add it in the LSQ UI (Settings > Customization > Lead > Contact Stage), then" $logPath
        Write-LsqLog "re-run. Use -SkipDropdownCheck only if you have confirmed it another way." $logPath
        throw "Prerequisite not met: '$TARGET_STAGE' is not a selectable option."
    }
}

# ---------------------------------------------------------------------------------------
# The exact set, from the only record of what the field held before.
# ---------------------------------------------------------------------------------------
$ids = New-Object System.Collections.Generic.List[string]
$off = 0
while ($true) {
    $resp = Invoke-LsqWithRetry -What "fact_field_change page" -Action {
        Invoke-WebRequest -Uri ("$sbUrl/rest/v1/fact_field_change?select=prospect_id,changed_at_utc" +
            "&field_name=eq.ProspectStage&old_value=eq.Future%20Prospect&new_value=eq.Disqualified" +
            "&limit=1000&offset=$off") -Headers $sbHead -UseBasicParsing -ErrorAction Stop
    }
    # Expand-LsqRows, not @(): ConvertFrom-Json hands the whole array to the pipeline as ONE
    # object, so @() would count 1 and the pager would stop after a single page.
    $rows = Expand-LsqRows ($resp.Content | ConvertFrom-Json)
    if ($rows.Count -eq 0) { break }
    foreach ($r in $rows) {
        if ("$($r.changed_at_utc)".StartsWith($MovedOn)) { [void]$ids.Add("$($r.prospect_id)") }
    }
    if ($rows.Count -lt 1000) { break }
    $off += 1000
}

$unique = @($ids.ToArray() | Sort-Object -Unique)
Write-LsqLog "Contacts moved $TARGET_STAGE -> $FROM_STAGE on $MovedOn : $($unique.Count)" $logPath
if ($unique.Count -eq 0) { throw "Empty set - refusing to report a successful no-op." }

# ---------------------------------------------------------------------------------------
# Re-read current state. Only revert what is STILL at Disqualified.
# ---------------------------------------------------------------------------------------
Write-LsqLog "Re-reading current stage for each (skipping any a rep has since moved)..." $logPath
$toRevert = New-Object System.Collections.Generic.List[string]
$moved = 0; $missing = 0; $checked = 0

foreach ($chunk in 0..([math]::Ceiling($unique.Count / 100) - 1)) {
    $slice = $unique[($chunk*100)..([Math]::Min($chunk*100+99, $unique.Count-1))]
    foreach ($pid_ in $slice) {
        $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
            LookupName = "ProspectID"; LookupValue = $pid_; SqlOperator = "="
        } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1 -SortColumn "CreatedOn"))
        $checked++
        if ($rows.Count -eq 0) { $missing++; continue }
        if ("$($rows[0].ProspectStage)" -eq $FROM_STAGE) { [void]$toRevert.Add($pid_) } else { $moved++ }
        Start-Sleep -Milliseconds 120
    }
    Write-LsqLog "  checked $checked/$($unique.Count) - revert $($toRevert.Count), moved on $moved, missing $missing" $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "=== PLAN ===" $logPath
Write-LsqLog "  in the original set        : $($unique.Count)" $logPath
Write-LsqLog "  still at $FROM_STAGE  : $($toRevert.Count)  <- will be set to '$TARGET_STAGE'" $logPath
Write-LsqLog "  moved on since (skipped)   : $moved" $logPath
Write-LsqLog "  not found (skipped)        : $missing" $logPath

$outPath = Join-Path $dataDir "rollback_future_prospect_worklist_$stamp.json"
$toRevert.ToArray() | ConvertTo-Json -Depth 2 | Set-Content -Path $outPath -Encoding UTF8
Write-LsqLog "  worklist written: $outPath" $logPath

if (-not $Execute) {
    Write-LsqLog "" $logPath
    Write-LsqLog "REPORT ONLY - nothing written. Re-run with -Execute." $logPath
    return
}

# ---------------------------------------------------------------------------------------
# Write. Bulk update, 25 per call, throttled - the account cap is 20 calls / 5 sec and it is
# account-wide, so a faster loop takes the live pipeline down with it.
# ---------------------------------------------------------------------------------------
$work = $toRevert.ToArray()
$bulkUrl = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"
$batches = [math]::Ceiling($work.Count / $BatchSize)
Write-LsqLog "Writing $($work.Count) leads in $batches batches..." $logPath
$ok = 0; $fail = 0

for ($b = 0; $b -lt $batches; $b++) {
    $slice = $work[($b*$BatchSize)..([Math]::Min($b*$BatchSize + $BatchSize - 1, $work.Count - 1))]
    # Exact body shape of Lead/Bulk/UpdateV2, copied from 12-reconcile-contacts.ps1 rather
    # than reconstructed: a bare array of {Attribute,Value} is rejected. Note the key is
    # "ProspectId" with a lower-case d - "ProspectID", which every READ path uses, is not
    # accepted here.
    $recJson = foreach ($pid_ in $slice) {
        '{"Fields":[' +
            '{"Attribute":"ProspectId","Value":' + (ConvertTo-Json -InputObject "$pid_") + '},' +
            '{"Attribute":"ProspectStage","Value":' + (ConvertTo-Json -InputObject $TARGET_STAGE) + '}' +
        ']}'
    }
    $body = '{"SearchByKey":"ProspectId","Options":{"PushNonExistentLeadsToUnProcessedList":true},' +
            '"LeadPropertiesList":[' + (@($recJson) -join ',') + ']}'
    try {
        # -Uri, and built by Get-LsqUrl which appends the credentials. Invoke-LsqPost has no
        # -Path parameter; passing one fails EVERY batch with "A parameter cannot be found
        # that matches parameter name 'Path'" - which is how the first run of this script
        # wrote nothing at all. Matches how 12-reconcile-contacts.ps1 calls the same endpoint.
        $r = Invoke-LsqPost -Uri $bulkUrl -JsonBody $body
        $sc = 0; [void][int]::TryParse("$($r.Status.SuccessCount)", [ref]$sc)
        $ok += $sc
        $fc = 0; [void][int]::TryParse("$($r.Status.FailureCount)", [ref]$fc)
        if ($fc -gt 0) { $fail += $fc; Write-LsqLog "  batch $b : $fc failure(s)" $logPath }
    } catch {
        $fail += $slice.Count
        Write-LsqLog "  batch $b FAILED: $($_.Exception.Message)" $logPath
    }
    if ($b % 20 -eq 0) { Write-LsqLog "  batch $b/$batches ok=$ok fail=$fail" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "" $logPath
Write-LsqLog "Rollback DONE. ok=$ok fail=$fail of $($work.Count)." $logPath
Write-LsqLog "VERIFY INDEPENDENTLY - a write response is not evidence:" $logPath
Write-LsqLog "  filter ProspectStage = '$TARGET_STAGE' in LSQ and confirm the count" $logPath
Write-LsqLog "  then run scripts\reports\verify-dropdown-coverage.ps1" $logPath
