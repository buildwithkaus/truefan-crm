<#
.SYNOPSIS
  Load the FULL opportunity record - deal size, closure dates, loss reason, contract dates -
  into fact_opportunity.

.DESCRIPTION
  Neither of the two sources the pipeline already reads carries these fields:

    ProspectActivity.svc/Retrieve (EventCode 12000)   mx_Custom_1, _2, Status, Owner. That is all.
    OpportunityManagement.svc/GetOpportunitiesOfLead   adds only mx_Custom_6 and _8.

  OpportunityManagement.svc/GetOpportunityDetails returns all 29 fields WITH DisplayName and
  DataType - it is also, incidentally, the opportunity field-metadata endpoint that
  docs/LSQ_API_GOTCHAS.md recorded as not existing.

  It is a GET keyed on opportunityId, and that id is the SAME GUID as the activity id already
  stored in fact_opportunity - so there is no lookup pass. One call per deal.

  Field names are never hardcoded against position: the response carries SchemaName and
  DisplayName together, so the mapping below is asserted against the live DisplayName and the
  script FAILS LOUD if LeadSquared renumbers a field. Reading mx_Custom_6 and hoping it is
  still Expected Deal Size is exactly how a silent wrong number gets shipped.

  READ-ONLY against LeadSquared.

.EXAMPLE
  pwsh ./scripts/pipeline/08-load-opportunity-details.ps1 -Limit 25      # smoke test
  pwsh ./scripts/pipeline/08-load-opportunity-details.ps1                # all of them

.NOTES
  ASCII only. One API call per opportunity - run outside 09:00-20:00 IST for the full pass.
#>

