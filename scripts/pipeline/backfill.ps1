<#
.SYNOPSIS
  Load historical calling activity from LeadSquared into Supabase. Checkpointed, resumable,
  read-only against LSQ.

.DESCRIPTION
  The webhook only captures forward from the moment it was switched on (2026-08-08 11:51
  IST). Everything before that has to be pulled from the activity trails, and the LSQ API
  cannot re-derive it later at scale - there is no bulk activity read, so this is the only
  route to a month view.

  Writes three things per lead:
    fact_call          calls on or after -FromDate
    fact_call_outcome  EventCode 203 forms on or after -FromDate
    fact_stage_change  EVERY stage change, regardless of date

  The stage changes are deliberately unbounded by date. Working out which stage a lead was
  in when it was called needs the transition BEFORE that call, which is frequently older
  than the reporting window. They are small, they dedupe on activity id, and without them
  the dashboard's "stage at call" silently degrades to "stage now".

  Cost is one API call per contact touched in the window, against a 10,000/day account cap.
  -WhatIf sizes the job without pulling anything.

.EXAMPLE
  pwsh ./scripts/pipeline/backfill.ps1 -FromDate 2026-08-01 -WhatIf
  pwsh ./scripts/pipeline/backfill.ps1 -FromDate 2026-08-01 -MaxApiCalls 4000

.NOTES
  ASCII only. Needs SUPABASE_URL and SUPABASE_SERVICE_KEY in config\.env.
  Run outside 09:00-20:00 IST so it does not compete with live rep traffic for the rate limit.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$FromDate = "2026-08-01",
    [int]$MaxApiCalls = 4000,
    [int]$BatchSize = 200,
    [int]$SleepMs = 200
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "pipeline_backfill_log.txt"
$checkpointPath = Join-Path $dataDir "pipeline_backfill_checkpoint.txt"

$cfg = Import-LsqConfig
foreach ($k in @("SUPABASE_URL", "SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$fromIst = [datetime]::ParseExact($FromDate, "yyyy-MM-dd", $inv)
$fromUtc = $fromIst.AddHours(-5).AddMinutes(-30)

Write-LsqLog "=== Backfill from $FromDate (UTC >= $($fromUtc.ToString('yyyy-MM-dd HH:mm:ss'))) ===" $logPath

# ---------------------------------------------------------------------------------------
# Negative control. A zero result is exactly as suspect as a wrong non-zero one - believing
# two unverified zeros silently skipped 20,076 leads during an earlier migration here.
# ---------------------------------------------------------------------------------------
$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "ProspectActivityDate_Max"; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">"
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Write-LsqLog "Negative control: $($neg.Count) rows -- must be 0" $logPath
if ($neg.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the watermark filter is being ignored." }

# ---------------------------------------------------------------------------------------
# Candidate scan. Sorted by the IMMUTABLE CreatedOn: paging over a column that changes while
# you page (ProspectActivityDate_Max moves constantly) reshuffles rows between pages and
# silently drops some.
# ---------------------------------------------------------------------------------------
$cols = "ProspectID,FirstName,LastName,Phone,Company,OwnerId,OwnerIdName,ProspectStage,mx_Call_Disposition,mx_Disqualification_Reason,mx_Segment,Source,ProspectActivityDate_Max,ProspectActivityName_Max"

$all = New-Object System.Collections.Generic.List[object]
$page = 1
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "ProspectActivityDate_Max"
        LookupValue = $fromUtc.ToString("yyyy-MM-dd HH:mm:ss")
        SqlOperator = ">"
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }
    foreach ($r in $rows) { [void]$all.Add($r) }
    Write-LsqLog "  page $page -> $($rows.Count) (total $($all.Count))" $logPath
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 200) { Write-LsqLog "  WARNING: stopped at 200 pages" $logPath; break }
}
$candidates = $all.ToArray()
Write-LsqLog "Contacts touched since $FromDate : $($candidates.Count)" $logPath
if ($candidates.Count -eq 0) { throw "Zero candidates - refusing to report a clean empty run." }

