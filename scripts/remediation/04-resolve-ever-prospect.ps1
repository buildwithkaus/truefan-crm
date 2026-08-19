<#
.SYNOPSIS
  For every contact holding a deal it should not have, answer one question from the stage
  trail: was this contact EVER at Prospect? READ-ONLY.

.DESCRIPTION
  A deal on a contact that is not at Prospect or Customer means one of two very different
  things:

    the contact reached Prospect and later moved off  -> a real deal that was worked and lost
    the contact never reached Prospect                -> a migration artifact; it never was a deal

  Both get deleted under the current decision, but the distinction is what makes the delete
  defensible, and it is recorded on every row so the deletion can be explained afterwards.

  THE SOURCE
  ----------
  EventCode 3002 carries PreviousStage / CurrentStage / CreatedBy in Data[] (it has no
  ActivityFields at all) and is present on essentially every contact's trail back to early
  2025. That makes stage history derivable for the whole book, where v_stage_history in the
  warehouse is only reliable from 1 August because it is webhook-fed.

  WHAT COUNTS AS "PROSPECT"
  -------------------------
  Not just the literal string. The pre-migration values Requirement Gathering (Warm),
  Conversation In Progress (Hot) and Contract Follow Up all MEANT Prospect, and Customer and
  Payment Received necessarily passed through it. The set is derived from $Script:StageMap by
  Get-LsqEverProspectStageValues rather than hand-written, so a legacy value added to the map
  later is picked up for free (hard rule 2). 'Follow Up' is deliberately excluded - the map
  puts it at Engaged.

  BOTH DIRECTIONS OF THE EVENT MATTER. A lead that went Requirement Gathering (Warm) ->
  Disqualified may have no event recording its ENTRY into that stage, because stage-change
  logging did not always run - but the exit event names it as PreviousStage. Testing only
  CurrentStage misses those entirely and converts a real deal into "never a prospect".

  MIGRATION-WRITTEN EVENTS ARE EVIDENCE, NOT NOISE
  -----------------------------------------------
  The 2026-07-30/31 restructure bulk-wrote ProspectStage, so a 3002 exists on nearly every
  lead. For THIS question those events are usable: a migration event with CurrentStage
  'Prospect' means the legacy value mapped to Prospect, which is exactly the fact being
  tested. The migration renamed the state, it did not invent it. CreatedBy is recorded so a
  human can see which resolutions rest on migration events, but it is never branched on.

  UNKNOWN IS A REAL ANSWER
  ------------------------
  A contact with no Prospect-meaning 3002 is NOT proven to have never been a Prospect - some
  deals predate reliable logging. Those resolve to EverProspect=$null with
  EvidenceSource='None', and the audit classes them DEAL_EVER_PROSPECT_UNKNOWN rather than
  folding them into the never-Prospect bucket.

.EXAMPLE
  powershell.exe -File scripts\remediation\04-resolve-ever-prospect.ps1
  powershell.exe -File scripts\remediation\04-resolve-ever-prospect.ps1 -Limit 25

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31). One API call per unresolved lead; results
  are cached so a re-run is free.
#>

