# Shared Opportunity helpers for LeadSquared API scripts.
#
#   . "$PSScriptRoot\..\lib\common.ps1"
#   . "$PSScriptRoot\..\lib\schema.ps1"
#   . "$PSScriptRoot\..\lib\opportunity.ps1"     # in that order - it needs both
#
# WHY THIS FILE EXISTS
# --------------------
# GetOpportunitiesOfLead was hand-rolled and duplicated verbatim in eleven scripts. Six of
# those copies had no retry wrapper, five read a "Fields" array the endpoint does not return
# (gotcha 45), and several swallowed a network error as "this lead has no deals" - which,
# in a create path, silently produces a duplicate deal that cannot be deleted afterwards.
# Same reasoning that produced activity.ps1. Extend this rather than writing a new inline call.
#
# THE THREE READS, AND WHY THEY DISAGREE (gotcha 25)
# --------------------------------------------------
#   ProspectActivity.svc/Retrieve  (EventCode 12000)  mx_Custom_1, _2, Status, Owner. That is all.
#   GetOpportunitiesOfLead   POST, empty body         adds _6 and _8. FLAT properties, no Fields[].
#   GetOpportunityDetails    GET                      all 29 fields, WITH DisplayName + DataType.
#                                                     The only read that returns mx_Custom_4.
#
# Deal Stage is mx_Custom_2, a dependent dropdown under the native Status field. Status is
# fixed to Open/Won/Lost and is what reps see labelled "Deal Stage". Do not confuse them.

$Script:OPP_TYPE_ID = "12000"        # opportunityType query param AND the activity EventCode

# Schema name -> what its DisplayName MUST still say. Asserted on every detail read, so a
# LeadSquared renumber stops the run instead of quietly loading Actual Deal Size into the
# expected-value column. Lifted from pipeline/08-load-opportunity-details.ps1 so both share one
# table. Type drives parsing only.
$Script:OpportunityFieldMap = @(
    @{ Schema='mx_Custom_1';  Expect='Opportunity Name';      Col='opportunity_name';    Type='text' },
    @{ Schema='mx_Custom_2';  Expect='Stage';                 Col='stage';               Type='text' },
    @{ Schema='Status';       Expect='Deal Stage';            Col='status';              Type='text' },
    @{ Schema='mx_Custom_3';  Expect='Source';                Col='source';              Type='text' },
    @{ Schema='mx_Custom_4';  Expect='Loss Reason';           Col='loss_reason';         Type='text' },
    @{ Schema='mx_Custom_5';  Expect='Description';           Col='description';         Type='text' },
    @{ Schema='mx_Custom_6';  Expect='Expected Deal Size';    Col='deal_value';          Type='num'  },
    @{ Schema='mx_Custom_7';  Expect='Actual Deal Size';      Col='actual_deal_value';   Type='num'  },
    @{ Schema='mx_Custom_8';  Expect='Expected Closure Date'; Col='expected_close_date'; Type='date' },
    @{ Schema='mx_Custom_9';  Expect='Actual Closure Date';   Col='actual_close_date';   Type='date' },
    @{ Schema='mx_Custom_10'; Expect='Product';               Col='product';             Type='text' },
    @{ Schema='mx_Custom_13'; Expect='Celebrity Assigned';    Col='celebrity_assigned';  Type='text' },
    @{ Schema='mx_Custom_14'; Expect='Contract Start Date';   Col='contract_start_date'; Type='date' },
    @{ Schema='mx_Custom_15'; Expect='Contract End Date';     Col='contract_end_date';   Type='date' },
    @{ Schema='mx_Custom_16'; Expect='Agreement Sent Date';   Col='agreement_sent_date'; Type='date' },
    @{ Schema='mx_Custom_17'; Expect='Invoice Sent Date';     Col='invoice_sent_date';   Type='date' }
)

# The note prefix every cleanup write stamps. GetOpportunityDetails returns OpportunityNote,
# so this makes a cleanup closure machine-recoverable even if mx_Custom_4 turns out unwritable,
# and it is the key the rollback and the warehouse's is_cleanup_closure both match on.
$Script:OPP_CLEANUP_NOTE_PREFIX = "OPPCLEAN"

# Records created by a probe or test run. Excluded from every audit count.
$Script:OpportunityTestMarkers = @("OPPCLEAN-PROBE", "TESTAUTO-")


