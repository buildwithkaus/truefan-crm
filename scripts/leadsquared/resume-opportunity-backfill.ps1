<#
.SYNOPSIS
  Resume Phase 3's Opportunity backfill after the duplicate-Opportunity discovery
  (see PROJECT_PLAN.md Phase 3 / memory notes). Checks GetOpportunitiesOfLead for each
  company's chosen Lead BEFORE creating - the Capture API does not dedupe on its own
  (confirmed: "IsUnique":true was returned even for a genuine duplicate), so a blind
  re-run of the full worklist would create a second Opportunity for every company
  already processed.

.DESCRIPTION
  Reads data/opportunity_backfill_worklist.json (4,404 companies). For each one:
    1. Check GetOpportunitiesOfLead?leadId=X&opportunityType=12000 - if RecordCount > 0,
       skip (already has an Opportunity, whether or not the original run logged it as a
       success - a prior run's "EXCEPTION" can still mean the write landed and only the
       response was lost, see the RGSF SOLUTIONS case in PROJECT_PLAN.md).
    2. If not, set IsPrimaryContact=true (idempotent - harmless to re-set even if already
       true) and create the Opportunity.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/resume-opportunity-backfill.ps1
#>

. "$PSScriptRoot\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_backfill_resume_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

$worklist = Get-Content (Join-Path $dataDir "opportunity_backfill_worklist.json") -Raw | ConvertFrom-Json
Write-Log "=== Resume run started. Worklist: $($worklist.Count) companies ==="

$primaryContactUrl = "$base/LeadManagement.svc/Lead/Bulk/UpdateV2?accessKey=$accessKey&secretKey=$secretKey"
$captureUrl = "$base/OpportunityManagement.svc/Capture?accessKey=$accessKey&secretKey=$secretKey"

$skipped = 0; $pcSuccess = 0; $pcFail = 0; $oppSuccess = 0; $oppFail = 0; $i = 0
foreach ($item in $worklist) {
    $i++

    # Check-before-create
    $checkUrl = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$accessKey&secretKey=$secretKey&leadId=$($item.ProspectId)&opportunityType=12000"
    try {
        $existing = Invoke-RestMethod -Uri $checkUrl -Method Post -ContentType "application/json"
        Start-Sleep -Milliseconds 350
        if ($existing.RecordCount -gt 0) {
            $skipped++
            if ($i % 200 -eq 0) { Write-Log "Progress: $i/$($worklist.Count)  skipped=$skipped pc(success=$pcSuccess fail=$pcFail) opp(success=$oppSuccess fail=$oppFail)" }
            continue
        }
    } catch {
        Write-Log "Company $($item.CompanyId): existence-check EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message) - skipping this record this pass, retry later"
        Start-Sleep -Milliseconds 350
        continue
    }

    # Step 1: IsPrimaryContact
    $body1 = @{ SearchByKey = "ProspectId"; Options = @{ PushNonExistentLeadsToUnProcessedList = $true }; LeadPropertiesList = @(@(@{ Fields = @(
        @{ Attribute = "ProspectId"; Value = $item.ProspectId },
        @{ Attribute = "IsPrimaryContact"; Value = "true" }
    ) })) } | ConvertTo-Json -Depth 6
    try {
        $r1 = Invoke-RestMethod -Uri $primaryContactUrl -Method Post -Body $body1 -ContentType "application/json"
        if ($r1.Status.SuccessCount -gt 0) { $pcSuccess++ } else { $pcFail++; Write-Log "Company $($item.CompanyId): IsPrimaryContact FAILURE -> $($r1 | ConvertTo-Json -Compress)" }
    } catch {
        $pcFail++
        Write-Log "Company $($item.CompanyId): IsPrimaryContact EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)"
    }
    Start-Sleep -Milliseconds 350

    # Step 2: create Opportunity
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
            OpportunityNote = "Backfilled from existing Company.Stage=$($item.Stage) - Phase 3 migration"
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
        $r2 = Invoke-RestMethod -Uri $captureUrl -Method Post -Body $oppBody -ContentType "application/json"
        if ($r2.Status -eq 0 -and $r2.CreatedOpportunityId) { $oppSuccess++ } else { $oppFail++; Write-Log "Company $($item.CompanyId): Opportunity FAILURE -> $($r2 | ConvertTo-Json -Compress)" }
    } catch {
        $oppFail++
        Write-Log "Company $($item.CompanyId): Opportunity EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)"
    }

    if ($i % 100 -eq 0) { Write-Log "Progress: $i/$($worklist.Count)  skipped=$skipped pc(success=$pcSuccess fail=$pcFail) opp(success=$oppSuccess fail=$oppFail)" }
    Start-Sleep -Milliseconds 700
}
Write-Log "Resume DONE. skipped=$skipped pc(success=$pcSuccess fail=$pcFail) opp(success=$oppSuccess fail=$oppFail) total=$($worklist.Count)"
Write-Log "=== Run complete ==="