param(
    [string]$ScanFile = "",
    [int]$Limit = 0,
    [int]$ThrottleMs = 250,
    [switch]$Refresh
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir   = Join-Path $PSScriptRoot "..\..\data"
$logPath   = Join-Path $dataDir "opportunity_everprospect_log.txt"
$cachePath = Join-Path $dataDir "opportunity_everprospect_cache.json"

$cfg = Import-LsqConfig
$KeepStages = @("Prospect", "Customer")

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

Write-LsqLog "" $logPath
Write-LsqLog "=== Ever-Prospect resolution ===" $logPath

$prospectMeaning = Get-LsqEverProspectStageValues
Write-LsqLog "Stage values that mean 'reached a deal stage' ($($prospectMeaning.Count), derived from `$Script:StageMap):" $logPath
foreach ($v in $prospectMeaning) { Write-LsqLog "    $v" $logPath }

if (-not $ScanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_scan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No scan file found. Run scripts\remediation\00-backup-opportunities.ps1 first." }
    $ScanFile = $newest.FullName
}
$scan = Read-Utf8Json $ScanFile
Write-LsqLog "Scan file: $ScanFile ($(@($scan.Deals).Count) deals)" $logPath

# The residue: contacts holding a deal whose stage does not entitle them to one. Everyone else
# is answered for free - a contact currently AT Prospect or Customer has self-evidently reached
# a deal stage, and costs no API call.
$residue = @($scan.Deals |
    Where-Object { "$($_.ContactStage)" -notin $KeepStages } |
    ForEach-Object { "$($_.ProspectId)" } |
    Sort-Object -Unique)
Write-LsqLog "Residue needing a trail read: $($residue.Count) contacts" $logPath

$cache = @{}
if ((Test-Path $cachePath) -and -not $Refresh) {
    foreach ($e in @((Read-Utf8Json $cachePath).Resolutions)) { $cache["$($e.ProspectId)"] = $e }
    Write-LsqLog "Cache holds $($cache.Count) prior resolutions (use -Refresh to discard)" $logPath
}

# Free resolutions for anyone currently at a Prospect-meaning stage.
foreach ($d in $scan.Deals) {
    $pid_ = "$($d.ProspectId)"
    if ($cache.ContainsKey($pid_)) { continue }
    if ("$($d.ContactStage)" -in $prospectMeaning) {
        $cache[$pid_] = [pscustomobject]@{
            ProspectId = $pid_; EverProspect = $true; EvidenceSource = "CurrentContactStage"
            FirstProspectUtc = $null; LastProspectUtc = $null; CreatedBy = ""
            Stage3002Count = 0; ResolvedAtUtc = ([datetime]::UtcNow).ToString("s")
        }
    }
}

$todo = @($residue | Where-Object { -not $cache.ContainsKey($_) })
if ($Limit -gt 0 -and $todo.Count -gt $Limit) { $todo = $todo[0..($Limit-1)] }
Write-LsqLog "To resolve via the trail this run: $($todo.Count)" $logPath

$i = 0; $yes = 0; $no = 0; $unknown = 0; $failed = 0
foreach ($leadId in $todo) {
    $i++
    try {
        $acts = @(Get-LeadActivities -ProspectId $leadId -Config $cfg)
        $stageEvents = @($acts | Where-Object { "$($_.EventCode)" -eq $Script:EVENT_STAGE_CHANGE })

        $ever = $null
        $source = "None"
        $first = $null; $last = $null; $by = ""

        foreach ($e in $stageEvents) {
            $cur  = "$(Get-ActivityDataValue $e 'CurrentStage')".Trim()
            $prev = "$(Get-ActivityDataValue $e 'PreviousStage')".Trim()
            $hit = $null
            if ($cur  -and $prospectMeaning -contains $cur)  { $hit = "CurrentStage" }
            elseif ($prev -and $prospectMeaning -contains $prev) { $hit = "PreviousStage" }
            if (-not $hit) { continue }

            $ever = $true
            if ($source -eq "None") { $source = $hit }
            $when = $null
            try { $when = ConvertFrom-LsqUtc "$($e.CreatedOn)" } catch { }
            if ($when) {
                if ($null -eq $first -or $when -lt $first) { $first = $when; $by = "$(Get-ActivityDataValue $e 'CreatedBy')" }
                if ($null -eq $last  -or $when -gt $last)  { $last  = $when }
            }
        }

        if ($null -eq $ever) {
            # Corroborating signal, free from the same read: a deal that advanced past the first
            # stage implies a real conversation happened. Recorded as its own source, never
            # promoted to a positive on its own.
            $advanced = @($acts | Where-Object {
                "$($_.EventCode)" -eq $Script:OPP_TYPE_ID -and
                $null -ne (Get-LsqOpportunityStageRank "$($_.ActivityFields.mx_Custom_2)") -and
                (Get-LsqOpportunityStageRank "$($_.ActivityFields.mx_Custom_2)") -ge 3
            })
            if ($advanced.Count -gt 0) {
                $ever = $true; $source = "DealAdvanced"
            } elseif ($stageEvents.Count -eq 0) {
                # No stage history at all. Absence of evidence, not evidence of absence.
                $ever = $null; $source = "None"
            } else {
                # Stage history exists and none of it names a Prospect-meaning value.
                $ever = $false; $source = "TrailComplete"
            }
        }

        $cache[$leadId] = [pscustomobject]@{
            ProspectId = $leadId
            EverProspect = $ever
            EvidenceSource = $source
            FirstProspectUtc = $(if ($first) { $first.ToString("s") } else { $null })
            LastProspectUtc  = $(if ($last)  { $last.ToString("s")  } else { $null })
            CreatedBy = $by
            Stage3002Count = $stageEvents.Count
            ResolvedAtUtc = ([datetime]::UtcNow).ToString("s")
        }
        if ($ever -eq $true) { $yes++ } elseif ($ever -eq $false) { $no++ } else { $unknown++ }
    } catch {
        $failed++
        Write-LsqLog "  trail read failed for $leadId -> $($_.Exception.Message)" $logPath
    }

    if ($i % 100 -eq 0) {
        Write-LsqLog "  $i/$($todo.Count) resolved | ever=$yes never=$no unknown=$unknown failed=$failed" $logPath
        [pscustomobject]@{ GeneratedAtUtc=([datetime]::UtcNow).ToString("s"); Resolutions=@($cache.Values) } |
            ConvertTo-Json -Depth 6 | Set-Content -Path $cachePath -Encoding UTF8
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

[pscustomobject]@{ GeneratedAtUtc=([datetime]::UtcNow).ToString("s"); Resolutions=@($cache.Values) } |
    ConvertTo-Json -Depth 6 | Set-Content -Path $cachePath -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "=== resolution summary ===" $logPath
$tally = @{}
foreach ($r in $cache.Values) {
    $k = "$($r.EvidenceSource)"
    if ($tally.ContainsKey($k)) { $tally[$k]++ } else { $tally[$k] = 1 }
}
foreach ($kv in ($tally.GetEnumerator() | Sort-Object Value -Descending)) {
    Write-LsqLog ("  {0,-24} {1}" -f $kv.Key, $kv.Value) $logPath
}
Write-LsqLog "" $logPath
Write-LsqLog ("  ever a Prospect : {0}" -f @($cache.Values | Where-Object { $_.EverProspect -eq $true }).Count) $logPath
Write-LsqLog ("  never           : {0}" -f @($cache.Values | Where-Object { $_.EverProspect -eq $false }).Count) $logPath
Write-LsqLog ("  UNKNOWN         : {0}  (must not be treated as 'never')" -f @($cache.Values | Where-Object { $null -eq $_.EverProspect }).Count) $logPath
Write-LsqLog ("  trail failures  : {0}" -f $failed) $logPath
Write-LsqLog "" $logPath
Write-LsqLog "Cache -> $cachePath" $logPath
Write-LsqLog "Next: scripts\reports\opportunity-hygiene-audit.ps1" $logPath
