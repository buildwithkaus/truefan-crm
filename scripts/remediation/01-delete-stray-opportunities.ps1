<#
.SYNOPSIS
  Delete opportunities that should not exist. Backs up every field of each deal IMMEDIATELY
  before deleting it. Requires -Execute; deletes ONE record unless told otherwise.

.DESCRIPTION
  Deletion is real and irreversible (gotcha 47) - there is no undelete and no recycle bin.
  Everything in this script exists to make that defensible:

    backup-then-delete, per record   Each deal's 29 fields are read via GetOpportunityDetails
                                     and appended to the applied-file BEFORE the delete call.
                                     A deal whose detail read fails is SKIPPED, not deleted -
                                     it is the one record that could not be restored.
    one record, then re-fetch        The first delete of every invocation is proven gone by an
                                     independent read, and the contact is checked for a stage
                                     cascade, before a second record is touched.
    checkpoint AFTER confirmation    Never before. A checkpoint written first turns a failed
                                     batch into a permanent, silent hole in the run.
    -MaxRecords defaults to 1        An unthinking -Execute deletes one deal, not two thousand.

  CLASSES IT REFUSES
    DEAL_EVER_PROSPECT_UNKNOWN  the trail could not say whether this was ever a real deal.
                                Deleting on "we could not tell" is how history gets destroyed.
    DEAL_ON_ENGAGED             the contact is a live account a rep is mid-conversation on.
                                2,327 of the 3,345 strays - 70% of the delete list - so it is
                                reviewed on its own rather than swept along with the rest.

  THE WAREHOUSE WILL NOT NOTICE
  No Opportunity_Post_Delete webhook is registered (verified 2026-08-14), which is why bulk
  deletion is quota-safe - but it also means fact_opportunity keeps every deleted row. Run
  scripts\remediation\98-reconcile-warehouse.ps1 afterwards or the deal book stays wrong.

.EXAMPLE
  powershell.exe -File scripts\remediation\01-delete-stray-opportunities.ps1 -PlanFile data\opportunity_cleanup_plan_X.json -IssueClass DUPLICATE_DEAL
  powershell.exe -File scripts\remediation\01-delete-stray-opportunities.ps1 -PlanFile ... -IssueClass DUPLICATE_DEAL -Execute
  powershell.exe -File scripts\remediation\01-delete-stray-opportunities.ps1 -PlanFile ... -IssueClass DUPLICATE_DEAL -Execute -MaxRecords 250

.NOTES
  ASCII only. Windows PowerShell 5.1 (gotcha 31).
  Documented delete rate limit is 25 calls / 5 s - do not drop ThrottleMs below 200.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('DEAL_ON_NEVER_PROSPECT','DEAL_ON_LAPSED_PROSPECT','DUPLICATE_DEAL','DEAL_ON_ENGAGED')]
    [string]$IssueClass,

    [string]$PlanFile = "",
    [switch]$Execute,
    [int]$MaxRecords = 1,
    [int]$ThrottleMs = 250,
    [switch]$IAcceptDeletingLiveAccounts   # required for DEAL_ON_ENGAGED
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
Write-LsqLog "=== Delete stray opportunities [$IssueClass] [$mode] ===" $logPath

if ($IssueClass -eq 'DEAL_ON_ENGAGED' -and $Execute -and -not $IAcceptDeletingLiveAccounts) {
    throw @"
DEAL_ON_ENGAGED deletes deals on contacts that are currently ENGAGED - live accounts reps are
mid-conversation on, and 70% of the whole delete list. That may well be right, but it is not
the same decision as clearing migration debris off Disqualified contacts, and it should not
ride along in the same run.

Re-run with -IAcceptDeletingLiveAccounts once that call has been made.
"@
}

if (-not $PlanFile) {
    $newest = Get-ChildItem (Join-Path $dataDir "opportunity_cleanup_plan_*.json") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No plan file found. Run scripts\reports\opportunity-hygiene-audit.ps1 first." }
    $PlanFile = $newest.FullName
}
$plan = Read-Utf8Json $PlanFile
Write-LsqLog "Plan file: $PlanFile (generated $($plan.GeneratedAtUtc) UTC)" $logPath

