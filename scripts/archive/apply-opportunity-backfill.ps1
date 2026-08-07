<#
.SYNOPSIS
  Phase 3, write step: for every Company at Stage=Opportunity or Stage=Customer, flag its
  primary-contact Lead (IsPrimaryContact=true) and create the corresponding Opportunity.

.DESCRIPTION
  Reads data/opportunity_backfill_worklist.json (built by
  build-opportunity-backfill-map.ps1 - primary contact = Lead with most recent
  ProspectActivityDate_Max under that Company, per Kaustubh's decision 2026-07-27).

  Two writes per company:
    1. Lead/Bulk/UpdateV2 - set IsPrimaryContact=true on the chosen Lead.
    2. OpportunityManagement.svc/Capture - create the Opportunity against that Lead.
       Company Stage=Customer -> Opportunity Status=Won, Stage="Payment Recieved"
       (matches the live account's actual stage value, typo included).
       Company Stage=Opportunity -> Opportunity Status=Open, Stage="Requirement Gathering"
       (the default open stage - reps update further as they work the deal).
       Owner is set explicitly to the Lead's current OwnerId so the Opportunity lands
       with the correct rep, not the API key's default owner.

  Smoke-tested and independently verified (GetOpportunityDetails + re-fetch of
  IsPrimaryContact) on one record before this script was written - see PROJECT_PLAN.md
  Phase 3.

.NOTES
  Run from repo root: pwsh ./scripts/leadsquared/apply-opportunity-backfill.ps1
#>

. "$PSScriptRoot\..\lib\common.ps1"
$cfg = Import-LsqConfig
$accessKey = $cfg['LSQ_ACCESS_KEY']
$secretKey = $cfg['LSQ_SECRET_KEY']
$base = $cfg['LSQ_API_HOST']

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_backfill_apply_log.txt"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

$worklist = Get-Content (Join-Path $dataDir "opportunity_backfill_worklist.json") -Raw | ConvertFrom-Json
Write-Log "=== Apply run started. Companies to backfill: $($worklist.Count) ==="

$primaryContactUrl = "$base/LeadManagement.svc/Lead/Bulk/UpdateV2?accessKey=$accessKey&secretKey=$secretKey"
$captureUrl = "$base/OpportunityManagement.svc/Capture?accessKey=$accessKey&secretKey=$secretKey"

$pcSuccess = 0; $pcFail = 0; $oppSuccess = 0; $oppFail = 0; $i = 0
foreach ($item in $worklist) {
    $i++

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

    if ($i % 100 -eq 0) { Write-Log "Apply progress: $i/$($worklist.Count)  primaryContact(success=$pcSuccess fail=$pcFail)  opportunity(success=$oppSuccess fail=$oppFail)" }
    Start-Sleep -Milliseconds 500
}
Write-Log "Apply DONE. primaryContact(success=$pcSuccess fail=$pcFail) opportunity(success=$oppSuccess fail=$oppFail) total=$($worklist.Count)"
Write-Log "=== Run complete ==="
