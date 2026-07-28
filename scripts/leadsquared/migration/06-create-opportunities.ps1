<#
.SYNOPSIS
  Creates an Opportunity for every account whose primary contact lands on Prospect or
  Customer, and sets IsPrimaryContact on that lead.

.DESCRIPTION
  Two hard-won rules are enforced here:

  1. CHECK BEFORE CREATE. OpportunityManagement.svc/Capture does NOT dedupe - it returns
     "IsUnique": true even for a genuine duplicate. A blind re-run creates a second
     Opportunity for every account already processed. Every record is therefore checked
     against GetOpportunitiesOfLead first (the opportunityType parameter is REQUIRED, not
     optional as the docs imply).

  2. Stage lives in mx_Custom_2, a dependent dropdown under the native Status field. Status
     itself is fixed to Open/Won/Lost and is shown to reps as "Deal Stage". Writing a stage
     name into Status will fail.

  Idempotent and resumable. Safe to re-run: anything that already has an Opportunity is
  skipped.

.PARAMETER Execute
  Required to write.

.NOTES
  pwsh ./scripts/leadsquared/migration/06-create-opportunities.ps1            # dry run
  pwsh ./scripts/leadsquared/migration/06-create-opportunities.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$ThrottleMs = 700
)

. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_opportunities_log.txt"
$checkpointPath = Join-Path $dataDir "migration_opportunities_checkpoint.txt"
$worklistPath = Join-Path $dataDir "migration_worklist_opportunities.json"

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "=== Opportunity creation [$mode] ===" $logPath

if (-not (Test-Path $worklistPath)) { throw "Worklist missing. Run 02-build-worklist.ps1 first." }
$work = @(Get-Content $worklistPath -Raw | ConvertFrom-Json)
Write-LsqLog "Opportunities in worklist: $($work.Count)" $logPath

if (-not $Execute) {
    $dist = $work | Group-Object OppStage | Sort-Object Count -Descending
    Write-LsqLog "--- Would create at these stages (before dedupe against existing) ---" $logPath
    foreach ($g in $dist) { Write-LsqLog ("  {0,-18} {1}" -f $g.Name, $g.Count) $logPath }
    Write-LsqLog "Note: many of these already exist from the Phase 3 backfill and will be skipped." $logPath
    Write-LsqLog "DRY RUN complete - nothing written. Re-run with -Execute." $logPath
    return
}

$startIdx = 0
if (Test-Path $checkpointPath) {
    $startIdx = [int](Get-Content $checkpointPath -Raw).Trim()
    Write-LsqLog "Resuming from index $startIdx (checkpoint found)." $logPath
}

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
$primaryUrl = "$base/LeadManagement.svc/Lead/Bulk/UpdateV2?accessKey=$ak&secretKey=$sk"
$captureUrl = "$base/OpportunityManagement.svc/Capture?accessKey=$ak&secretKey=$sk"

$skipped = 0; $created = 0; $failed = 0; $pcOk = 0; $pcFail = 0

for ($i = $startIdx; $i -lt $work.Count; $i++) {
    $row = $work[$i]

    # --- 1. Check before create -------------------------------------------------------
    $checkUrl = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$($row.ProspectId)&opportunityType=12000"
    try {
        $existing = Invoke-RestMethod -Uri $checkUrl -Method Post -ContentType "application/json"
        Start-Sleep -Milliseconds 300
        if ($existing.RecordCount -gt 0) {
            $skipped++
            Set-Content -Path $checkpointPath -Value ($i + 1)
            if ($i % 100 -eq 0) { Write-LsqLog "Progress: $i/$($work.Count) skipped=$skipped created=$created failed=$failed" $logPath }
            continue
        }
    } catch {
        Write-LsqLog "Lead $($row.ProspectId): existence check EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message) - skipping this pass, retry later" $logPath
        Set-Content -Path $checkpointPath -Value ($i + 1)
        Start-Sleep -Milliseconds 300
        continue
    }

    # --- 2. Flag the primary contact ---------------------------------------------------
    $pcBody = @{
        SearchByKey = "ProspectId"
        Options = @{ PushNonExistentLeadsToUnProcessedList = $true }
        LeadPropertiesList = @(, @(@{ Fields = @(
            @{ Attribute = "ProspectId";       Value = $row.ProspectId },
            @{ Attribute = "IsPrimaryContact"; Value = "true" }
        ) }))
    } | ConvertTo-Json -Depth 8
    try {
        $r1 = Invoke-LsqPost -Uri $primaryUrl -JsonBody $pcBody
        if ($r1.Status.SuccessCount -gt 0) { $pcOk++ } else { $pcFail++ }
    } catch {
        $pcFail++
        Write-LsqLog "Lead $($row.ProspectId): IsPrimaryContact EXCEPTION -> $($_.Exception.Message)" $logPath
    }
    Start-Sleep -Milliseconds 350

    # --- 3. Create the Opportunity -----------------------------------------------------
    $oppBody = @{
        LeadDetails = @(
            @{ Attribute = "ProspectID";              Value = $row.ProspectId },
            @{ Attribute = "SearchBy";                Value = "ProspectId" },
            @{ Attribute = "__UseUserDefinedGuid__";  Value = "true" }
        )
        Opportunity = @{
            OpportunityEventCode      = 12000
            OpportunityNote           = "Created by stage restructure migration"
            UpdateEmptyFields         = $true
            DoNotPostDuplicateActivity = $false
            DoNotChangeOwner          = $false
            Fields = @(
                @{ SchemaName = "Status";      Value = $row.Status },
                @{ SchemaName = "mx_Custom_2"; Value = $row.OppStage },
                @{ SchemaName = "Owner";       Value = $row.OwnerId }
            )
        }
    } | ConvertTo-Json -Depth 8

    try {
        $r2 = Invoke-LsqPost -Uri $captureUrl -JsonBody $oppBody
        if ($r2.Status -eq 0 -and $r2.CreatedOpportunityId) { $created++ }
        else { $failed++; Write-LsqLog "Lead $($row.ProspectId): Opportunity FAILURE -> $($r2 | ConvertTo-Json -Compress)" $logPath }
    } catch {
        $failed++
        Write-LsqLog "Lead $($row.ProspectId): Opportunity EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }

    Set-Content -Path $checkpointPath -Value ($i + 1)
    if ($i % 100 -eq 0) { Write-LsqLog "Progress: $i/$($work.Count) skipped=$skipped created=$created failed=$failed" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Opportunity creation DONE. created=$created skipped=$skipped failed=$failed primaryContact(ok=$pcOk fail=$pcFail)" $logPath
if ($failed -eq 0) {
    Remove-Item $checkpointPath -ErrorAction SilentlyContinue
    Write-LsqLog "Checkpoint cleared (clean run)." $logPath
}
Write-LsqLog "=== Opportunity creation complete [$mode] ===" $logPath