# The plan is only actionable if the audit's own gates passed.
$gaps = @($plan.Reconciliation | Where-Object { $_.Verdict -ne 'PASS' })
if ($gaps.Count -gt 0) {
    Write-LsqLog "Plan reconciliation has $($gaps.Count) unresolved gap(s):" $logPath
    foreach ($g in $gaps) { Write-LsqLog "    $($g.Check): expected $($g.Expected), actual $($g.Actual) - $($g.Note)" $logPath }
    throw "Refusing to delete against a plan whose reconciliation did not pass."
}

$targets = @($plan.Delete | Where-Object { $_.Class -eq $IssueClass })
Write-LsqLog "Targets in class $IssueClass : $($targets.Count)" $logPath
if ($targets.Count -eq 0) { Write-LsqLog "Nothing to do." $logPath; return }

$byStage = $targets | Group-Object ContactStage | Sort-Object Count -Descending
Write-LsqLog "  by contact stage:" $logPath
foreach ($g in $byStage) { Write-LsqLog ("    {0,-18} {1}" -f $g.Name, $g.Count) $logPath }

if (-not $Execute) {
    Write-LsqLog "" $logPath
    Write-LsqLog "DRY RUN - nothing deleted. First 10 targets:" $logPath
    foreach ($t in ($targets | Select-Object -First 10)) {
        Write-LsqLog ("    {0}  {1,-16} {2,-14} {3}" -f $t.OpportunityId, $t.OppStage, $t.ContactStage, $t.Company) $logPath
    }
    Write-LsqLog "" $logPath
    Write-LsqLog "Re-run with -Execute. It will delete ONE record unless -MaxRecords is raised." $logPath
    return
}

$ckptPath    = Join-Path $dataDir "opportunity_delete_checkpoint_$IssueClass.txt"
$appliedPath = Join-Path $dataDir "opportunity_deleted_$IssueClass`_$stamp.json"

$done = @{}
if (Test-Path $ckptPath) {
    foreach ($line in (Get-Content $ckptPath)) { $t = $line.Trim(); if ($t) { $done[$t] = $true } }
    Write-LsqLog "Checkpoint holds $($done.Count) already-deleted id(s)." $logPath
}

$queue = @($targets | Where-Object { -not $done.ContainsKey("$($_.OpportunityId)") })
if ($queue.Count -eq 0) { Write-LsqLog "All targets already processed." $logPath; return }
if ($MaxRecords -gt 0 -and $queue.Count -gt $MaxRecords) { $queue = $queue[0..($MaxRecords-1)] }
Write-LsqLog "Deleting $($queue.Count) this run (of $($targets.Count) in class)." $logPath

$applied = New-Object System.Collections.Generic.List[object]
$ok = 0; $skipped = 0; $failed = 0
$isFirst = $true

