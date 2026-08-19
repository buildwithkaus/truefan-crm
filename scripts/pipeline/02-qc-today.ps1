<#
.SYNOPSIS
  QC the calling pipeline against the live LeadSquared API. Read-only.

.DESCRIPTION
  Answers, with real numbers, the only question that matters when a report looks wrong:
  is the pipeline undercounting, and by how much?

  It reproduces the SAME filter a human would apply in the LSQ UI - last activity type is a
  phone call, last activity date is today - so the contact count here is directly comparable
  to what you see on screen. It then pulls those contacts' trails to count actual CALLS
  (a contact can be dialled many times), and splits them at the webhook cutover so
  "the webhook only captures forward" can be separated from "the webhook is broken".

  Also smoke-tests Leads.GetById, which the Apps Script enrichment depends on. If that
  endpoint does not work, the Leads tab stays empty, every contact stage reads blank, and
  the Prospects tab and most hygiene flags silently produce nothing - which looks like a
  reporting bug but is an enrichment bug.

.PARAMETER CutoverIst
  When the webhook went live, IST. Calls before this were never delivered and must be
  backfilled; they are not evidence of a fault.

.EXAMPLE
  pwsh ./scripts/pipeline/02-qc-today.ps1
  pwsh ./scripts/pipeline/02-qc-today.ps1 -TargetDate 2026-08-08 -CutoverIst "2026-08-08 11:51"
#>

[CmdletBinding()]
param(
    [string]$TargetDate = (Get-Date).ToString("yyyy-MM-dd"),
    [string]$CutoverIst = "2026-08-08 11:51",
    [int]$SleepMs = 220,
    [int]$MaxContacts = 1200
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "pipeline_qc_log.txt"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

Write-LsqLog "=== QC for $TargetDate (run $stamp) ===" $logPath

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

$inv = [System.Globalization.CultureInfo]::InvariantCulture
$dayIst = [datetime]::ParseExact($TargetDate, "yyyy-MM-dd", $inv)
$dayStartUtc = $dayIst.AddHours(-5).AddMinutes(-30)
$dayEndUtc = $dayStartUtc.AddDays(1)
$cutoverUtc = ([datetime]::ParseExact($CutoverIst, "yyyy-MM-dd HH:mm", $inv)).AddHours(-5).AddMinutes(-30)

Write-LsqLog "IST day  : $TargetDate" $logPath
Write-LsqLog "UTC range: $($dayStartUtc.ToString('yyyy-MM-dd HH:mm:ss')) .. $($dayEndUtc.ToString('yyyy-MM-dd HH:mm:ss'))" $logPath
Write-LsqLog "Cutover  : $CutoverIst IST = $($cutoverUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC" $logPath

# =======================================================================================
# 0. Does Leads.GetById work? The Apps Script enrichment stands or falls on this.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- 0. Leads.GetById smoke test (enrichment depends on it) ---" $logPath

$probe = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "ProspectActivityDate_Max"; LookupValue = (Get-LsqTimestamp ((Get-Date).AddDays(-2))); SqlOperator = ">"
} -ColumnsCsv "ProspectID,OwnerIdName" -PageSize 1 -SortColumn "CreatedOn"))