# Skip contacts whose only recent activity is the Callkaro AI dialler: it is ~41% of all
# lead-touch volume and contributes nothing to rep metrics, so pulling those trails would
# burn a large share of the daily API budget for data discarded on arrival.
$before = $candidates.Count
$scoped = @($candidates | Where-Object { "$($_.ProspectActivityName_Max)" -ne $Script:AI_ACTIVITY_NAME })
Write-LsqLog "Excluded $($before - $scoped.Count) AI-dialler-only contacts" $logPath

$done = @{}
if (Test-Path $checkpointPath) {
    foreach ($line in (Get-Content $checkpointPath)) { $t = $line.Trim(); if ($t) { $done[$t] = $true } }
    Write-LsqLog "Checkpoint holds $($done.Count) already-loaded contacts" $logPath
}
$todo = @($scoped | Where-Object { -not $done.ContainsKey("$($_.ProspectID)") })
Write-LsqLog "To pull this run: $($todo.Count) (ceiling $MaxApiCalls)" $logPath

if ($WhatIfPreference) {
    Write-LsqLog "" $logPath
    Write-LsqLog "DRY RUN - nothing pulled, nothing written." $logPath
    Write-LsqLog "  would pull    : $([Math]::Min($todo.Count, $MaxApiCalls)) trails" $logPath
    Write-LsqLog "  nights needed : $([Math]::Ceiling($todo.Count / [double]$MaxApiCalls)) at this ceiling" $logPath
    return
}

# ---------------------------------------------------------------------------------------
# Supabase writer
# ---------------------------------------------------------------------------------------
# Column order per table. PostgREST rejects a bulk insert whose objects do not all carry the
# SAME key set - "PGRST102: All object keys must match" - and PowerShell makes that easy to
# violate by accident, because ConvertTo-Json will happily emit whatever each hashtable
# happens to contain. Rather than trusting every construction site to be identical, every
# row is projected through these fixed schemas immediately before serialising.
$SbSchema = @{
    "fact_call"         = @("activity_id","prospect_id","event_code","direction","called_at_utc",
                            "actor_owner_id","actor_name","status","duration_sec","connected",
                            "call_note","recording_url","ingest_source")
    "fact_call_outcome" = @("activity_id","prospect_id","logged_at_utc","owner_id","status",
                            "connected_outcome","not_connected_outcome","next_step","note",
                            "ingest_source")
    "fact_stage_change" = @("activity_id","prospect_id","changed_at_utc","previous_stage",
                            "current_stage","changed_by_name","ingest_source")
    "dim_contact"       = @("prospect_id","company_name","full_name","phone","owner_id",
                            "owner_name","contact_stage","call_disposition",
                            "disqualification_reason","segment","source","last_refreshed_at")
}

function ConvertTo-SbJson {
    <#
      Project rows onto the table's exact key set, in a fixed order, converting empty strings
      to null so Postgres stores a real absence rather than "". Guarantees a uniform payload.
    #>
    param([Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][object[]]$Rows)
    $keys = $SbSchema[$Table]
    if (-not $keys) { throw "No schema defined for table $Table" }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[')
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append(',') }
        [void]$sb.Append('{')
        for ($j = 0; $j -lt $keys.Count; $j++) {
            if ($j -gt 0) { [void]$sb.Append(',') }
            $key = $keys[$j]
            $val = $Rows[$i][$key]
            [void]$sb.Append((ConvertTo-Json -InputObject $key -Compress))
            [void]$sb.Append(':')
            if ($null -eq $val -or ($val -is [string] -and $val -eq "")) {
                [void]$sb.Append('null')
            } elseif ($val -is [bool]) {
                [void]$sb.Append($(if ($val) { 'true' } else { 'false' }))
            } elseif ($val -is [int] -or $val -is [long] -or $val -is [double]) {
                [void]$sb.Append(([string]$val))
            } else {
                [void]$sb.Append((ConvertTo-Json -InputObject ([string]$val) -Compress))
            }
        }
        [void]$sb.Append('}')
    }
    [void]$sb.Append(']')
    return $sb.ToString()
}

