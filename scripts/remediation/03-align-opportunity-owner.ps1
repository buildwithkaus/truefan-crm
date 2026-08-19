<#
.SYNOPSIS
  Set each open deal's Owner to its contact's owner. Requires -Execute; one record unless
  told otherwise.

.DESCRIPTION
  The contact is the source of truth for ownership: leads get reassigned and the deal does not
  follow, so a deal can sit with a rep who no longer owns the account.

  SCOPED TO Status=Open ON PURPOSE. Changing the owner of a Won deal reassigns credit for
  closed business, which is a commercial decision and not a data-hygiene one.

  This is the most reversible write in the cleanup - it is a field value, the previous owner is
  recorded, and nothing is destroyed - so it runs FIRST, as the rehearsal that exercises the
  whole write path before anything irreversible happens.

  Whether Owner is writable via Update is proven per-run by the first record's read-back rather
  than assumed: probe P2 could not test it on every account shape.

.EXAMPLE
  powershell.exe -File scripts\remediation\03-align-opportunity-owner.ps1
  powershell.exe -File scripts\remediation\03-align-opportunity-owner.ps1 -Execute -MaxRecords 200

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
. "$PSScriptRoot\..\lib\opportunity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_cleanup_log.txt"
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$cfg     = Import-LsqConfig

function Read-Utf8Json { param([string]$Path) return ([IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))) | ConvertFrom-Json }

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "" $logPath
Write-LsqLog "=== Align opportunity owner to contact owner [$mode] ===" $logPath

if (-not $PlanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_cleanup_plan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No plan file found. Run scripts\reports\opportunity-hygiene-audit.ps1 first." }
    $PlanFile = $newest.FullName
}
$plan = Read-Utf8Json $PlanFile
$gaps = @($plan.Reconciliation | Where-Object { $_.Verdict -ne 'PASS' })
if ($gaps.Count -gt 0) { throw "Refusing to write against a plan whose reconciliation did not pass ($($gaps.Count) gap(s))." }

$targets = @($plan.Owner | Where-Object { $_.ToOwnerId })
Write-LsqLog "Owner mismatches on open deals: $($targets.Count)" $logPath
if ($targets.Count -eq 0) { Write-LsqLog "Nothing to do." $logPath; return }

if (-not $Execute) {
    Write-LsqLog "DRY RUN - nothing written. First 10:" $logPath
    foreach ($t in ($targets | Select-Object -First 10)) {
        Write-LsqLog ("    {0,-34} {1} -> {2}" -f $t.Company, $t.FromOwnerId, $t.ToOwnerName) $logPath
    }
    return
}

$ckptPath    = Join-Path $dataDir "opportunity_owner_checkpoint.txt"
$appliedPath = Join-Path $dataDir "opportunity_owner_realigned_$stamp.json"

$done = @{}
if (Test-Path $ckptPath) { foreach ($l in (Get-Content $ckptPath)) { $t = $l.Trim(); if ($t) { $done[$t] = $true } } }
$queue = @($targets | Where-Object { -not $done.ContainsKey("$($_.OpportunityId)") })
if ($queue.Count -eq 0) { Write-LsqLog "All targets already processed." $logPath; return }
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }
Write-LsqLog "Realigning $($queue.Count) this run." $logPath

$applied = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0
$isFirst = $true

foreach ($t in $queue) {
    $oid = "$($t.OpportunityId)"
    try {
        # $null = : Set-LsqOpportunity returns the API response, and an unassigned call emits it
        # to the pipeline, interleaving a status table through the log (gotcha 12 family).
        $null = Set-LsqOpportunity -OpportunityId $oid -Config $cfg `
            -Fields @{ Owner = "$($t.ToOwnerId)" } `
            -Note "$($Script:OPP_CLEANUP_NOTE_PREFIX)-$stamp owner realigned to the contact owner (was $($t.FromOwnerId))"

        if ($isFirst) {
            $c = Confirm-LsqOpportunityWrite -OpportunityId $oid -Expected @{ Owner = "$($t.ToOwnerId)" } -MaxWaitSeconds 90 -Config $cfg
            if (-not $c.Ok) {
                throw "Owner is NOT writable via Update on this account: $($c.Mismatches -join '; '). Stopping - OWNER_MISMATCH must stay report-only."
            }
            Write-LsqLog "  PROOF: $oid owner now $($c.Observed['Owner']) (waited $($c.WaitedSeconds)s)." $logPath
            $isFirst = $false
        }

        [void]$applied.Add([pscustomobject]@{
            OpportunityId = $oid; ProspectId = $t.ProspectId; Company = $t.Company
            FromOwnerId = $t.FromOwnerId; ToOwnerId = $t.ToOwnerId
            AppliedAtUtc = ([datetime]::UtcNow).ToString("s")
        })
        Add-Content -Path $ckptPath -Value $oid
        $ok++
    } catch {
        $failed++
        Write-LsqLog "  FAIL $oid -> $($_.Exception.Message)" $logPath
        if ($isFirst) { throw "The first owner write of this run FAILED. Stopping." }
    }
    if (($ok + $failed) % 50 -eq 0) { Write-LsqLog "  realigned $ok, failed $failed" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

[pscustomobject]@{ Stamp=$stamp; PlanFile=$PlanFile; Realigned=$applied.ToArray() } |
    ConvertTo-Json -Depth 6 | Set-Content -Path $appliedPath -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "=== owner alignment done: ok=$ok failed=$failed ===" $logPath
Write-LsqLog "Previous owners recorded -> $appliedPath" $logPath