if ($probe.Count -eq 0) {
    Write-LsqLog "  could not find a lead to probe with - skipping" $logPath
} else {
    $pid0 = $probe[0].ProspectID
    $u = "$base/LeadManagement.svc/Leads.GetById" + "?accessKey=$ak&secretKey=$sk&id=$pid0"
    try {
        $r = Invoke-RestMethod -Uri $u -Method Get -ErrorAction Stop
        # @() around the call is MANDATORY. Expand-LsqRows returns .ToArray() with no leading
        # comma, so PowerShell unrolls a single-element result into a bare object and .Count
        # then reads blank - which made an earlier version of this script report
        # "200 but ZERO rows" for an endpoint that was working perfectly.
        $rows = @(Expand-LsqRows $r)
        if ($rows.Count -gt 0) {
            $l = $rows[0]
            Write-LsqLog "  WORKS - returned $($rows.Count) row(s)" $logPath
            Write-LsqLog "    OwnerIdName        = [$($l.OwnerIdName)]" $logPath
            Write-LsqLog "    ProspectStage      = [$($l.ProspectStage)]" $logPath
            Write-LsqLog "    mx_Call_Disposition= [$($l.mx_Call_Disposition)]" $logPath
            Write-LsqLog "    Company            = [$($l.Company)]" $logPath
        } else {
            Write-LsqLog "  *** RETURNED 200 BUT ZERO ROWS - enrichment will silently produce nothing ***" $logPath
        }
    } catch {
        $m = $_.ErrorDetails.Message; if (-not $m) { $m = $_.Exception.Message }
        Write-LsqLog "  *** FAILED: $m ***" $logPath
        Write-LsqLog "  Enrichment cannot work. The Leads tab stays empty, every stage reads blank," $logPath
        Write-LsqLog "  Prospects stays empty, and most hygiene flags never fire." $logPath
    }
}

# =======================================================================================
# 1. Reproduce the LSQ UI filter: last activity is a phone call, today.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- 1. Contacts whose LAST activity is a call, today (matches the UI filter) ---" $logPath

$sinceUtc = $dayStartUtc.ToString("yyyy-MM-dd HH:mm:ss")
$cols = "ProspectID,OwnerId,OwnerIdName,ProspectStage,mx_Call_Disposition,ProspectActivityDate_Max,ProspectActivityName_Max"

function Get-ContactsByLastActivity {
    <#
      PURE - returns rows, logs nothing.

      Filters on ProspectActivityDate_Max (server side, cheap) and then keeps only rows
      whose last activity NAME is the one asked for. The reverse - filtering on the name and
      paging forward looking for today's dates - does not work: there are tens of thousands
      of leads whose last activity is an outbound call, and sorted by CreatedOn today's
      callers are scattered anywhere in that set. An earlier version did exactly that,
      capped at 60 pages, and reported zero.
    #>
    param([string]$ActivityName, [Parameter(Mandatory)][datetime]$SinceUtc, [string]$Cols)
    $out = New-Object System.Collections.Generic.List[object]
    $page = 1
    while ($true) {
        $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
            LookupName = "ProspectActivityDate_Max"
            LookupValue = $SinceUtc.ToString("yyyy-MM-dd HH:mm:ss")
            SqlOperator = ">"
        } -ColumnsCsv $Cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
        if ($rows.Count -eq 0) { break }
        foreach ($r in $rows) {
            if ("$($r.ProspectActivityName_Max)" -eq $ActivityName) { [void]$out.Add($r) }
        }
        if ($rows.Count -lt 1000) { break }
        $page++
        if ($page -gt 60) { break }
    }
    return $out.ToArray()
}

$contacts = New-Object System.Collections.Generic.List[object]
foreach ($name in $Script:CallActivityNames) {
    $found = @(Get-ContactsByLastActivity -ActivityName $name -SinceUtc $dayStartUtc -Cols $cols)
    Write-LsqLog ("  {0,-32} {1,5} contacts" -f $name, $found.Count) $logPath
    foreach ($f in $found) { [void]$contacts.Add($f) }
}
$contactArr = $contacts.ToArray()
Write-LsqLog "  TOTAL contacts whose last activity is a call today: $($contactArr.Count)" $logPath
Write-LsqLog "  (this is the number directly comparable to the LSQ UI filter)" $logPath

# =======================================================================================
# 2. Pull trails and count actual CALLS. A contact can be dialled many times.
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "--- 2. Actual calls today, from the activity trails ---" $logPath

