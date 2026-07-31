<#
.SYNOPSIS
  The stage sync engine. One pass per invocation - designed to be run every 15 minutes by
  Windows Task Scheduler. Keeps Contact, Company and Opportunity stages consistent.

.DESCRIPTION
  Implements docs/STAGE_RESTRUCTURE_PLAN.md section 2. The decision logic lives in
  sync-rules.ps1 (pure, offline-tested by test-sync-rules.ps1); this script is only the
  plumbing that gathers state, calls those rules, and performs the writes.

  Incremental by default: reads a UTC watermark, fetches only leads modified since, and
  processes those. Observed change rate on this account is ~133 leads/hour in business hours,
  so a 15-minute cycle handles ~35 records - a few seconds of work.

  CRITICAL - timezone. LeadSquared stores ModifiedOn in UTC while this account operates in
  IST (UTC+5:30). A watermark built from local Get-Date would be 5.5 hours in the FUTURE and
  match zero rows forever, so the sync would silently do nothing. All timestamps go through
  Get-LsqTimestamp, which converts to UTC. Verified live 2026-07-28.

  There is NO bulk Opportunity read endpoint (probed and confirmed - reads are per-lead via
  GetOpportunitiesOfLead). That is why this engine is watermark-scoped rather than a full
  sweep: a full sweep would need one call per lead.

.PARAMETER Execute
  Required to write. Without it, every intended change is logged and nothing is sent.

.PARAMETER FullScan
  Ignore the watermark and process every lead at a live stage (Engaged/Prospect/Customer)
  plus every primary contact. Use as a nightly reconciliation to catch anything the
  incremental pass missed. Slower - budget one API call per candidate.

.PARAMETER LookbackMinutes
  Safety overlap re-processed on each run, so a record modified during the previous pass is
  not skipped. Default 30. Harmless - the engine is idempotent and skips no-op records.

.EXAMPLE
  # Rehearsal - shows what it would do, writes nothing:
  pwsh ./scripts/leadsquared/sync/sync-engine.ps1

  # Live, every 15 min via Task Scheduler:
  pwsh ./scripts/leadsquared/sync/sync-engine.ps1 -Execute

  # Nightly reconciliation:
  pwsh ./scripts/leadsquared/sync/sync-engine.ps1 -Execute -FullScan
#>

