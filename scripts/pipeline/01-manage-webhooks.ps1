<#
.SYNOPSIS
  Create, list, inspect and delete LeadSquared webhooks via Webhook.svc. Removes the UI
  build from the deployment checklist.

.DESCRIPTION
  Discovered 2026-08-08 from LSQ's own API docs: Webhook.svc/Create, /Retrieve, /Update and
  /Delete all exist. This is a genuinely different subsystem from Automations - which is
  why gotcha 11 ("automations do not fire on API/bulk writes") does not necessarily apply
  to it. Whether an activity created by the TELEPHONY INTEGRATION raises Lead Activity
  Creation is still unproven, and -Action Test is how you find out cheaply.

  Nothing is created without -Execute.

.PARAMETER Action
  List    - show existing webhooks with status. Read-only. Start here.
  Test    - create ONE webhook (Outbound Phone Call only) pointing at -Url. For discovering
            the payload shape before committing to the full set.
  Create  - create the full set: outbound calls, inbound calls, the 203 outcome form, and
            lead stage change.
  Delete  - delete by -WebhookId.

.EXAMPLE
  pwsh ./scripts/pipeline/01-manage-webhooks.ps1 -Action List
  pwsh ./scripts/pipeline/01-manage-webhooks.ps1 -Action Test -Url https://script.google.com/.../exec -Execute
  pwsh ./scripts/pipeline/01-manage-webhooks.ps1 -Action Create -Url https://... -Secret xyz -Execute

.NOTES
  ASCII only. Webhook.svc rate limit is 25 calls / 5 seconds - far looser than the lead API.
#>

