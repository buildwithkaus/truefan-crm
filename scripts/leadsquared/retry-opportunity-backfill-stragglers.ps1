<#
.SYNOPSIS
  Retry pass for the 124 companies the main resume run (resume-opportunity-backfill.ps1)
  couldn't finish: 118 hit a transient DNS/connection blip on the existence-check itself
  (never attempted a write), 2 more hit the same blip mid-write (existence-check passed,
  then IsPrimaryContact and/or Opportunity creation failed), and 4 hit a genuine (non-transient)
  400 Bad Request caused by a UTF-8 body-encoding bug - see .NOTES.

.DESCRIPTION
  Reads data/opportunity_backfill_stragglers.json (124 companies, a subset of the full
  4,404-company worklist). Same check-before-create logic as resume-opportunity-backfill.ps1:
  skip if GetOpportunitiesOfLead already shows a record (covers the case where a "failed"
  write actually landed server-side), otherwise set IsPrimaryContact and create the
  Opportunity.

.NOTES
  Root cause of the 4 genuine failures: all 4 have non-ASCII characters in CompanyName
  (deg symbol, accented E/e, registered-trademark symbol - e.g. "360 deg Career Institute",
  "BodyCafe", "SHAFAQUE (R)"). Windows PowerShell 5.1's Invoke-RestMethod, given a .NET
  string body and -ContentType "application/json" with no charset, does not reliably send
  UTF-8 bytes on the wire - the non-ASCII character became a single stray byte the server's
  UTF-8 JSON parser couldn't decode, producing "Unexpected character encountered while
  parsing value" errors. Fix: convert the JSON string to explicit UTF-8 bytes before
  sending, and set charset=utf-8 on the Content-Type header. Smoke-tested on one of the
  4 real failures before this script was run at scale - see PROJECT_PLAN.md Phase 3.

  Run from repo root: pwsh ./scripts/leadsquared/retry-opportunity-backfill-stragglers.ps1
#>

. "$PSScriptRoot\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_backfill_stragglers_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

# UTF-8-safe POST - fixes the encoding bug described in .NOTES above.
function Invoke-LsqPostUtf8 {
    param([string]$Uri, [string]$JsonBody)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
    return Invoke-RestMethod -Uri $Uri -Method Post -Body $bytes -ContentType "application/json; charset=utf-8"
}

$worklist = Get-Content (Join-Path $dataDir "opportunity_backfill_stragglers.json") -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Log "=== Straggler retry started. Worklist: $($worklist.Count) companies ==="

$primaryContactUrl = "$base/LeadManagement.svc/Lead/Bulk/UpdateV2?accessKey=$accessKey&secretKey=$secretKey"
$captureUrl = "$base/OpportunityManagement.svc/Capture?accessKey=$accessKey&secretKey=$secretKey"

$skipped = 0; $pcSuccess = 0; $pcFail = 0; $oppSuccess = 0; $oppFail = 0; $i = 0
foreach ($item in $worklist) {
    $i++

    $checkUrl = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$accessKey&secretKey=$secretKey&leadId=$($item.ProspectId)&opportunityType=12000"
    try {
        $existing = Invoke-RestMethod -Uri $checkUrl -Method Post -ContentType "application/json"
        Start-Sleep -Milliseconds 350
        if ($existing.RecordCount -gt 0) {
            $skipped++
            Write-Log "Company $($item.CompanyId) ($($item.CompanyName)): already has an Opportunity, skipping"
            continue
        }
    } catch {
        Write-Log "Company $($item.CompanyId) ($($item.CompanyName)): existence-check EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message) - skipping this record this pass, retry later"
        Start-Sleep -Milliseconds 350
        continue
    }

    $body1 = @{ SearchByKey = "ProspectId"; Options = @{ PushNonExistentLeadsToUnProcessedList = $true }; LeadPropertiesList = @(@(@{ Fields = @(
        @{ Attribute = "ProspectId"; Value = $item.ProspectId },
        @{ Attribute = "IsPrimaryContact"; Value = "true" }
    ) })) } | ConvertTo-Json -Depth 6
    try {
        $r1 = Invoke-LsqPostUtf8 -Uri $primaryContactUrl -JsonBody $body1
        if ($r1.Status.SuccessCount -gt 0) { $pcSuccess++ } else { $pcFail++; Write-Log "Company $($item.CompanyId): IsPrimaryContact FAILURE -> $($r1 | ConvertTo-Json -Compress)" }
    } catch {
        $pcFail++
        Write-Log "Company $($item.CompanyId): IsPrimaryContact EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)"
    }
    Start-Sleep -Milliseconds 350

    $status = if ($item.Stage -eq "Customer") { "Won" } else { "Open" }
    $stageVal = if ($item.Stage -eq "Customer") { "Payment Recieved" } else { "Requirement Gathering" }
    $oppBody = @{
        LeadDetails = @(
            @{ Attribute = "ProspectID"; Value = $item.ProspectId },
            @{ Attribute = "SearchBy"; Value = "ProspectId" },
            @{ Attribute = "__UseUserDefinedGuid__"; Value = "true" }
        )
        Opportunity = @{
            OpportunityEventCode = 12000
            OpportunityNote = "Backfilled from existing Company.Stage=$($item.Stage) - Phase 3 migration (straggler retry)"
            UpdateEmptyFields = $true
            DoNotPostDuplicateActivity = $false
            DoNotChangeOwner = $false
            Fields = @(
                @{ SchemaName = "Status"; Value = $status },
                @{ SchemaName = "mx_Custom_1"; Value = $item.CompanyName },
                @{ SchemaName = "mx_Custom_2"; Value = $stageVal },
                @{ SchemaName = "Owner"; Value = $item.OwnerId }
            )
        }
    } | ConvertTo-Json -Depth 6
    try {
        $r2 = Invoke-LsqPostUtf8 -Uri $captureUrl -JsonBody $oppBody
        if ($r2.Status -eq 0 -and $r2.CreatedOpportunityId) { $oppSuccess++ } else { $oppFail++; Write-Log "Company $($item.CompanyId): Opportunity FAILURE -> $($r2 | ConvertTo-Json -Compress)" }
    } catch {
        $oppFail++
        Write-Log "Company $($item.CompanyId): Opportunity EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)"
    }

    Write-Log "Progress: $i/$($worklist.Count)  skipped=$skipped pc(success=$pcSuccess fail=$pcFail) opp(success=$oppSuccess fail=$oppFail)"
    Start-Sleep -Milliseconds 700
}
Write-Log "Straggler retry DONE. skipped=$skipped pc(success=$pcSuccess fail=$pcFail) opp(success=$oppSuccess fail=$oppFail) total=$($worklist.Count)"
Write-Log "=== Run complete ==="