param(
    [switch]$Execute,
    [switch]$FullScan,
    [int]$LookbackMinutes = 30,
    [int]$ThrottleMs = 300
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\sync-rules.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "sync_engine_log.txt"
$watermarkPath = Join-Path $dataDir "sync_watermark.txt"
$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# Capture the run start BEFORE doing any work, so records changed mid-run are picked up next
# pass rather than being skipped by a watermark set at the end.
$runStartUtc = Get-LsqTimestamp

Write-LsqLog "=== Sync pass [$mode]$(if ($FullScan) { ' [FULL SCAN]' }) ===" $logPath

# ---------------------------------------------------------------------------------------
# Gather candidate leads
# ---------------------------------------------------------------------------------------
$cols = "ProspectID,ProspectStage,RelatedCompanyId,OwnerId,IsPrimaryContact,ProspectActivityDate_Max,ModifiedOn"
$candidates = @()

if ($FullScan) {
    Write-LsqLog "Full scan: fetching all leads at a live stage plus all primary contacts." $logPath
    foreach ($stage in @("Engaged", "Prospect", "Customer")) {
        $page = 1
        while ($true) {
            $r = Invoke-LsqLeadSearch -Filter @{ LookupName="ProspectStage"; LookupValue=$stage; SqlOperator="=" } `
                -ColumnsCsv $cols -PageIndex $page -PageSize 1000
            if (-not $r -or @($r).Count -eq 0) { break }
            $candidates += @($r)
            if (@($r).Count -lt 1000) { break }
            $page++; Start-Sleep -Milliseconds $ThrottleMs
        }
    }
    # IsPrimaryContact filtering needs LookupValue "1" - "true" returns HTTP 500. Verified live.
    $page = 1
    while ($true) {
        $r = Invoke-LsqLeadSearch -Filter @{ LookupName="IsPrimaryContact"; LookupValue="1"; SqlOperator="=" } `
            -ColumnsCsv $cols -PageIndex $page -PageSize 1000
        if (-not $r -or @($r).Count -eq 0) { break }
        $candidates += @($r)
        if (@($r).Count -lt 1000) { break }
        $page++; Start-Sleep -Milliseconds $ThrottleMs
    }
    $candidates = $candidates | Sort-Object ProspectID -Unique
} else {
    $since = if (Test-Path $watermarkPath) {
        (Get-Content $watermarkPath -Raw).Trim()
    } else {
        Write-LsqLog "No watermark found - defaulting to the last 24 hours." $logPath
        Get-LsqTimestamp ((Get-Date).AddHours(-24))
    }
    # Re-process a short overlap so a record modified during the previous pass is not missed.
    $sinceDt = [datetime]::ParseExact($since, "yyyy-MM-dd HH:mm:ss", $null)
    $since = $sinceDt.AddMinutes(-$LookbackMinutes).ToString("yyyy-MM-dd HH:mm:ss")
    Write-LsqLog "Incremental: leads with ModifiedOn > $since (UTC)" $logPath

    $page = 1
    while ($true) {
        $r = Invoke-LsqLeadSearch -Filter @{ LookupName="ModifiedOn"; LookupValue=$since; SqlOperator=">" } `
            -ColumnsCsv $cols -PageIndex $page -PageSize 1000
        if (-not $r -or @($r).Count -eq 0) { break }
        $candidates += @($r)
        if (@($r).Count -lt 1000) { break }
        $page++; Start-Sleep -Milliseconds $ThrottleMs
    }
}

Write-LsqLog "Candidate leads: $($candidates.Count)" $logPath
if ($candidates.Count -eq 0) {
    if ($Execute) { Set-Content -Path $watermarkPath -Value $runStartUtc }
    Write-LsqLog "Nothing to do. Watermark -> $runStartUtc" $logPath
    return
}

# ---------------------------------------------------------------------------------------
# Helpers with caching - company stages and per-account open-deal state are reused across
# contacts at the same account within a pass.
# ---------------------------------------------------------------------------------------
$companyStageCache = @{}
$accountOpenOppCache = @{}

function Get-CompanyStage {
    param([string]$CompanyId)
    if ([string]::IsNullOrWhiteSpace($CompanyId)) { return $null }
    if ($companyStageCache.ContainsKey($CompanyId)) { return $companyStageCache[$CompanyId] }
    try {
        $r = Invoke-LsqCompanySearch -FilterBy @{ LookupName="CompanyId"; LookupValue=$CompanyId; SqlOperator="=" } -PageSize 1
        $stage = $null
        if ($r.Companies -and @($r.Companies).Count -gt 0) {
            foreach ($p in $r.Companies[0].companyPropertyList) { if ($p.Attribute -eq "Stage") { $stage = $p.Value } }
        }
        $companyStageCache[$CompanyId] = $stage
        return $stage
    } catch {
        Write-LsqLog "  company read failed for $CompanyId -> $($_.Exception.Message)" $logPath
        $companyStageCache[$CompanyId] = $null
        return $null
    }
}

function Get-LeadOpportunity {
    param([string]$LeadId)
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$LeadId&opportunityType=12000"
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json"
        if ($r.RecordCount -gt 0) {
            $o = $r.List[0]
            $f = @{}
            foreach ($fld in $o.Fields) { $f[$fld.SchemaName] = $fld.Value }
            return @{ Id = $o.OpportunityId; Status = $f["Status"]; Stage = $f["mx_Custom_2"] }
        }
        return $null
    } catch {
        Write-LsqLog "  opportunity read failed for $LeadId -> $($_.Exception.Message)" $logPath
        return "ERROR"
    }
}

# ---------------------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------------------
$stats = @{ Examined=0; ContactWrites=0; CompanyWrites=0; OppsCreated=0; Errors=0; NoChange=0 }
$leadUpdateUrl = Get-LsqUrl "LeadManagement.svc/Lead/Bulk/UpdateV2"

foreach ($lead in $candidates) {
    $stats.Examined++
    $leadId = $lead.ProspectID
    $contactStage = $lead.ProspectStage
    $companyId = $lead.RelatedCompanyId
    $isPrimary = Test-LsqTrue $lead.IsPrimaryContact
    $hasActivity = -not [string]::IsNullOrWhiteSpace($lead.ProspectActivityDate_Max)

    # Only pay for an opportunity lookup when one could plausibly exist.
    $opp = $null
    if ($isPrimary -or $contactStage -in @("Prospect", "Customer")) {
        $opp = Get-LeadOpportunity -LeadId $leadId
        Start-Sleep -Milliseconds $ThrottleMs
        if ($opp -eq "ERROR") { $stats.Errors++; continue }
    }

    $companyStage = Get-CompanyStage -CompanyId $companyId
    if ($companyId) { Start-Sleep -Milliseconds 150 }

    # Does any OTHER contact at this account already own an open deal? Prevents a second
    # deal being opened on the same account.
    $accountHasOpen = $false
    if ($companyId) {
        if ($accountOpenOppCache.ContainsKey($companyId)) {
            $accountHasOpen = $accountOpenOppCache[$companyId]
        } else {
            $accountHasOpen = ($companyStage -eq "Opportunity" -or $companyStage -eq "Customer")
            $accountOpenOppCache[$companyId] = $accountHasOpen
        }
    }
    # A contact that owns the deal must not be blocked by its own deal.
    if ($opp) { $accountHasOpen = $false }

    $actions = Get-SyncActions `
        -CurrentContactStage $contactStage `
        -CurrentCompanyStage $companyStage `
        -HasActivity $hasActivity `
        -HasOpportunity ($null -ne $opp) `
        -OppStatus $(if ($opp) { $opp.Status } else { $null }) `
        -OppStage  $(if ($opp) { $opp.Stage }  else { $null }) `
        -IsPrimaryContact $isPrimary `
        -AccountHasOpenOpportunity $accountHasOpen

    if (-not $actions.ContactStage -and -not $actions.CompanyStage -and -not $actions.CreateOpportunity) {
        $stats.NoChange++
        continue
    }

    Write-LsqLog "Lead $leadId : $($actions.Reason)" $logPath

    if (-not $Execute) {
        if ($actions.ContactStage)      { Write-LsqLog "    WOULD SET contact  $contactStage -> $($actions.ContactStage)" $logPath }
        if ($actions.CompanyStage)      { Write-LsqLog "    WOULD SET company  $companyStage -> $($actions.CompanyStage)" $logPath }
        if ($actions.CreateOpportunity) { Write-LsqLog "    WOULD CREATE opportunity at $($actions.NewOppStage.Stage)" $logPath }
        continue
    }

    # --- write contact stage -----------------------------------------------------------
    if ($actions.ContactStage) {
        $body = @{
            SearchByKey = "ProspectId"
            Options = @{ PushNonExistentLeadsToUnProcessedList = $true }
            LeadPropertiesList = @(, @(@{ Fields = @(
                @{ Attribute = "ProspectId";    Value = $leadId },
                @{ Attribute = "ProspectStage"; Value = $actions.ContactStage }
            ) }))
        } | ConvertTo-Json -Depth 8
        try {
            $r = Invoke-LsqPost -Uri $leadUpdateUrl -JsonBody $body
            if ($r.Status.SuccessCount -gt 0) { $stats.ContactWrites++ }
            else { $stats.Errors++; Write-LsqLog "    contact write FAILED -> $($r | ConvertTo-Json -Compress -Depth 3)" $logPath }
        } catch { $stats.Errors++; Write-LsqLog "    contact write EXCEPTION -> $($_.Exception.Message)" $logPath }
        Start-Sleep -Milliseconds $ThrottleMs
    }

    # --- create opportunity ------------------------------------------------------------
    if ($actions.CreateOpportunity) {
        # Set the primary-contact flag first: only the primary may own the account's deal.
        $pcBody = @{
            SearchByKey = "ProspectId"
            Options = @{ PushNonExistentLeadsToUnProcessedList = $true }
            LeadPropertiesList = @(, @(@{ Fields = @(
                @{ Attribute = "ProspectId";       Value = $leadId },
                @{ Attribute = "IsPrimaryContact"; Value = "true" }
            ) }))
        } | ConvertTo-Json -Depth 8
        try { Invoke-LsqPost -Uri $leadUpdateUrl -JsonBody $pcBody | Out-Null } catch {
            Write-LsqLog "    IsPrimaryContact write EXCEPTION -> $($_.Exception.Message)" $logPath
        }
        Start-Sleep -Milliseconds $ThrottleMs

        $oppBody = @{
            LeadDetails = @(
                @{ Attribute = "ProspectID";             Value = $leadId },
                @{ Attribute = "SearchBy";               Value = "ProspectId" },
                @{ Attribute = "__UseUserDefinedGuid__"; Value = "true" }
            )
            Opportunity = @{
                OpportunityEventCode       = 12000
                OpportunityNote            = "Auto-created by sync engine on stage change to $(if ($actions.ContactStage) { $actions.ContactStage } else { $contactStage })"
                UpdateEmptyFields          = $true
                DoNotPostDuplicateActivity = $false
                DoNotChangeOwner           = $false
                Fields = @(
                    @{ SchemaName = "Status";      Value = $actions.NewOppStage.Status },
                    @{ SchemaName = "mx_Custom_2"; Value = $actions.NewOppStage.Stage },
                    @{ SchemaName = "Owner";       Value = $lead.OwnerId }
                )
            }
        } | ConvertTo-Json -Depth 8
        try {
            $r = Invoke-LsqPost -Uri "$base/OpportunityManagement.svc/Capture?accessKey=$ak&secretKey=$sk" -JsonBody $oppBody
            if ($r.Status -eq 0 -and $r.CreatedOpportunityId) {
                $stats.OppsCreated++
                if ($companyId) { $accountOpenOppCache[$companyId] = $true }
            } else {
                $stats.Errors++; Write-LsqLog "    opportunity create FAILED -> $($r | ConvertTo-Json -Compress)" $logPath
            }
        } catch { $stats.Errors++; Write-LsqLog "    opportunity create EXCEPTION -> $($_.Exception.Message)" $logPath }
        Start-Sleep -Milliseconds $ThrottleMs
    }

    # --- write company stage -----------------------------------------------------------
    if ($actions.CompanyStage -and $companyId) {
        # Company.Update requires the array wrapped in "CompanyProperties" - a bare array
        # fails with MXInvalidDataTypeException on every call. See 05-migrate-companies.ps1.
        $body = "{`"CompanyProperties`":[{`"Attribute`":`"Stage`",`"Value`":`"$($actions.CompanyStage)`"}]}"
        try {
            $r = Invoke-LsqPost -Uri "$base/CompanyManagement.svc/Company.Update?accessKey=$ak&secretKey=$sk&companyId=$companyId" -JsonBody $body
            if ($r.Status -eq "Success") {
                $stats.CompanyWrites++
                $companyStageCache[$companyId] = $actions.CompanyStage
            } else { $stats.Errors++; Write-LsqLog "    company write FAILED -> $($r | ConvertTo-Json -Compress)" $logPath }
        } catch { $stats.Errors++; Write-LsqLog "    company write EXCEPTION -> $($_.Exception.Message)" $logPath }
        Start-Sleep -Milliseconds $ThrottleMs
    }
}

# Advance the watermark only on a successful executing pass, and only to the run START time.
if ($Execute -and -not $FullScan) {
    Set-Content -Path $watermarkPath -Value $runStartUtc
    Write-LsqLog "Watermark advanced -> $runStartUtc (UTC)" $logPath
}

Write-LsqLog ("Pass complete. examined={0} noChange={1} contactWrites={2} companyWrites={3} oppsCreated={4} errors={5}" -f `
    $stats.Examined, $stats.NoChange, $stats.ContactWrites, $stats.CompanyWrites, $stats.OppsCreated, $stats.Errors) $logPath
Write-LsqLog "=== Sync pass done [$mode] ===" $logPath