function Get-LsqOpportunityConfig {
    param([AllowNull()][hashtable]$Config)
    if ($Config) { return $Config }
    return Import-LsqConfig
}


function Get-LsqOpportunitiesOfLead {
    <#
      Every opportunity on one lead.

      POST with an EMPTY body - a GET returns 405 - and opportunityType is REQUIRED despite the
      docs implying otherwise (gotcha 23). There is no /Opportunity/ path segment; the wrong
      path 404s on every method, which reads as "the endpoint does not exist" rather than
      "the URL is wrong".

      Returns an ARRAY, empty when the lead has no deals. Throws on a transport failure - it
      does NOT return empty, because a caller that cannot tell "no deals" from "the read
      failed" will create a duplicate deal, and deletion is blocked.
    #>
    param(
        [Parameter(Mandatory)][string]$ProspectId,
        [AllowNull()][hashtable]$Config,
        [switch]$IncludeRaw
    )
    $cfg  = Get-LsqOpportunityConfig $Config
    $base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
    $url  = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead?accessKey=$ak&secretKey=$sk&leadId=$ProspectId&opportunityType=$($Script:OPP_TYPE_ID)"

    # Invoke-WebRequest | ConvertFrom-Json, not Invoke-RestMethod: @() over an IRM result counts
    # $null as 1 and a nested array as 1 (gotcha 19).
    $resp = Invoke-LsqWithRetry -What "opportunities of lead $ProspectId" -Action {
        (Invoke-WebRequest -Uri $url -Method Post -ContentType "application/json" -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
    }

    $rows = @(Expand-LsqRows $resp.List)

    # RecordCount is the server's own count. If it disagrees with what we managed to iterate,
    # the page arrived in a shape we did not expect - stop rather than under-report (gotcha 9).
    if ($null -ne $resp.RecordCount) {
        $declared = [int]$resp.RecordCount
        if ($declared -ne $rows.Count) {
            throw "Lead $ProspectId : RecordCount says $declared but $($rows.Count) row(s) were read. Refusing to report a partial deal list."
        }
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($o in $rows) {
        # FLAT properties. This endpoint has NO Fields[] array - only GetOpportunityDetails does
        # (gotcha 45). Reading $o.Fields here yields null on every column and looks like an
        # empty-but-present record.
        $item = [pscustomobject]@{
            OpportunityId     = "$($o.OpportunityId)"
            ProspectId        = if ($o.RelatedProspectId) { "$($o.RelatedProspectId)" } else { $ProspectId }
            Name              = "$($o.mx_Custom_1)"
            OppStage          = "$($o.mx_Custom_2)"
            Status            = "$($o.Status)"
            ExpectedDealSize  = $o.mx_Custom_6
            ExpectedCloseDate = $o.mx_Custom_8
            OwnerId           = "$($o.Owner)"
            OwnerName         = "$($o.OwnerName)"
            Note              = "$($o.OpportunityNote)"
            CreatedOnUtc      = "$($o.CreatedOn)"
            ModifiedOnUtc     = "$($o.ModifiedOn)"
            Raw               = $(if ($IncludeRaw) { $o } else { $null })
        }
        [void]$out.Add($item)
    }
    # NO leading comma on the return. `return ,$out.ToArray()` makes @(Get-LsqOpportunitiesOfLead ...)
    # report Count = 1 for a 0-deal, 1-deal AND N-deal lead, with [0] holding the whole inner
    # array - a phantom deal on every empty lead. Same contract as Expand-LsqRows in common.ps1:
    # this unrolls, and the CALLER wraps in @(...).
    return $out.ToArray()
}


function Get-LsqOpportunityDetails {
    <#
      The full 29-field record for one opportunity, WITH DisplayName and DataType.

      A GET. The opportunityId is the same GUID as the activity Id on the EventCode 12000
      trail entry, so no lookup pass is needed. This is also the opportunity field-metadata
      endpoint that gotcha 23 recorded as not existing - it was simply not among the 14 names
      probed (gotcha 25).

      Returns @{ OpportunityId; ProspectId; Note; Status; OppStage; Fields } where Fields is
      schema name -> @{ DisplayName; DataType; Value }.
    #>
    param(
        [Parameter(Mandatory)][string]$OpportunityId,
        [AllowNull()][hashtable]$Config,
        [switch]$SkipMapAssert
    )
    $cfg  = Get-LsqOpportunityConfig $Config
    $base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
    $url  = "$base/OpportunityManagement.svc/GetOpportunityDetails?accessKey=$ak&secretKey=$sk&opportunityId=$OpportunityId"

    $resp = Invoke-LsqWithRetry -What "opportunity details $OpportunityId" -Action {
        (Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
    }

    if (-not $SkipMapAssert) { Assert-LsqOpportunityFieldMap -DetailResponse $resp }

    $fields = @{}
    foreach ($f in @($resp.Fields)) {
        if (-not $f.SchemaName) { continue }
        $fields["$($f.SchemaName)"] = @{
            DisplayName = "$($f.DisplayName)".Trim()
            DataType    = "$($f.DataType)"
            Value       = $f.Value
        }
    }

    return @{
        OpportunityId = "$OpportunityId"
        ProspectId    = "$($resp.RelatedProspectId)"
        Note          = "$($resp.OpportunityNote)"
        Status        = $(if ($fields.ContainsKey('Status'))      { "$($fields['Status'].Value)" }      else { "" })
        OppStage      = $(if ($fields.ContainsKey('mx_Custom_2')) { "$($fields['mx_Custom_2'].Value)" } else { "" })
        Fields        = $fields
        Raw           = $resp
    }
}


function Assert-LsqOpportunityFieldMap {
    <#
      Fails loud if LeadSquared has renumbered a custom field.

      Reading mx_Custom_6 and hoping it is still Expected Deal Size is exactly how a silent
      wrong number gets shipped - and an unlabelled empty field is NOT a missing field
      (gotcha 24). A blank DisplayName is tolerated; a DIFFERENT one is fatal.
    #>
    param([Parameter(Mandatory)]$DetailResponse)

    $seen = @{}
    foreach ($f in @($DetailResponse.Fields)) {
        if ($f.SchemaName) { $seen["$($f.SchemaName)"] = "$($f.DisplayName)".Trim() }
    }
    foreach ($m in $Script:OpportunityFieldMap) {
        if (-not $seen.ContainsKey($m.Schema)) { continue }
        $dn = $seen[$m.Schema]
        if ($dn -and $dn -ne $m.Expect) {
            throw "FIELD MAPPING DRIFT: $($m.Schema) is now '$dn', expected '$($m.Expect)'. Stopping before reading or writing a wrong field."
        }
    }
}


function Set-LsqOpportunity {
    <#
      Update fields on an existing opportunity.

      The body is FLAT - ProspectOpportunityId plus a Fields array, with NO Opportunity{} or
      LeadDetails[] wrapper. The wrapped shape throws ArgumentNullException("source") on every
      call. Confirmed against apidocs 2026-07-29.

      There is a several-second propagation delay before an independent re-fetch reflects the
      write, so this does NOT verify. Pair it with Confirm-LsqOpportunityWrite (hard rule 3).
    #>
    param(
        [Parameter(Mandatory)][string]$OpportunityId,
        [Parameter(Mandatory)][hashtable]$Fields,      # @{ Status='Lost'; mx_Custom_2='Closed - Lost' }
        [string]$Note,
        [AllowNull()][hashtable]$Config
    )
    if ($Fields.Count -eq 0) { throw "Set-LsqOpportunity called with no fields for $OpportunityId." }

    $cfg  = Get-LsqOpportunityConfig $Config
    $base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
    $url  = "$base/OpportunityManagement.svc/Update?accessKey=$ak&secretKey=$sk"

    $fieldList = @()
    foreach ($k in $Fields.Keys) { $fieldList += @{ SchemaName = "$k"; Value = "$($Fields[$k])" } }

    $payload = @{ ProspectOpportunityId = $OpportunityId; Fields = $fieldList }
    if ($Note) { $payload['OpportunityNote'] = $Note }

    # Gotcha 12's single-element-array collapse does NOT apply here: verified on 5.1.26100.8972
    # (2026-08-14) that a hashtable MEMBER holding a one-element array still serialises as a
    # JSON array. The collapse bites a bare array in the pipeline, not this shape. Asserted
    # below anyway - a silent shape change here would 400 every single-field update.
    $body = $payload | ConvertTo-Json -Depth 6
    if ($body -notmatch '"Fields"\s*:\s*\[') {
        throw "Set-LsqOpportunity: Fields serialised as an object rather than an array for $OpportunityId. The endpoint would reject this. Body: $body"
    }

    $r = Invoke-LsqPost -Uri $url -JsonBody $body
    if ("$($r.Status)" -ne "Success") {
        throw "Opportunity $OpportunityId update FAILED -> $($r | ConvertTo-Json -Compress -Depth 4)"
    }
    return $r
}


function New-LsqOpportunity {
    <#
      Create an opportunity on a lead.

      Capture does NOT dedupe - it returns "IsUnique": true for a genuine duplicate - so this
      existence-checks first by default and throws rather than creating a second deal. That
      matters more here than anywhere else in the repo: opportunity deletion is blocked at the
      object level, so a wrongly created deal is PERMANENT.

      mx_Custom_1 (Opportunity Name) is mandatory; omitting it fails with
      MXInvalidActivityFieldsException.
    #>
    param(
        [Parameter(Mandatory)][string]$ProspectId,
        [Parameter(Mandatory)][string]$OpportunityName,
        [Parameter(Mandatory)][ValidateSet('Open','Won','Lost')][string]$Status,
        [Parameter(Mandatory)][string]$OppStage,
        [string]$OwnerId,
        [string]$Note,
        [AllowNull()][hashtable]$ExtraFields,
        [AllowNull()][hashtable]$Config,
        [switch]$SkipExistenceCheck
    )
    if ([string]::IsNullOrWhiteSpace($OpportunityName)) {
        throw "Lead $ProspectId : Opportunity Name is mandatory and was blank - refusing to call Capture."
    }
    if ($Script:OpportunityStages.Contains($Status) -and $Script:OpportunityStages[$Status] -notcontains $OppStage) {
        throw "Stage '$OppStage' is not valid under Status '$Status'. Valid: $($Script:OpportunityStages[$Status] -join ', ')."
    }

    $cfg = Get-LsqOpportunityConfig $Config

    if (-not $SkipExistenceCheck) {
        $existing = Get-LsqOpportunitiesOfLead -ProspectId $ProspectId -Config $cfg
        if ($existing.Count -gt 0) {
            throw "Lead $ProspectId already has $($existing.Count) opportunity(ies) [$(($existing | ForEach-Object { $_.OppStage }) -join ', ')]. Refusing to create a duplicate."
        }

        # GetOpportunitiesOfLead ALONE IS NOT ENOUGH. Verified live 2026-08-14: a deal created
        # minutes earlier was fully readable via GetOpportunityDetails and present on the
        # activity trail, while GetOpportunitiesOfLead reported 0 deals for its lead - it is
        # index-backed and lags. Trusting it by itself is how a "this Prospect has no deal"
        # create produces a second deal on an account that already had one.
        #
        # The trail (EventCode 12000) is authoritative and immediate. EventCode 33 is its
        # fieldless shadow and must never be counted as a deal (gotcha 14).
        if (Get-Command Get-LeadActivities -ErrorAction SilentlyContinue) {
            try {
                $trailDeals = @(Get-LeadActivities -ProspectId $ProspectId -Config $cfg |
                    Where-Object { "$($_.EventCode)" -eq $Script:OPP_TYPE_ID })
                if ($trailDeals.Count -gt 0) {
                    throw "Lead $ProspectId has $($trailDeals.Count) opportunity(ies) on its ACTIVITY TRAIL that GetOpportunitiesOfLead did not return (it lags for recent records). Refusing to create a duplicate. Trail ids: $(($trailDeals | ForEach-Object { $_.Id }) -join ', ')"
                }
            } catch {
                if ("$($_.Exception.Message)" -like "*Refusing to create a duplicate*") { throw }
                Write-Warning "Lead $ProspectId : trail cross-check failed ($($_.Exception.Message)). Proceeding on GetOpportunitiesOfLead alone - re-verify this create."
            }
        }
    }

    $base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
    $url  = "$base/OpportunityManagement.svc/Capture?accessKey=$ak&secretKey=$sk"

    $fieldList = @(
        @{ SchemaName = "Status";      Value = $Status },
        @{ SchemaName = "mx_Custom_1"; Value = $OpportunityName },
        @{ SchemaName = "mx_Custom_2"; Value = $OppStage }
    )
    if ($OwnerId) { $fieldList += @{ SchemaName = "Owner"; Value = $OwnerId } }
    if ($ExtraFields) {
        foreach ($k in $ExtraFields.Keys) { $fieldList += @{ SchemaName = "$k"; Value = "$($ExtraFields[$k])" } }
    }

    $body = @{
        LeadDetails = @(
            @{ Attribute = "ProspectID";             Value = $ProspectId },
            @{ Attribute = "SearchBy";               Value = "ProspectId" },
            @{ Attribute = "__UseUserDefinedGuid__"; Value = "true" }
        )
        Opportunity = @{
            OpportunityEventCode       = [int]$Script:OPP_TYPE_ID
            OpportunityNote            = $(if ($Note) { $Note } else { "" })
            UpdateEmptyFields          = $true
            DoNotPostDuplicateActivity = $false
            DoNotChangeOwner           = $false
            Fields                     = $fieldList
        }
    } | ConvertTo-Json -Depth 8

    $r = Invoke-LsqPost -Uri $url -JsonBody $body
    if (-not ($r.Status -eq 0 -and $r.CreatedOpportunityId)) {
        throw "Lead $ProspectId : Opportunity create FAILED -> $($r | ConvertTo-Json -Compress -Depth 4)"
    }
    return "$($r.CreatedOpportunityId)"
}


function Remove-LsqOpportunity {
    <#
      Delete an opportunity. IRREVERSIBLE - there is no undelete and no recycle bin.

      Contract per apidocs.leadsquared.com/delete-an-opportunity/ (read 2026-08-14):
        GET OpportunityManagement.svc/Delete?accessKey=&secretKey=&Id=<opportunityId>
        success -> { "Status":"Success", "Message":{ "IsSuccessful":true } }

      THE PARAMETER IS `Id`, NOT `opportunityId`. Every other opportunity endpoint in this API
      keys on `opportunityId`, so the natural guess is wrong here - and the wrong name does not
      error, it just fails to delete, which reads as "deletion is blocked at the object level".
      That is very likely how `CanDelete: false` got into docs/AUTOMATION_CAPABILITIES.md; the
      live type reports CanDelete=True.

      Requires "Allow Delete" on the Opportunity Type (it is on, verified 2026-08-14).
      Documented rate limit: 25 calls per 5 seconds - space bulk deletes at >= 200ms.

      Named with an approved verb deliberately: a short helper like `Del` would be shadowed by
      the built-in `del` -> Remove-Item alias and silently try to delete a file path (gotcha 22).

      Does NOT verify. Pair with Confirm-LsqOpportunityRemoved (hard rule 3).
    #>
    param(
        [Parameter(Mandatory)][string]$OpportunityId,
        [AllowNull()][hashtable]$Config
    )
    $cfg  = Get-LsqOpportunityConfig $Config
    $base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
    $url  = "$base/OpportunityManagement.svc/Delete?accessKey=$ak&secretKey=$sk&Id=$OpportunityId"

    $r = Invoke-LsqWithRetry -What "delete opportunity $OpportunityId" -Action {
        (Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
    }
    if ("$($r.Status)" -ne "Success" -or -not (Test-LsqTrue $r.Message.IsSuccessful)) {
        throw "Opportunity $OpportunityId delete FAILED -> $($r | ConvertTo-Json -Compress -Depth 4)"
    }
    return $r
}


function Confirm-LsqOpportunityRemoved {
    <#
      Prove a delete actually happened, by independently re-reading the opportunity.
      A "Success" body is not sufficient (hard rule 3).

      A DELETED opportunity's detail read returns HTTP 500, not 404 (verified live 2026-08-14).
      That matters for cost: 500 is classified transient, so routing this through
      Get-LsqOpportunityDetails would burn all four retry attempts plus backoff - about 14
      seconds - on every successful delete, which over ~1,000 deletes is nearly four hours of
      pure waiting. So this issues a single raw request with NO retry wrapper and reads the
      status code directly.

      Returns $true when the record is gone.
    #>
    param(
        [Parameter(Mandatory)][string]$OpportunityId,
        [int]$MaxWaitSeconds = 30,
        [int]$PollSeconds = 5,
        [AllowNull()][hashtable]$Config
    )
    $cfg  = Get-LsqOpportunityConfig $Config
    $base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
    $url  = "$base/OpportunityManagement.svc/GetOpportunityDetails?accessKey=$ak&secretKey=$sk&opportunityId=$OpportunityId"

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $present = $true
        try {
            $resp = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -ErrorAction Stop
            $body = $resp.Content | ConvertFrom-Json
            # A deleted record can also come back as an empty envelope rather than an error.
            if ($null -eq $body -or @($body.Fields).Count -eq 0) { $present = $false }
        } catch {
            # 500 (observed) or 404 both mean gone. Anything else is a genuine transport
            # problem and must NOT be reported as a successful deletion.
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -eq 500 -or $code -eq 404) { $present = $false }
            else { throw }
        }
        if (-not $present) { $sw.Stop(); return $true }
        if ($sw.Elapsed.TotalSeconds -ge $MaxWaitSeconds) { $sw.Stop(); return $false }
        Start-Sleep -Seconds $PollSeconds
    }
}


function Confirm-LsqOpportunityWrite {
    <#
      THE HARD-RULE-3 PRIMITIVE. Independently re-fetch and prove the write landed.

      Reads back through GetOpportunityDetails - a DIFFERENT endpoint from the Update that
      wrote, and the only one that returns mx_Custom_4 - and polls, because Update takes
      several seconds to propagate. A "Success" response body alone is not sufficient.

      Returns @{ Ok; Observed; Mismatches; WaitedSeconds }. Never throws on a mismatch; the
      caller decides whether to abort.
    #>
    param(
        [Parameter(Mandatory)][string]$OpportunityId,
        [Parameter(Mandatory)][hashtable]$Expected,     # schema name -> expected value
        [int]$MaxWaitSeconds = 90,
        [int]$PollSeconds = 5,
        [AllowNull()][hashtable]$Config
    )
    $cfg = Get-LsqOpportunityConfig $Config
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $observed = @{}
    $mismatches = @()

    while ($true) {
        $mismatches = @()
        try {
            $d = Get-LsqOpportunityDetails -OpportunityId $OpportunityId -Config $cfg
            foreach ($k in $Expected.Keys) {
                $actual = if ($d.Fields.ContainsKey($k)) { "$($d.Fields[$k].Value)".Trim() } else { $null }
                $observed[$k] = $actual
                $want = "$($Expected[$k])".Trim()
                if ($actual -ne $want) { $mismatches += "$k : expected '$want', found '$actual'" }
            }
        } catch {
            $mismatches = @("read-back threw: $($_.Exception.Message)")
        }

        if ($mismatches.Count -eq 0) { break }
        if ($sw.Elapsed.TotalSeconds -ge $MaxWaitSeconds) { break }
        Start-Sleep -Seconds $PollSeconds
    }

    $sw.Stop()
    return @{
        Ok            = ($mismatches.Count -eq 0)
        Observed      = $observed
        Mismatches    = $mismatches
        WaitedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}


function Get-LsqOpportunityStageRank {
    <#
      Rank for an opportunity stage, or $null plus a warning for a value not in the taxonomy.

      Never returns 0 for an unknown value. $Script:OpportunityStageRank was missing
      'Requirement Gathering' until 2026-08-14, so the lookup returned $null - and PowerShell
      evaluates ($null -lt 1) as $true, which made a warm deal lose every "keep the furthest
      advanced" duplicate contest to a brand-new one. Route every rank comparison through here
      and treat $null as "stop and ask", not as "lowest".
    #>
    param([AllowNull()][string]$StageValue)

    $s = "$StageValue".Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($Script:OpportunityStageRank.Contains($s)) { return [int]$Script:OpportunityStageRank[$s] }
    Write-Warning "Opportunity stage '$s' is not in `$Script:OpportunityStageRank - it has no rank and cannot be compared. Add it to scripts/lib/schema.ps1 and to opp_stage_rank() in the warehouse."
    return $null
}


function Test-LsqForecastValue {
    <#
      Is Expected Deal Size a real, forecastable number?
      0 is LeadSquared's untouched-numeric default and does NOT count as filled.
    #>
    param([AllowNull()]$DealValue)
    if ($null -eq $DealValue) { return $false }
    $s = "$DealValue".Trim()
    if ($s -eq "") { return $false }
    $d = 0.0
    if (-not [double]::TryParse($s, [ref]$d)) { return $false }
    return ($d -gt 0)
}


function Test-LsqForecastDate {
    param([AllowNull()]$CloseDate)
    if ($null -eq $CloseDate) { return $false }
    return ("$CloseDate".Trim() -ne "")
}


function Test-LsqOpportunityIsTestRecord {
    <#
      Probe and automation-test leftovers. They cannot be deleted, so they must be excluded
      from every count instead.
    #>
    param([AllowNull()]$Opportunity)
    if ($null -eq $Opportunity) { return $false }
    $hay = "$($Opportunity.Name) $($Opportunity.Note)"
    foreach ($m in $Script:OpportunityTestMarkers) {
        if ($hay -like "*$m*") { return $true }
    }
    return $false
}


function Get-LsqEverProspectStageValues {
    <#
      Every stage string that MEANS the contact reached a deal stage - current or legacy.

      Derived from $Script:StageMap rather than hand-written (hard rule 2), so a legacy value
      added to the map later is picked up here for free. As of 2026-08-14 this resolves to:
        Prospect, Customer, Requirement Gathering, Requirement Gathering (Warm),
        Conversation In Progress (Hot), Contract Follow Up, Payment Received

      'Follow Up' is deliberately NOT in the set - schema.ps1 maps it to Engaged, not Prospect.
      'Customer' and 'Payment Received' are, because reaching Customer necessarily passed
      through Prospect.
    #>
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @('Prospect','Customer')) { [void]$out.Add($v) }
    foreach ($kv in $Script:StageMap.GetEnumerator()) {
        if ($kv.Value.Contact -eq 'Prospect' -or $kv.Value.Contact -eq 'Customer') { [void]$out.Add("$($kv.Key)") }
    }
    return @($out.ToArray() | Sort-Object -Unique)
}


function New-LsqForecastWorklistSheets {
    <#
      Build the $Sheets array for New-XlsxWorkbook (scripts/lib/xlsx.ps1): one combined sheet
      plus one WL_<rep> tab per rep, so a rep can be handed only their own rows.

      Rows are expected to carry: rep, company, contact, opportunity, opp_stage, status,
      days_open, last_call_ist, deal_value, close_date, prospect_id, opportunity_id.

      The deal_value and close_date cells are written BLANK when missing. Never defaulted,
      never zero-filled - a placeholder here becomes a fabricated forecast the moment anyone
      sums the column.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [int]$MaxRepSheets = 30
    )
    $headers = @('Rep','Company','Contact','Opportunity','Deal Stage','Status',
                 'Days Open','Last Call (IST)','Expected Deal Size','Expected Closure Date',
                 'Prospect Id','Opportunity Id')

    $toRow = {
        param($r)
        @(
            "$($r.rep)", "$($r.company)", "$($r.contact)", "$($r.opportunity)",
            "$($r.opp_stage)", "$($r.status)",
            $(if ($null -ne $r.days_open) { [int]$r.days_open } else { "" }),
            "$($r.last_call_ist)",
            $(if (Test-LsqForecastValue $r.deal_value) { [double]$r.deal_value } else { "" }),
            $(if (Test-LsqForecastDate  $r.close_date) { "$($r.close_date)" }   else { "" }),
            "$($r.prospect_id)", "$($r.opportunity_id)"
        )
    }

    $sheets = @()
    $sheets += @{
        Name    = 'Forecast_Worklist'
        Headers = $headers
        Rows    = @($Rows | ForEach-Object { & $toRow $_ })
    }

    $byRep = $Rows | Group-Object { "$($_.rep)" } | Sort-Object Count -Descending
    $n = 0
    foreach ($g in $byRep) {
        $n++
        if ($n -gt $MaxRepSheets) { break }
        # Excel sheet names: 31 chars max, and : \ / ? * [ ] are illegal.
        $safe = ($g.Name -replace '[:\\/?*\[\]]', ' ').Trim()
        $nm = "WL_$safe"
        if ($nm.Length -gt 31) { $nm = $nm.Substring(0, 31) }
        $sheets += @{
            Name    = $nm
            Headers = $headers
            Rows    = @($g.Group | ForEach-Object { & $toRow $_ })
        }
    }
    return $sheets
}
