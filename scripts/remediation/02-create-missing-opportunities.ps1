<#
.SYNOPSIS
  Create the missing deal for every contact at Prospect that is primary, has a company name,
  and has no opportunity. Requires -Execute; creates ONE unless told otherwise.

.DESCRIPTION
  Only PROSPECT_NO_DEAL is actioned here. The audit deliberately keeps two neighbouring classes
  out of it, and this script refuses them:

    NON_PRIMARY_PROSPECT   only the primary contact may own the account's deal. Creating one
                           for a second contact fragments the account into two "deals".
    PROSPECT_NO_COMPANY    mx_Custom_1 (Opportunity Name) is mandatory and would be blank.

  A create is now REVERSIBLE - deletion works (gotcha 47) - but it still fires the live
  Opportunity_Post_Create webhook into the Apps Script pipeline, so it is not free. Volumes
  here are ~100, well inside the UrlFetch budget (gotcha 27).

  The existence check re-runs LIVE immediately before each create, because the plan file may be
  hours old and Capture does not dedupe - it returns "IsUnique": true for a genuine duplicate.
  New-LsqOpportunity also cross-checks the activity trail, because GetOpportunitiesOfLead lags
  and reports 0 deals for leads that have one (gotcha 48).

.EXAMPLE
  powershell.exe -File scripts\remediation\02-create-missing-opportunities.ps1
  powershell.exe -File scripts\remediation\02-create-missing-opportunities.ps1 -Execute -MaxRecords 120

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31).
#>

param(
    [string]$PlanFile = "",
    [switch]$Execute,
    [int]$MaxRecords = 1,
    [int]$ThrottleMs = 300
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_cleanup_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$cfg     = Import-LsqConfig

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Create missing opportunities [$mode] ===" $logPath

if (-not $PlanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_cleanup_plan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No plan file found. Run scripts\reports\opportunity-hygiene-audit.ps1 first." }
    $PlanFile = $newest.FullName
}
$plan = Read-Utf8Json $PlanFile
$gaps = @($plan.Reconciliation | Where-Object { $_.Verdict -ne 'PASS' })
if ($gaps.Count -gt 0) { throw "Refusing to create against a plan whose reconciliation did not pass ($($gaps.Count) gap(s))." }

$targets = @($plan.Create)
Write-LsqLog "Plan file: $PlanFile" $logPath
Write-LsqLog "Contacts at Prospect with no deal: $($targets.Count)" $logPath
if ($targets.Count -eq 0) { Write-LsqLog "Nothing to do." $logPath; return }

if (-not $Execute) {
    Write-LsqLog "DRY RUN - nothing created. First 10:" $logPath
    foreach ($t in ($targets | Select-Object -First 10)) {
        Write-LsqLog ("    {0,-38} {1}" -f $t.CompanyName, $t.OwnerName) $logPath
    }
    Write-LsqLog "Re-run with -Execute. It will create ONE unless -MaxRecords is raised." $logPath
    return
}

$ckptPath    = Join-Path $dataDir "opportunity_create_checkpoint.txt"
$appliedPath = Join-Path $dataDir "opportunity_created_$stamp.json"

$done = @{}
if (Test-Path $ckptPath) { foreach ($l in (Get-Content $ckptPath)) { $t = $l.Trim(); if ($t) { $done[$t] = $true } } }
$queue = @($targets | Where-Object { -not $done.ContainsKey("$($_.ProspectId)") })
if ($queue.Count -eq 0) { Write-LsqLog "All targets already processed." $logPath; return }
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }
Write-LsqLog "Creating $($queue.Count) this run." $logPath

$created = New-Object System.Collections.Generic.List[object]
$ok = 0; $skipped = 0; $failed = 0
$isFirst = $true

foreach ($t in $queue) {
    $lid = "$($t.ProspectId)"
    if ([string]::IsNullOrWhiteSpace($t.CompanyName)) {
        $skipped++; Write-LsqLog "  SKIP $lid - blank company name, Opportunity Name is mandatory" $logPath; continue
    }
    try {
        # Owner is set at creation, which satisfies the owner-alignment rule for new deals
        # without needing a second write.
        $newId = New-LsqOpportunity -ProspectId $lid -OpportunityName "$($t.CompanyName)" `
            -Status "Open" -OppStage "Prospect" -OwnerId "$($t.OwnerId)" -Config $cfg `
            -Note "$($Script:OPP_CLEANUP_NOTE_PREFIX)-$stamp created for a Prospect-stage contact with no deal"

        if ($isFirst) {
            # Prove it, and prove there is exactly ONE - not two.
            Start-Sleep -Seconds 5
            $check = Confirm-LsqOpportunityWrite -OpportunityId $newId -MaxWaitSeconds 60 -Config $cfg `
                -Expected @{ Status = "Open"; mx_Custom_2 = "Prospect"; mx_Custom_1 = "$($t.CompanyName)" }
            if (-not $check.Ok) {
                throw "First create $newId did not read back as expected: $($check.Mismatches -join '; '). Stopping before record 2."
            }
            Write-LsqLog "  PROOF: $newId reads back Open/Prospect with the right name." $logPath
            $isFirst = $false
        }

        [void]$created.Add([pscustomobject]@{
            OpportunityId = $newId; ProspectId = $lid; Company = $t.CompanyName
            OwnerId = $t.OwnerId; OwnerName = $t.OwnerName; CreatedAtUtc = ([datetime]::UtcNow).ToString("s")
        })
        Add-Content -Path $ckptPath -Value $lid
        $ok++
    } catch {
        # New-LsqOpportunity throws rather than duplicating when a deal already exists - that
        # is a skip, not a failure.
        if ("$($_.Exception.Message)" -like "*already has*" -or "$($_.Exception.Message)" -like "*Refusing to create a duplicate*") {
            $skipped++
            Write-LsqLog "  SKIP $lid - a deal already exists: $($_.Exception.Message)" $logPath
            Add-Content -Path $ckptPath -Value $lid
        } else {
            $failed++
            Write-LsqLog "  FAIL $lid -> $($_.Exception.Message)" $logPath
            if ($isFirst) { throw "The first create of this run FAILED. Stopping." }
        }
    }
    if (($ok + $skipped + $failed) % 25 -eq 0) { Write-LsqLog "  created $ok, skipped $skipped, failed $failed" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

[pscustomobject]@{ Stamp=$stamp; PlanFile=$PlanFile; Created=$created.ToArray() } |
    ConvertTo-Json -Depth 6 | Set-Content -Path $appliedPath -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "=== create done: created=$ok skipped=$skipped failed=$failed ===" $logPath
Write-LsqLog "Created ids -> $appliedPath (delete them with Remove-LsqOpportunity if this was wrong)" $logPath