param(
    [int]$Limit = 0,          # 0 = every opportunity
    [int]$SleepMs = 250,
    [switch]$OnlyMissing      # skip ones already loaded
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$cfg  = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
foreach ($kk in @("SUPABASE_URL","SUPABASE_SERVICE_KEY")) { if (-not $cfg[$kk]) { throw "Missing $kk in config\.env" } }
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/'); $sbKey = $cfg['SUPABASE_SERVICE_KEY']
$sbHead = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_details_log.txt"

Write-LsqLog "=== Opportunity detail load ===" $logPath

# ---------------------------------------------------------------------------------------
# The mapping. Schema name -> warehouse column, with the DisplayName we EXPECT to find.
# The expectation is asserted on every record; a rename or renumber stops the run rather
# than quietly loading Actual Deal Size into the expected-value column.
# ---------------------------------------------------------------------------------------
$Map = @(
    @{ Schema='mx_Custom_6';  Expect='Expected Deal Size';    Col='deal_value';          Type='num'  },
    @{ Schema='mx_Custom_7';  Expect='Actual Deal Size';      Col='actual_deal_value';   Type='num'  },
    @{ Schema='mx_Custom_8';  Expect='Expected Closure Date'; Col='expected_close_date'; Type='date' },
    @{ Schema='mx_Custom_9';  Expect='Actual Closure Date';   Col='actual_close_date';   Type='date' },
    @{ Schema='mx_Custom_4';  Expect='Loss Reason';           Col='loss_reason';         Type='text' },
    @{ Schema='mx_Custom_3';  Expect='Source';                Col='source';              Type='text' },
    @{ Schema='mx_Custom_5';  Expect='Description';           Col='description';         Type='text' },
    @{ Schema='mx_Custom_10'; Expect='Product';               Col='product';             Type='text' },
    @{ Schema='mx_Custom_13'; Expect='Celebrity Assigned';    Col='celebrity_assigned';  Type='text' },
    @{ Schema='mx_Custom_14'; Expect='Contract Start Date';   Col='contract_start_date'; Type='date' },
    @{ Schema='mx_Custom_15'; Expect='Contract End Date';     Col='contract_end_date';   Type='date' },
    @{ Schema='mx_Custom_16'; Expect='Agreement Sent Date';   Col='agreement_sent_date'; Type='date' },
    @{ Schema='mx_Custom_17'; Expect='Invoice Sent Date';     Col='invoice_sent_date';   Type='date' },
    @{ Schema='mx_Custom_1';  Expect='Opportunity Name';      Col='opportunity_name';    Type='text' },
    @{ Schema='mx_Custom_2';  Expect='Stage';                 Col='stage';               Type='text' },
    @{ Schema='Status';       Expect='Deal Stage';            Col='status';              Type='text' }
)

# ---------------------------------------------------------------------------------------
# Which opportunities to load.
# ---------------------------------------------------------------------------------------
function Get-SbAll {
    param([string]$Query)
    $out = New-Object System.Collections.Generic.List[object]
    $offset = 0
    while ($true) {
        $sep = if ($Query -match '\?') { '&' } else { '?' }
        $uri = "$sbUrl/rest/v1/$Query$sep" + "limit=1000&offset=$offset"
        $page = ((Invoke-WebRequest -Uri $uri -Headers $sbHead -UseBasicParsing).Content | ConvertFrom-Json)
        $n = @($page).Count
        if ($n -eq 0) { break }
        foreach ($r in $page) { [void]$out.Add($r) }
        if ($n -lt 1000) { break }
        $offset += 1000
    }
    return $out.ToArray()
}

$filter = "fact_opportunity?select=activity_id,prospect_id&order=activity_id"
if ($OnlyMissing) { $filter = "fact_opportunity?select=activity_id,prospect_id&details_loaded_at=is.null&order=activity_id" }
$todo = Get-SbAll $filter
if ($Limit -gt 0 -and $todo.Count -gt $Limit) { $todo = $todo[0..($Limit-1)] }
Write-LsqLog "Opportunities to load: $($todo.Count)" $logPath
if ($todo.Count -eq 0) { Write-LsqLog "Nothing to do." $logPath; return }

function ConvertTo-SbValue {
    param($Raw, [string]$Type)
    $v = "$Raw".Trim()
    if ($v -eq "") { return $null }
    switch ($Type) {
        'num'  {
            $n = 0.0
            if ([double]::TryParse($v, [ref]$n)) { return $n }
            return $null
        }
        'date' {
            # LSQ hands these back as "2026-08-31 08:38:00". ConvertFrom-LsqUtc handles the
            # with- and without-milliseconds forms (gotcha 17); anything it cannot read
            # becomes null rather than a wrong date.
            $d = ConvertFrom-LsqUtc $v
            if ($null -eq $d) { return $null }
            return $d.ToString("yyyy-MM-dd")
        }
        default { return $v }
    }
}

# ---------------------------------------------------------------------------------------
# Pull and upsert, in batches.
# ---------------------------------------------------------------------------------------
$cols = @('activity_id','prospect_id','details_loaded_at','opportunity_id','opportunity_note') +
        ($Map | ForEach-Object { $_.Col })
$cols = $cols | Select-Object -Unique

$batch = New-Object System.Collections.Generic.List[object]
$done = 0; $failed = 0; $withValue = 0; $withDate = 0; $withActual = 0

function Send-Batch {
    if ($batch.Count -eq 0) { return }
    $rows = @()
    foreach ($r in $batch) {
        $o = [ordered]@{}
        foreach ($c in $cols) { $o[$c] = $r[$c] }
        $rows += ,$o
    }
    # PGRST102: every object in a bulk upsert must carry an identical key set, which the
    # fixed $cols projection above guarantees.
    $json = $rows | ConvertTo-Json -Depth 5 -Compress
    if ($rows.Count -eq 1) { $json = "[$json]" }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $h = @{ apikey=$sbKey; Authorization="Bearer $sbKey"; Prefer="resolution=merge-duplicates,return=minimal" }
    [void](Invoke-LsqWithRetry -What "upsert details" -Action {
        try {
            Invoke-RestMethod -Uri "$sbUrl/rest/v1/fact_opportunity" -Method Post -Body $bytes `
                -Headers $h -ContentType "application/json; charset=utf-8" -ErrorAction Stop
        } catch {
            $d = $_.ErrorDetails.Message
            if (-not $d -and $_.Exception.Response) {
                $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                $d = $sr.ReadToEnd(); $sr.Close()
            }
            throw "upsert failed: $($_.Exception.Message) :: $d"
        }
    })
    $batch.Clear()
}

foreach ($t in $todo) {
    $oppId = $t.activity_id
    $url = "$base/OpportunityManagement.svc/GetOpportunityDetails?opportunityId=$oppId&accessKey=$ak&secretKey=$sk"
    try {
        $resp = Invoke-LsqWithRetry -What "detail $oppId" -Action {
            (Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
        }
    } catch { $failed++; Start-Sleep -Milliseconds $SleepMs; continue }

    $fields = @{}
    foreach ($f in @($resp.Fields)) {
        if ($f.SchemaName) { $fields[$f.SchemaName] = $f }
    }

    $row = @{
        activity_id       = $oppId
        prospect_id       = "$($resp.RelatedProspectId)"
        opportunity_id    = $oppId
        opportunity_note  = "$($resp.OpportunityNote)"
        details_loaded_at = ([datetime]::UtcNow).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    }
    if (-not $row.prospect_id) { $row.prospect_id = "$($t.prospect_id)" }

    foreach ($m in $Map) {
        $f = $fields[$m.Schema]
        if (-not $f) { $row[$m.Col] = $null; continue }
        # Assert the field still means what the mapping says. A renumber would otherwise load
        # Actual Deal Size into the expected-value column and look entirely plausible.
        $dn = "$($f.DisplayName)".Trim()
        if ($dn -and $dn -ne $m.Expect) {
            throw "FIELD MAPPING DRIFT: $($m.Schema) is now '$dn', expected '$($m.Expect)'. Stopping before writing a wrong number."
        }
        $row[$m.Col] = ConvertTo-SbValue -Raw $f.Value -Type $m.Type
    }

    if ($null -ne $row['deal_value'])          { $withValue++ }
    if ($null -ne $row['expected_close_date']) { $withDate++ }
    if ($null -ne $row['actual_deal_value'])   { $withActual++ }

    [void]$batch.Add($row)
    $done++
    if ($batch.Count -ge 100) { Send-Batch }
    if ($done % 200 -eq 0) {
        Write-LsqLog "  $done/$($todo.Count) | value $withValue | close date $withDate | actual $withActual" $logPath
    }
    Start-Sleep -Milliseconds $SleepMs
}
Send-Batch

Write-LsqLog "" $logPath
Write-LsqLog "=== done ===" $logPath
Write-LsqLog "  loaded              : $done  (failed $failed)" $logPath
Write-LsqLog "  Expected Deal Size  : $withValue" $logPath
Write-LsqLog "  Expected Close Date : $withDate" $logPath
Write-LsqLog "  Actual Deal Size    : $withActual" $logPath
Write-LsqLog "" $logPath
Write-LsqLog "Verify independently rather than trusting this line:" $logPath
Write-LsqLog "  GET /rest/v1/v_forecast_quality?select=*" $logPath
