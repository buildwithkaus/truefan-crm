<#
.SYNOPSIS
  Load channel touches (fact_touch) AND assignment history (fact_assignment) from lead
  activity trails, in ONE pass. Read-only against LeadSquared; writes only to Supabase.

.DESCRIPTION
  These two backfills need exactly the same expensive thing - the lead's full activity trail,
  one API call per lead, with no bulk read available. Running them as separate jobs would
  double the cost of the most expensive operation in this system for no benefit, so they
  share the pass.

  WHAT IT EXTRACTS, per lead, from one trail:
    * every non-call, non-Callkaro activity  -> fact_touch     (WhatsApp, chat, forms,
                                                                meetings, contract, payment)
    * every EventCode 3001 LeadAssigned      -> fact_assignment (previous + current owner)

  Calls (21/22) are deliberately NOT written. fact_call is live, reconciles exactly, and is
  fed by webhooks and the existing backfill; fact_touch has a CHECK constraint rejecting call
  codes so a mistake here fails loudly instead of double-counting every call in the account.

  SCOPES, with the cost measured on 2026-08-10 (cap is 10,000 API calls/day):
    Enriched   17,608 leads - those already in dim_contact. Matches what the saturation
                              views can currently see. ~3 hours.
    Workable   26,302 leads - Fresh/Engaged/Prospect. 4 nights.
    Touched    16,092 leads - any activity since -Since. 3 nights.
    All        91,033 leads - the whole book. 12 nights.

  Checkpointed and resumable: the checkpoint file holds every ProspectID already done, so an
  interrupted run resumes rather than restarting. Re-running is safe regardless - both tables
  are keyed on the LSQ activity id and every write is an upsert.

.PARAMETER Scope
  Enriched | Workable | Touched | All

.PARAMETER MaxLeads
  Hard ceiling on leads processed this run. Use it to stay inside the daily API budget.

.EXAMPLE
  powershell.exe -File scripts\pipeline\11-load-trail-history.ps1 -Scope Enriched -MaxLeads 25 -WhatIf
  powershell.exe -File scripts\pipeline\11-load-trail-history.ps1 -Scope Enriched -MaxLeads 6000

.NOTES
  ASCII only. Do NOT run alongside another LSQ script - the rate limit is account-wide and a
  collision produces transient failures in both. Migrations 015 and 016 must be applied first.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Enriched", "Workable", "Touched", "All")]
    [string]$Scope = "Enriched",
    [int]$MaxLeads = 6000,
    [string]$Since = "2026-08-01",
    [int]$SleepMs = 220,
    [int]$BatchSize = 400
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir    = Join-Path $PSScriptRoot "..\..\data"
$logPath    = Join-Path $dataDir "trail_history_log.txt"
$checkPath  = Join-Path $dataDir "trail_history_checkpoint.txt"