$scan = $contactArr
if ($scan.Count -gt $MaxContacts) {
    Write-LsqLog "  *** LIMITED to $MaxContacts of $($scan.Count) contacts - numbers below are a FLOOR, not the total ***" $logPath
    $scan = $scan[0..($MaxContacts - 1)]
}

$byRep = @{}
$totalCalls = 0; $beforeCut = 0; $afterCut = 0; $connected = 0
$ok = 0; $failed = 0

foreach ($c in $scan) {
    try {
        $acts = Get-LeadActivities -ProspectId $c.ProspectID -Config $cfg
        $ok++
    } catch { $failed++; continue }

    foreach ($a in $acts) {
        if ("$($a.EventCode)" -ne "22") { continue }
        $when = ConvertFrom-LsqUtc "$($a.CreatedOn)"
        if ($null -eq $when -or $when -lt $dayStartUtc -or $when -ge $dayEndUtc) { continue }

        $totalCalls++
        if ($when -lt $cutoverUtc) { $beforeCut++ } else { $afterCut++ }
        $dur = Get-LsqCallDuration $a
        if ($dur -gt 0) { $connected++ }

        $rep = Get-CallNoteValue -Blob "$($a.ActivityFields.ActivityEvent_Note)" -Key "Caller"
        if (-not $rep) { $rep = "$($c.OwnerIdName)" }
        if (-not $byRep.ContainsKey($rep)) {
            $byRep[$rep] = [pscustomobject]@{ Total = 0; Before = 0; After = 0; Conn = 0 }
        }
        $byRep[$rep].Total++
        if ($when -lt $cutoverUtc) { $byRep[$rep].Before++ } else { $byRep[$rep].After++ }
        if ($dur -gt 0) { $byRep[$rep].Conn++ }
    }
    Start-Sleep -Milliseconds $SleepMs
}

Write-LsqLog "  trails fetched: $ok ok, $failed failed" $logPath
Write-LsqLog "" $logPath
Write-LsqLog ("  {0,-26} {1,7} {2,8} {3,8} {4,7}" -f "Rep (from call record)", "Calls", "PreCut", "PostCut", "Conn") $logPath
Write-LsqLog ("  " + ("-" * 62)) $logPath
$byRep.GetEnumerator() | Sort-Object { $_.Value.Total } -Descending | ForEach-Object {
    Write-LsqLog ("  {0,-26} {1,7} {2,8} {3,8} {4,7}" -f $_.Name, $_.Value.Total, $_.Value.Before, $_.Value.After, $_.Value.Conn) $logPath
}
Write-LsqLog ("  " + ("-" * 62)) $logPath
Write-LsqLog ("  {0,-26} {1,7} {2,8} {3,8} {4,7}" -f "TOTAL", $totalCalls, $beforeCut, $afterCut, $connected) $logPath

# =======================================================================================
# 3. Verdict
# =======================================================================================
Write-LsqLog "" $logPath
Write-LsqLog "=== VERDICT ===" $logPath
Write-LsqLog "  Calls today (LSQ truth)          : $totalCalls" $logPath
Write-LsqLog "  Before webhook cutover           : $beforeCut  <- never delivered, needs BACKFILL" $logPath
Write-LsqLog "  After  webhook cutover           : $afterCut  <- the Sheet SHOULD hold these" $logPath
Write-LsqLog "" $logPath
Write-LsqLog "  Compare 'after cutover' against the Consolidated tab's total for $TargetDate." $logPath
Write-LsqLog "    match      -> the webhook is healthy; the shortfall is purely missing history." $logPath
Write-LsqLog "    sheet LOW  -> the webhook is dropping events. Check -Action List for a disabled" $logPath
Write-LsqLog "                  hook, the Unparsed tab, and the Apps Script executions log." $logPath
Write-LsqLog "    sheet HIGH -> duplicates; the ActivityId dedupe is not working." $logPath
Write-LsqLog "" $logPath
Write-LsqLog "Log: $logPath" $logPath