function Invoke-SbUpsert {
    param([Parameter(Mandatory)][string]$Table, [AllowEmptyCollection()][object[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return 0 }
    $json = ConvertTo-SbJson -Table $Table -Rows $Rows
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $headers = @{
        apikey = $sbKey; Authorization = "Bearer $sbKey"
        Prefer = "resolution=merge-duplicates,return=minimal"
    }
    [void](Invoke-LsqWithRetry -What "upsert $Table" -Action {
        Invoke-RestMethod -Uri "$sbUrl/rest/v1/$Table" -Method Post -Body $bytes `
            -Headers $headers -ContentType "application/json; charset=utf-8" -ErrorAction Stop
    })
    return $Rows.Count
}

function ConvertTo-IsoUtc {
    param([AllowNull()][datetime]$D)
    if ($null -eq $D) { return $null }
    return $D.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

# ---------------------------------------------------------------------------------------
# Pull, convert, write.
#
# Trail shape, NOT webhook shape: Id / EventCode / ActivityFields(object) / Data(array of
# {Key,Value}). The webhook uses ProspectActivityId / ActivityEvent / Data(object) - same
# key, different meaning - so these conversions cannot be shared with the Apps Script ones.
# ---------------------------------------------------------------------------------------
$calls = New-Object System.Collections.Generic.List[object]
$outcomes = New-Object System.Collections.Generic.List[object]
$stages = New-Object System.Collections.Generic.List[object]
$contacts = New-Object System.Collections.Generic.List[object]

$apiCalls = 0; $pulled = 0; $failed = 0
$wroteCalls = 0; $wroteStages = 0; $wroteOutcomes = 0; $wroteContacts = 0
$batchLeads = New-Object System.Collections.Generic.List[string]

function Flush-Batch {
    $script:wroteCalls    += Invoke-SbUpsert -Table "fact_call"          -Rows $calls.ToArray()
    $script:wroteOutcomes += Invoke-SbUpsert -Table "fact_call_outcome"  -Rows $outcomes.ToArray()
    $script:wroteStages   += Invoke-SbUpsert -Table "fact_stage_change"  -Rows $stages.ToArray()
    $script:wroteContacts += Invoke-SbUpsert -Table "dim_contact"        -Rows $contacts.ToArray()
    foreach ($id in $batchLeads.ToArray()) { Add-Content -Path $checkpointPath -Value $id }
    $calls.Clear(); $outcomes.Clear(); $stages.Clear(); $contacts.Clear(); $batchLeads.Clear()
}

foreach ($lead in $todo) {
    if ($apiCalls -ge $MaxApiCalls) {
        Write-LsqLog "API ceiling $MaxApiCalls reached - stopping cleanly. Re-run to continue." $logPath
        break
    }
    $leadId = "$($lead.ProspectID)"
    try {
        $acts = Get-LeadActivities -ProspectId $leadId -Config $cfg
        $apiCalls++; $pulled++
    } catch {
        $failed++
        Write-LsqLog "  trail FAILED $leadId -> $($_.Exception.Message)" $logPath
        continue
    }

    [void]$contacts.Add([ordered]@{
        prospect_id = $leadId
        company_name = "$($lead.Company)"
        full_name = ("$($lead.FirstName) $($lead.LastName)").Trim()
        phone = "$($lead.Phone)"
        owner_id = "$($lead.OwnerId)"
        owner_name = "$($lead.OwnerIdName)"
        contact_stage = "$($lead.ProspectStage)"
        call_disposition = "$($lead.mx_Call_Disposition)"
        disqualification_reason = "$($lead.mx_Disqualification_Reason)"
        segment = "$($lead.mx_Segment)"
        source = "$($lead.Source)"
        last_refreshed_at = (ConvertTo-IsoUtc ([datetime]::UtcNow))
    })

    foreach ($a in $acts) {
        $code = "$($a.EventCode)"
        if ($code -eq $Script:EVENT_AI_CALL) { continue }   # Callkaro: never a person
        $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
        if ($null -eq $when) { continue }

        if ($code -eq $Script:EVENT_STAGE_CHANGE) {
            # Unbounded by date on purpose - see the header.
            [void]$stages.Add([ordered]@{
                activity_id = (Get-LsqActivityId $a)
                prospect_id = $leadId
                changed_at_utc = (ConvertTo-IsoUtc $when)
                previous_stage = (Get-ActivityDataValue $a "PreviousStage")
                current_stage = (Get-ActivityDataValue $a "CurrentStage")
                changed_by_name = (Get-ActivityDataValue $a "CreatedBy")
                ingest_source = "backfill"
            })
            continue
        }

        if ($when -lt $fromUtc) { continue }

        if ($code -eq $Script:EVENT_CALL_OUTBOUND -or $code -eq $Script:EVENT_CALL_INBOUND) {
            $note = "$($a.ActivityFields.ActivityEvent_Note)"
            $dur = Get-LsqCallDuration $a
            [void]$calls.Add([ordered]@{
                activity_id = (Get-LsqActivityId $a)
                prospect_id = $leadId
                event_code = $code
                direction = $(if ($code -eq $Script:EVENT_CALL_INBOUND) { "inbound" } else { "outbound" })
                called_at_utc = (ConvertTo-IsoUtc $when)
                actor_owner_id = "$($a.ActivityFields.CreatedBy)"
                actor_name = (Get-CallNoteValue -Blob $note -Key "Caller")
                status = "$($a.ActivityFields.Status)"
                duration_sec = $dur
                connected = ($dur -gt 0)
                call_note = (Get-CallNoteValue -Blob $note -Key "CallNotes")
                recording_url = "$($a.ActivityFields.mx_Custom_4)"
                ingest_source = "backfill"
            })
        }
        elseif ($code -eq $Script:EVENT_CALL_FORM) {
            $af = $a.ActivityFields
            [void]$outcomes.Add([ordered]@{
                activity_id = (Get-LsqActivityId $a)
                prospect_id = $leadId
                logged_at_utc = (ConvertTo-IsoUtc $when)
                owner_id = "$($af.Owner)"
                status = "$($af.Status)"
                connected_outcome = "$($af.mx_Custom_2)"      # NOT a duration - see header
                not_connected_outcome = "$($af.mx_Custom_1)"
                next_step = "$($af.mx_Custom_3)"              # NOT a duration either
                note = "$($af.ActivityEvent_Note)"
                ingest_source = "backfill"
            })
        }
    }

    [void]$batchLeads.Add($leadId)
    if ($batchLeads.Count -ge $BatchSize) {
        Flush-Batch
        Write-LsqLog "  progress $pulled/$($todo.Count) | api $apiCalls | calls $wroteCalls stages $wroteStages" $logPath
    }
    Start-Sleep -Milliseconds $SleepMs
}
if ($batchLeads.Count -gt 0) { Flush-Batch }

$remaining = $todo.Count - $pulled
Write-LsqLog "" $logPath
Write-LsqLog "=== Backfill run complete ===" $logPath
Write-LsqLog "  trails pulled  : $pulled  (failed $failed)" $logPath
Write-LsqLog "  API calls used : $apiCalls" $logPath
Write-LsqLog "  calls written  : $wroteCalls" $logPath
Write-LsqLog "  stage changes  : $wroteStages" $logPath
Write-LsqLog "  outcome forms  : $wroteOutcomes" $logPath
Write-LsqLog "  contacts       : $wroteContacts" $logPath
Write-LsqLog "  remaining      : $remaining" $logPath

if ($remaining -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "  INCOMPLETE - re-run to continue. Until it finishes the Daily Trend tab is a" $logPath
    Write-LsqLog "  PARTIAL history and must not be quoted as full coverage." $logPath
} else {
    Write-LsqLog "" $logPath
    Write-LsqLog "  Window complete. Verify before trusting it:" $logPath
    Write-LsqLog "    pwsh ./scripts/pipeline/02-qc-today.ps1 -TargetDate <a backfilled date>" $logPath
}