$cfg = Import-LsqConfig
foreach ($k in @("SUPABASE_URL", "SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']
$sbHeaders = @{ apikey = $sbKey; Authorization = "Bearer $sbKey"
                Prefer = "resolution=merge-duplicates,return=minimal" }

Write-LsqLog "" $logPath
Write-LsqLog "=== Trail history load: scope=$Scope maxLeads=$MaxLeads ===" $logPath


# =======================================================================================
# Helpers
# =======================================================================================
function Split-OwnerRef {
    <#
      PURE. "Subham Tak (subham.tak@true-fan.in)" -> name + email.

      Returns the raw string untouched alongside the parse. An owner with no email at all is
      real and common ("PreviousOwner=System"), and must come back as a name with an empty
      email rather than as a null row - a dropped assignment silently shortens a contact's
      ownership history and makes days_held wrong for the wrong rep.
    #>
    param([AllowNull()][string]$Value)
    $raw = "$Value".Trim()
    if (-not $raw) { return @{ Raw = ""; Name = ""; Email = "" } }
    $m = [regex]::Match($raw, '^(?<name>.*?)\s*\((?<email>[^)]*)\)\s*$')
    if ($m.Success) {
        return @{ Raw = $raw; Name = $m.Groups['name'].Value.Trim(); Email = $m.Groups['email'].Value.Trim() }
    }
    return @{ Raw = $raw; Name = $raw; Email = "" }
}

function Invoke-SbUpsert {
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows
    )
    if ($Rows.Count -eq 0) { return 0 }

    # Dedupe on the primary key BEFORE sending. PostgreSQL refuses an ON CONFLICT DO UPDATE
    # that would touch the same row twice in one statement, and PostgREST surfaces that as a
    # bare HTTP 500 with no useful body - which the retry wrapper then dutifully repeats four
    # times. The same activity legitimately appears twice in a trail under two event codes
    # (3011 mirrors 201 and 12000), so this is a real condition, not a defensive nicety.
    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        $key = "$($r.activity_id)"
        if (-not $key -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$unique.Add($r)
    }
    $Rows = $unique.ToArray()
    if ($Rows.Count -eq 0) { return 0 }

    $written = 0
    for ($i = 0; $i -lt $Rows.Count; $i += $BatchSize) {
        $slice = $Rows[$i..([Math]::Min($i + $BatchSize - 1, $Rows.Count - 1))]
        $json = ConvertTo-Json -InputObject $slice -Depth 8
        # ConvertTo-Json collapses a single-element array into a bare object; PostgREST then
        # rejects it. Same trap as gotcha 12.
        if ($slice.Count -eq 1) { $json = "[$json]" }
        [void](Invoke-LsqWithRetry -What "upsert $Table" -Action {
            Invoke-RestMethod -Uri "$sbUrl/rest/v1/$Table" -Method Post `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -Headers $sbHeaders `
                -ContentType "application/json; charset=utf-8" -ErrorAction Stop
        })
        $written += $slice.Count
    }
    return $written
}


# =======================================================================================
# Candidate set
# =======================================================================================
Write-LsqLog "Building the candidate set..." $logPath

$candidates = New-Object System.Collections.Generic.List[string]

if ($Scope -eq "Enriched") {
    # From Supabase, not LeadSquared - these are the contacts the warehouse already knows,
    # so this scope costs zero LSQ calls to enumerate.
    $offset = 0
    while ($true) {
        $r = Invoke-LsqWithRetry -What "dim_contact page" -Action {
            Invoke-WebRequest -Uri "$sbUrl/rest/v1/dim_contact?select=prospect_id&limit=1000&offset=$offset" `
                -Headers @{ apikey = $sbKey; Authorization = "Bearer $sbKey" } -UseBasicParsing -ErrorAction Stop
        }
        # Expand-LsqRows, NOT @(...). ConvertFrom-Json hands the whole JSON array to the
        # pipeline as ONE object, so @($content | ConvertFrom-Json) has Count = 1 no matter
        # how many rows came back - the paging loop then reads "1 row, less than 1000, stop"
        # and reports a complete pass after one page. Same failure family as gotcha 19, and
        # it is why this loop returned 1 candidate against 17,608 contacts on first run.
        $rows = Expand-LsqRows ($r.Content | ConvertFrom-Json)
        if ($rows.Count -eq 0) { break }
        foreach ($x in $rows) { [void]$candidates.Add("$($x.prospect_id)") }
        if ($rows.Count -lt 1000) { break }
        $offset += 1000
    }
} else {
    $filter = @{ LookupName = "CreatedOn"; LookupValue = "2000-01-01 00:00:00"; SqlOperator = ">" }
    if ($Scope -eq "Touched") {
        $filter = @{ LookupName = "ProspectActivityDate_Max"; LookupValue = "$Since 00:00:00"; SqlOperator = ">" }
    }

    # Negative control before trusting the filter. A zero result is exactly as suspect as a
    # wrong non-zero one - two unverified zeros once skipped 20,076 leads.
    $neg = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "CreatedOn"; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">"
    } -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
    Write-LsqLog "  negative control: $($neg.Count) rows -- must be 0" $logPath
    if ($neg.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the filter is being ignored." }

    $page = 1
    while ($true) {
        $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter $filter `
            -ColumnsCsv "ProspectID,ProspectStage" -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
        if ($rows.Count -eq 0) { break }
        foreach ($x in $rows) {
            if ($Scope -eq "Workable" -and "$($x.ProspectStage)" -notin @("Fresh", "Engaged", "Prospect")) { continue }
            [void]$candidates.Add("$($x.ProspectID)")
        }
        if ($rows.Count -lt 1000) { break }
        $page++
        if ($page -gt 300) { Write-LsqLog "  WARNING: stopped paging at 300" $logPath; break }
    }
}

$allCandidates = $candidates.ToArray()
Write-LsqLog "  candidate set: $($allCandidates.Count) leads" $logPath
if ($allCandidates.Count -eq 0) { throw "Empty candidate set for scope '$Scope' - refusing to report a successful no-op." }

# Resume
$done = @{}
if (Test-Path $checkPath) {
    foreach ($line in (Get-Content $checkPath)) { if ($line) { $done["$line".Trim()] = $true } }
    Write-LsqLog "  checkpoint: $($done.Count) leads already processed" $logPath
}
$todo = @($allCandidates | Where-Object { -not $done.ContainsKey($_) })
if ($todo.Count -gt $MaxLeads) { $todo = $todo[0..($MaxLeads - 1)] }
Write-LsqLog "  to process this run: $($todo.Count)" $logPath

if ($WhatIfPreference) {
    Write-LsqLog "DRY RUN - no trails fetched, nothing written." $logPath
    return
}


# =======================================================================================
# The pass
# =======================================================================================
$touchRows  = New-Object System.Collections.Generic.List[object]
$assignRows = New-Object System.Collections.Generic.List[object]
$pendingIds = New-Object System.Collections.Generic.List[string]
$processed = 0; $failed = 0; $touchTotal = 0; $assignTotal = 0

function Save-Batch {
    <#
      Write the buffer, and ONLY THEN checkpoint the leads it came from.

      The ordering is the point. A checkpoint written before the write means an interrupted
      or failed batch leaves those leads marked done, and the resume skips them permanently -
      a silent hole in the history that every subsequent run reports as complete.
    #>
    $t = Invoke-SbUpsert -Table "fact_touch"      -Rows $touchRows.ToArray()
    $a = Invoke-SbUpsert -Table "fact_assignment" -Rows $assignRows.ToArray()
    $Script:touchTotal  += $t
    $Script:assignTotal += $a
    $touchRows.Clear(); $assignRows.Clear()

    if ($pendingIds.Count -gt 0) {
        Add-Content -Path $checkPath -Value $pendingIds.ToArray()
        $pendingIds.Clear()
    }
}

foreach ($pid_ in $todo) {
    try {
        $acts = Get-LeadActivities -ProspectId $pid_ -Config $cfg
        $processed++
    } catch {
        $failed++
        Write-LsqLog "  trail FAILED $pid_ : $($_.Exception.Message)" $logPath
        Start-Sleep -Milliseconds $SleepMs
        continue
    }

    foreach ($a in $acts) {
        $code = "$($a.EventCode)"
        if ($code -eq $Script:EVENT_AI_CALL) { continue }                      # Callkaro
        if ($code -eq $Script:EVENT_CALL_OUTBOUND -or $code -eq $Script:EVENT_CALL_INBOUND) { continue }

        # EventCode 3011 is a MIRROR, not an activity. Proven live 2026-08-10: a
        # 3011|WhatsApp Message carries the SAME top-level Id as the 201|WhatsApp Message it
        # shadows, and a 3011|Opportunity the same Id as its 12000. Storing both would
        # double every WhatsApp number in the system, and because the primary key collides
        # it also makes the batch upsert fail outright - PostgreSQL refuses an ON CONFLICT
        # that would touch the same row twice, which PostgREST reports as an opaque HTTP 500.
        #
        # Skipped here rather than deduped so the reason is explicit. The dedupe below is a
        # second, general guard.
        if ($code -eq "3011") { continue }

        # Opportunities have their own table, loaded by 08-load-opportunity-details.ps1 with
        # all 29 fields. The trail copy carries four.
        if ($code -eq "12000" -or $code -eq "33") { continue }

        $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
        if ($null -eq $when) { continue }   # never persist an unparseable date as real
        $stamp = $when.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

        $id = ""
        try { $id = Get-LsqActivityId -Activity $a } catch { continue }
        $lead = "$($a.RelatedProspectId)".Trim(); if (-not $lead) { $lead = $pid_ }

        if ($code -eq "3001") {
            $prev = Split-OwnerRef (Get-ActivityDataValue $a "PreviousOwner")
            $curr = Split-OwnerRef (Get-ActivityDataValue $a "CurrentOwner")
            # Fixed key set on every row - PostgREST rejects a bulk insert whose objects
            # differ at all ("PGRST102: All object keys must match").
            [void]$assignRows.Add([ordered]@{
                activity_id          = $id
                prospect_id          = $lead
                assigned_at_utc      = $stamp
                previous_owner_raw   = $prev.Raw
                previous_owner_name  = $prev.Name
                previous_owner_email = $prev.Email
                current_owner_raw    = $curr.Raw
                current_owner_name   = $curr.Name
                current_owner_email  = $curr.Email
                changed_by_name      = (Get-ActivityDataValue $a "CreatedBy")
                ingest_source        = "backfill"
            })
            continue
        }

        # Everything else is a touch. WhatsApp carries its own per-message direction; no
        # other channel does, so it is read only where it means that.
        $dirRaw = ""
        if ($code -eq "201" -or $code -eq "3011") { $dirRaw = "$($a.ActivityFields.mx_Custom_2)".Trim() }

        $attrs = @{}
        if ($null -ne $a.ActivityFields) {
            foreach ($p in $a.ActivityFields.PSObject.Properties) {
                $v = "$($p.Value)"
                if ($v) { $attrs[$p.Name] = $v }
            }
        }

        [void]$touchRows.Add([ordered]@{
            activity_id    = $id
            prospect_id    = $lead
            event_code     = $code
            event_name     = "$($a.EventName)"
            touched_at_utc = $stamp
            actor_owner_id = "$($a.ActivityFields.CreatedBy)".Trim()
            actor_name     = ""
            status         = "$($a.ActivityFields.Status)".Trim()
            direction_raw  = $dirRaw
            duration_sec   = $null
            note           = "$($a.ActivityFields.ActivityEvent_Note)".Trim()
            attrs          = $attrs
            ingest_source  = "backfill"
        })
    }

    # Buffer the lead id; it is only checkpointed once its rows have actually been written.
    # Checkpointing here instead would mark a lead done whose batch then failed - and on
    # resume it would be skipped forever, losing its history silently. That is the same
    # shape as the migration bug that logged 25,520 leads as "already at target (skipped)".
    [void]$pendingIds.Add($pid_)
    if (($touchRows.Count + $assignRows.Count) -ge 800) { Save-Batch }
    if ($processed % 250 -eq 0) {
        Write-LsqLog "  $processed/$($todo.Count) leads | touches $touchTotal | assignments $assignTotal | failed $failed" $logPath
    }
    Start-Sleep -Milliseconds $SleepMs
}

Save-Batch

Write-LsqLog "" $logPath
Write-LsqLog "Processed $processed leads ($failed failed)." $logPath
Write-LsqLog "  fact_touch rows written      : $touchTotal" $logPath
Write-LsqLog "  fact_assignment rows written : $assignTotal" $logPath
Write-LsqLog "" $logPath
Write-LsqLog "VERIFY INDEPENDENTLY - a write response is not evidence:" $logPath
Write-LsqLog "  GET /rest/v1/v_qc_channel?select=*" $logPath
Write-LsqLog "  GET /rest/v1/v_qc_saturation?select=*" $logPath
Write-LsqLog "  GET /rest/v1/v_channel_unmapped?select=*   (should be empty)" $logPath