foreach ($t in $queue) {
    $oid = "$($t.OpportunityId)"
    $lid = "$($t.ProspectId)"

    # --- 1. back it up BEFORE deleting. No backup, no delete. ---------------------------
    $backup = $null
    try {
        $det = Get-LsqOpportunityDetails -OpportunityId $oid -Config $cfg
        $flat = @{}
        foreach ($k in $det.Fields.Keys) { $flat[$k] = $det.Fields[$k].Value }
        $backup = [pscustomobject]@{
            OpportunityId = $oid; ProspectId = $det.ProspectId
            Class = $IssueClass; Note = $det.Note
            ContactStage = $t.ContactStage; Company = $t.Company; Rep = $t.Rep
            EverProspect = $t.EverProspect; Evidence = $t.Evidence
            Fields = $flat
            DeletedAtUtc = ([datetime]::UtcNow).ToString("s")
        }
    } catch {
        $skipped++
        Write-LsqLog "  SKIP $oid - detail read failed, so it cannot be restored: $($_.Exception.Message)" $logPath
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }

    # Flush the backup to disk BEFORE the delete, not after. A crash between the two must
    # leave a recoverable record, not a deleted deal with no trace.
    [void]$applied.Add($backup)
    [pscustomobject]@{ Stamp=$stamp; Class=$IssueClass; PlanFile=$PlanFile; Deleted=$applied.ToArray() } |
        ConvertTo-Json -Depth 8 | Set-Content -Path $appliedPath -Encoding UTF8

    # --- 2. contact stage before, so a cascade is detectable ----------------------------
    $stageBefore = $null
    try {
        $lr = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
        if ($lr.Count -gt 0) { $stageBefore = "$($lr[0].ProspectStage)" }
    } catch { }

    # --- 3. delete ----------------------------------------------------------------------
    try {
        # $null = : the API response would otherwise print a status table through the log.
        $null = Remove-LsqOpportunity -OpportunityId $oid -Config $cfg
    } catch {
        $failed++
        Write-LsqLog "  FAIL $oid -> $($_.Exception.Message)" $logPath
        if ($isFirst) { throw "The first delete of this run FAILED. Stopping before touching anything else." }
        Start-Sleep -Milliseconds $ThrottleMs
        continue
    }

    # --- 4. prove it, on the first record of every run ----------------------------------
    if ($isFirst) {
        $gone = Confirm-LsqOpportunityRemoved -OpportunityId $oid -MaxWaitSeconds 45 -Config $cfg
        if (-not $gone) {
            throw "Delete of $oid reported success but the record still reads back. Stopping before record 2 - the API's success response cannot be trusted here."
        }
        Write-LsqLog "  PROOF: $oid confirmed gone by an independent read." $logPath

        # The cascade guard. No Opportunity_Post_Delete webhook is registered and no scheduled
        # sync runs, so this should never fire - but "should" is what the 2026-08-11
        # over-disqualification was built on.
        if ($stageBefore) {
            Start-Sleep -Seconds 20
            $stageAfter = $null
            try {
                $lr2 = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectID"; LookupValue=$lid; SqlOperator="=" } -ColumnsCsv "ProspectID,ProspectStage" -PageSize 1))
                if ($lr2.Count -gt 0) { $stageAfter = "$($lr2[0].ProspectStage)" }
            } catch { }
            if ($stageAfter -and $stageAfter -ne $stageBefore) {
                throw "CASCADE DETECTED: contact $lid moved '$stageBefore' -> '$stageAfter' after its deal was deleted. STOP. Disable the automation before deleting anything else."
            }
            Write-LsqLog "  GUARD: contact $lid still '$stageBefore' after the delete - no cascade." $logPath
        }
        $isFirst = $false
    }

    # --- 5. checkpoint only now that it is confirmed ------------------------------------
    Add-Content -Path $ckptPath -Value $oid
    $ok++
    if ($ok % 50 -eq 0) { Write-LsqLog "  deleted $ok/$($queue.Count) (skipped $skipped, failed $failed)" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

[pscustomobject]@{ Stamp=$stamp; Class=$IssueClass; PlanFile=$PlanFile; Deleted=$applied.ToArray() } |
    ConvertTo-Json -Depth 8 | Set-Content -Path $appliedPath -Encoding UTF8

Write-LsqLog "" $logPath
Write-LsqLog "=== $IssueClass done: deleted=$ok skipped=$skipped failed=$failed ===" $logPath
Write-LsqLog "Backup of every deleted record -> $appliedPath" $logPath
if ($skipped -gt 0) { Write-LsqLog "$skipped deal(s) were NOT deleted because their fields could not be read first." $logPath }
Write-LsqLog "" $logPath
Write-LsqLog "The warehouse still holds these rows - no delete webhook exists. Run:" $logPath
Write-LsqLog "  scripts\remediation\98-reconcile-warehouse.ps1" $logPath