[CmdletBinding()]
param(
    [ValidateSet("List", "Test", "Create", "Delete")]
    [string]$Action = "List",

    [string]$Url,
    [string]$Secret,
    [string]$WebhookId,
    [switch]$Execute
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "pipeline_webhooks_log.txt"

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']

# WebhookEvent codes, from the LSQ API docs. Only the ones this pipeline needs.
$EVT_ACTIVITY_CREATE = 2
$EVT_LEAD_STAGE_CHANGE = 5

# The activity types to subscribe to, keyed by LSQ activity event code. These are the same
# codes the activity trail uses - confirmed live 2026-08-08.
$activityTargets = @(
    @{ Code = 22;  Name = "Outbound Phone Call Activity" }
    @{ Code = 21;  Name = "Inbound Phone Call Activity" }
    @{ Code = 203; Name = "01. Phone Call/ Follow Up" }
)

function Invoke-WebhookApi {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$JsonBody)
    $uri = "$base/Webhook.svc/$Path" + "?accessKey=$ak&secretKey=$sk"
    # UTF-8 bytes with an explicit charset: PS 5.1's -Body <string> does not reliably send
    # UTF-8, and a single non-ASCII character produces a hard 400 that every retry repeats.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
    return Invoke-LsqWithRetry -What "Webhook.svc/$Path" -Action {
        Invoke-RestMethod -Uri $uri -Method Post -Body $bytes `
            -ContentType "application/json; charset=utf-8" -ErrorAction Stop
    }
}

function Get-WebhookList {
    <#
      PURE - returns a result object, logs nothing. A function that both logs and returns
      hands the caller its log lines bundled with the return value.

      Returns a hashtable rather than a bare array on purpose. Two PowerShell traps meet
      here: an empty/absent .Response makes `return @($x)` emit $null to the caller (the
      pipeline unrolls a single-element array), and that then binds as $null rather than as
      an empty array. Wrapping in a hashtable stops the unrolling entirely, and carrying
      RecordCount separately is what distinguishes "the account has no webhooks" from "the
      call failed" - two very different findings that otherwise look identical.
    #>
    param([string]$EventFilter = "LeadActivity_Post_Create")
    $body = @{
        Parameter = @{ Type = "Webhook"; WebhookEvent = $EventFilter; StatusCode = 0; WebhookId = ""; SearchText = "" }
        Sorting   = @{ ColumnName = "ModifiedOn"; Direction = "1" }
        Paging    = @{ PageIndex = 1; PageSize = 100 }
    } | ConvertTo-Json -Depth 6
    $resp = Invoke-WebhookApi -Path "Retrieve" -JsonBody $body

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($resp.Response)) { if ($null -ne $r) { [void]$rows.Add($r) } }

    return @{
        # .ToArray(), never @($list) - @() on a List[object] variable throws
        # "Argument types do not match" on this machine (gotcha 12).
        Rows        = $rows.ToArray()
        RecordCount = $resp.RecordCount
        Raw         = $resp
    }
}

function Write-WebhookRows {
    param([AllowNull()][object[]]$Rows, $RecordCount, [string]$Label, [string]$LogPath)
    $list = @()
    if ($null -ne $Rows) { $list = $Rows }
    Write-LsqLog "" $LogPath
    Write-LsqLog "--- $Label (returned $($list.Count), RecordCount=$RecordCount) ---" $LogPath
    if ($list.Count -eq 0) { Write-LsqLog "  (none configured)" $LogPath; return }
    $Rows = $list
    foreach ($w in $Rows) {
        # StatusCode: 0 enabled, 1 manually disabled, 2 disabled after 10 consecutive failures.
        $status = switch ("$($w.StatusCode)") {
            "0" { "ENABLED" }
            "1" { "disabled (manual)" }
            "2" { "DISABLED - 10 consecutive failures" }
            default { "status $($w.StatusCode)" }
        }
        Write-LsqLog ("  {0,-38} {1}" -f $w.EventCode, $status) $LogPath
        Write-LsqLog ("     id  : {0}" -f $w.WebhookId) $LogPath
        Write-LsqLog ("     url : {0}" -f $w.URL) $LogPath
        if ($w.Description) { Write-LsqLog ("     desc: {0}" -f $w.Description) $LogPath }
        if ($w.WebhookProperties) { Write-LsqLog ("     props: {0}" -f $w.WebhookProperties) $LogPath }
    }
}

function New-ActivityWebhook {
    <#
      GOTCHA, established live 2026-08-08 by probing five body shapes:

      ActivityEvent must ALSO be passed at the TOP LEVEL of the body. The API documentation
      shows it only inside the WebhookProperties string, and that form alone fails with
      HTTP 500 / MXInvalidDataTypeException "You have not passed ActivityEvent."

      Both are sent. WebhookProperties must remain a STRING containing escaped JSON - a
      nested object is rejected with a 400 JSON parse error - and the top-level key is what
      the server actually reads.

      Note LSQ returns 500 (not 400) for this malformed input, which the shared retry helper
      classifies as transient and retries four times. The real message only surfaces from
      ErrorDetails.Message, which is why the failure originally looked like a server fault.
    #>
    param(
        [Parameter(Mandatory)][int]$ActivityEventCode,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$TargetUrl,
        [string]$HeaderSecret
    )
    $props = (@{ ActivityEvent = "$ActivityEventCode"; ActivityData = "[]"; WebPageNames = "[]" } | ConvertTo-Json -Compress)

    $payload = [ordered]@{
        Description           = $Description
        URL                   = $TargetUrl
        Method                = "POST"
        ContentType           = "application/json"
        WebhookEvent          = "$EVT_ACTIVITY_CREATE"
        ActivityEvent         = "$ActivityEventCode"   # <-- the undocumented required key
        IsSpecificLandingPage = $false
        NotifyOnFailure       = $true
        WebhookProperties     = $props
    }
    if ($HeaderSecret) {
        # Custom headers are the documented way to authenticate a webhook. Up to 10 allowed.
        $payload["CustomHeaders"] = @(@{ Key = "x-truefan-signature"; Value = $HeaderSecret })
    }
    return Invoke-WebhookApi -Path "Create" -JsonBody ($payload | ConvertTo-Json -Depth 6)
}

function New-StageChangeWebhook {
    <#
      UNRESOLVED as of 2026-08-08 - this fails and the correct body is not known.

      WebhookEvent 5 rejects a null/absent WebhookProperties with "Webhook Properties is not
      found", and then rejects every JSON string tried with "Webhook Properties is not a
      valid JSON" - including a plain "{}", which plainly IS valid JSON. Seven shapes were
      probed: {}, {"StageFrom":"","StageTo":""}, {"ProspectStage":"[]"},
      {"StageFrom":"Any","StageTo":"Any"}, {"Stages":"[]"}, and both the null and absent
      forms. The documentation gives an example only for the OPPORTUNITY stage-change event,
      not the lead one.

      NOT BLOCKING. The pipeline reads contact stage from the Leads cache, which the hourly
      reconcile refreshes for everyone called that day. The stage-change webhook would only
      sharpen "what stage was this lead in AT THE MOMENT of the call" from "what stage is it
      in now" - a real improvement, not a prerequisite.

      Easiest resolution: create it once in the LSQ UI (My Account > Settings > API and
      Webhooks), then run -Action List and read the WebhookProperties value LSQ itself
      stored. That is the shape to copy here.
    #>
    param([Parameter(Mandatory)][string]$TargetUrl, [string]$HeaderSecret)
    $payload = [ordered]@{
        Description           = "TrueFan pipeline - lead stage change"
        URL                   = $TargetUrl
        Method                = "POST"
        ContentType           = "application/json"
        WebhookEvent          = "$EVT_LEAD_STAGE_CHANGE"
        IsSpecificLandingPage = $false
        NotifyOnFailure       = $true
        WebhookProperties     = $null
    }
    if ($HeaderSecret) {
        $payload["CustomHeaders"] = @(@{ Key = "x-truefan-signature"; Value = $HeaderSecret })
    }
    return Invoke-WebhookApi -Path "Create" -JsonBody ($payload | ConvertTo-Json -Depth 6)
}

# =======================================================================================

Write-LsqLog "=== Webhook management: $Action ===" $logPath

switch ($Action) {

    "List" {
        # Lead_Field_Change is how stage and disposition HISTORY is captured. Lead Stage
        # Change (event 5) cannot be created through this API - eleven body shapes were
        # probed on 2026-08-08 and all were rejected with "Webhook Properties is not a valid
        # JSON", including a literal {}. A field-change webhook on ProspectStage does the
        # same job and creates cleanly, so that is the route used.
        foreach ($evt in @("LeadActivity_Post_Create", "LeadActivity_Post_Update",
                           "Lead_Field_Change", "Lead_Post_Stage_Change", "Lead_Post_Update")) {
            try {
                $res = Get-WebhookList -EventFilter $evt
                Write-WebhookRows -Rows $res.Rows -RecordCount $res.RecordCount -Label $evt -LogPath $logPath
            } catch {
                Write-LsqLog "  $evt -> query FAILED: $($_.Exception.Message)" $logPath
                if ($_.ErrorDetails.Message) { Write-LsqLog "     detail: $($_.ErrorDetails.Message)" $logPath }
            }
        }
        Write-LsqLog "" $logPath
        Write-LsqLog "Any webhook showing 'DISABLED - 10 consecutive failures' must be re-enabled" $logPath
        Write-LsqLog "in the UI after the endpoint is fixed; LSQ does not re-enable it by itself." $logPath
    }

    "Test" {
        if (-not $Url) { throw "-Url is required. Deploy the capture endpoint first (appsscript/WebhookCapture.gs)." }
        Write-LsqLog "Creating ONE webhook: Outbound Phone Call Activity (event 22) -> $Url" $logPath
        Write-LsqLog "Purpose: discover the real payload shape before building against a guess." $logPath
        if (-not $Execute) {
            Write-LsqLog "" $logPath
            Write-LsqLog "DRY RUN - nothing created. Re-run with -Execute." $logPath
            break
        }
        $r = New-ActivityWebhook -ActivityEventCode 22 `
                -Description "TrueFan payload discovery - DELETE AFTER USE" `
                -TargetUrl $Url -HeaderSecret $Secret
        Write-LsqLog "Response: $($r | ConvertTo-Json -Depth 5 -Compress)" $logPath
        Write-LsqLog "" $logPath
        Write-LsqLog "NEXT: place one real call, wait 2 minutes (activity webhooks are batched" $logPath
        Write-LsqLog "per minute), then read the Captured tab. You can also see the exact payload" $logPath
        Write-LsqLog "in LSQ: Webhooks > Actions > View History > Show." $logPath
    }

    "Create" {
        if (-not $Url) { throw "-Url is required." }
        if (-not $Secret) { Write-LsqLog "WARNING: no -Secret given; the endpoint will be unauthenticated." $logPath }

        Write-LsqLog "Will create $($activityTargets.Count) activity webhooks + 1 stage-change webhook -> $Url" $logPath
        foreach ($t in $activityTargets) { Write-LsqLog "  activity $($t.Code) - $($t.Name)" $logPath }

        if (-not $Execute) {
            Write-LsqLog "" $logPath
            Write-LsqLog "DRY RUN - nothing created. Re-run with -Execute." $logPath
            break
        }

        foreach ($t in $activityTargets) {
            try {
                $r = New-ActivityWebhook -ActivityEventCode $t.Code `
                        -Description "TrueFan calling pipeline - $($t.Name)" `
                        -TargetUrl $Url -HeaderSecret $Secret
                Write-LsqLog "  created $($t.Name) -> $($r.Message.Id)" $logPath
            } catch {
                Write-LsqLog "  FAILED $($t.Name) -> $($_.Exception.Message)" $logPath
                if ($_.ErrorDetails.Message) { Write-LsqLog "     detail: $($_.ErrorDetails.Message)" $logPath }
            }
            Start-Sleep -Milliseconds 400
        }

        try {
            $r = New-StageChangeWebhook -TargetUrl $Url -HeaderSecret $Secret
            Write-LsqLog "  created Lead Stage Change -> $($r.Message.Id)" $logPath
        } catch {
            Write-LsqLog "  FAILED Lead Stage Change -> $($_.Exception.Message)" $logPath
        }

        Write-LsqLog "" $logPath
        Write-LsqLog "VERIFY by independent re-fetch, not by the responses above:" $logPath
        Write-LsqLog "  pwsh ./scripts/pipeline/01-manage-webhooks.ps1 -Action List" $logPath
    }

    "Delete" {
        # GOTCHA: Delete is a GET with the id in the QUERY STRING. A POST - the pattern every
        # other Webhook.svc verb uses - returns 405 Method Not Allowed. Established live
        # 2026-08-08 after POST with the id in the body, and POST with it in the query
        # string, both failed.
        if (-not $WebhookId) { throw "-WebhookId is required. Get it from -Action List." }
        if (-not $Execute) {
            Write-LsqLog "DRY RUN - would delete $WebhookId. Re-run with -Execute." $logPath
            break
        }
        $delUri = "$base/Webhook.svc/Delete" + "?accessKey=$ak&secretKey=$sk&webhookId=$WebhookId"
        $r = Invoke-LsqWithRetry -What "Webhook.svc/Delete" -Action {
            Invoke-RestMethod -Uri $delUri -Method Get -ErrorAction Stop
        }
        Write-LsqLog "Deleted $WebhookId -> $($r | ConvertTo-Json -Compress)" $logPath
        Write-LsqLog "Verify with -Action List - do not trust this response alone." $logPath
    }
}

Write-LsqLog "Log: $logPath" $logPath
