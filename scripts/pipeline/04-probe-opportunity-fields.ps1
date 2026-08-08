<#
.SYNOPSIS
  Enumerate the real Opportunity schema from live data - specifically, whether deal size and
  expected closure date exist as fields and what they are actually called.

.DESCRIPTION
  The forecast tab cannot be built on guessed field names. Hard rule 2 of this repo: never
  hand-write a field or dropdown string, enumerate it from live data. Two false negatives have
  already come from reading one doc page instead of probing.

  This probes, in order:
    1. Opportunity metadata endpoints (candidate names - most will 404, that is the point)
    2. GetOpportunitiesOfLead on a real Prospect-stage lead, which is the ONE per-lead
       opportunity read confirmed working on this account
    3. The EventCode 12000 activity as it appears on the trail

  Then it prints the union of every key seen, so the schema can be written against reality.

  READ-ONLY. Safe to run any time, costs about a dozen API calls.

.NOTES
  ASCII only. $ErrorActionPreference is deliberately Continue here - a 404 on a candidate
  endpoint is the expected result, not a failure.
#>

param(
    [int]$SampleLeads = 12
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$cfg  = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']
$ak   = $cfg['LSQ_ACCESS_KEY']
$sk   = $cfg['LSQ_SECRET_KEY']

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_probe_log.txt"

Write-LsqLog "=== Opportunity schema probe ===" $logPath

# ---------------------------------------------------------------------------------------
# 1. Find real Prospect-stage leads. Only these can own an opportunity (primary-contact rule),
#    so probing anything else would return an empty list that looks like a broken endpoint.
# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- finding Prospect-stage leads ---" $logPath

$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "ProspectStage"; LookupValue = "__NoSuchStage__"; SqlOperator = "="
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Write-LsqLog "Negative control (ProspectStage=__NoSuchStage__): $($neg.Count) rows -- must be 0" $logPath
if ($neg.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the ProspectStage filter is being ignored." }

$leads = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "ProspectStage"; LookupValue = "Prospect"; SqlOperator = "="
} -ColumnsCsv "ProspectID,FirstName,CompanyName,OwnerIdName" -PageSize $SampleLeads `
  -SortColumn "ProspectActivityDate_Max" -SortDirection "1"))
Write-LsqLog "Prospect-stage sample: $($leads.Count) leads" $logPath
if ($leads.Count -eq 0) { throw "No Prospect-stage leads found - cannot probe opportunities." }

# ---------------------------------------------------------------------------------------
# 2. Candidate metadata endpoints. Most are expected to 404; the probe exists to find which
#    one does not, and to record the negative result so nobody re-guesses later.
# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- metadata endpoint candidates ---" $logPath

# NOTE the path shape. The working per-lead read is OpportunityManagement.svc/<Method> - there
# is NO /Opportunity/ segment. A first pass at this probe inserted one and got a clean 404 on
# every candidate, which reads exactly like "the endpoint does not exist" rather than "the URL
# is wrong". Same family as gotcha 2: a plausible-looking zero is not evidence.
$candidates = @(
    "OpportunityManagement.svc/GetMetaData?opportunityEvent=12000",
    "OpportunityManagement.svc/Opportunity.GetMetaData?opportunityEvent=12000",
    "OpportunityManagement.svc/Metadata.Get?opportunityEvent=12000",
    "OpportunityManagement.svc/Fields.Get?opportunityEvent=12000",
    "OpportunityManagement.svc/GetOpportunityTypes",
    "OpportunityManagement.svc/OpportunityType.Get",
    "ProspectActivity.svc/GetActivityMetaData?activityEvent=12000",
    "CustomActivity.svc/GetMetaData?activityEvent=12000"
)

$metaHits = New-Object System.Collections.Generic.List[object]
foreach ($c in $candidates) {
    $url = "$base/$c&accessKey=$ak&secretKey=$sk"
    if ($c -notmatch '\?') { $url = "$base/$c`?accessKey=$ak&secretKey=$sk" }
    try {
        $r = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -ErrorAction Stop
        $body = $r.Content | ConvertFrom-Json
        Write-LsqLog ("  HIT  {0}" -f $c) $logPath
        $metaHits.Add([pscustomobject]@{ endpoint = $c; body = $body })
    } catch {
        $code = "?"
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-LsqLog ("  {0,-4} {1}" -f $code, $c) $logPath
    }
    Start-Sleep -Milliseconds 300
}

# ---------------------------------------------------------------------------------------
# 3. The confirmed-working per-lead read. This is the authoritative answer: whatever fields
#    a real opportunity carries will be in this response.
# ---------------------------------------------------------------------------------------
Write-LsqLog "" $logPath
Write-LsqLog "--- GetOpportunitiesOfLead on real Prospect leads ---" $logPath

$allKeys   = @{}
$fieldSeen = @{}
$samples   = New-Object System.Collections.Generic.List[object]
$found     = 0

foreach ($lead in $leads) {
    $leadId = $lead.ProspectID
    if (-not $leadId) { continue }
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead" +
           "?accessKey=$ak&secretKey=$sk&leadId=$leadId&opportunityType=12000"
    # POST, despite taking every parameter on the query string and reading nothing. A GET
    # returns 405. Confirmed against scripts/migration/03-backup.ps1, which has been calling
    # it in production since Phase 3.
    try {
        $r    = Invoke-WebRequest -Uri $url -Method Post -Body "" `
                    -ContentType "application/json" -UseBasicParsing -ErrorAction Stop
        $resp = $r.Content | ConvertFrom-Json
        $opps = @(Expand-LsqRows $resp.List)
    } catch {
        $code = "?"
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        Write-LsqLog ("  {0} -> HTTP {1}" -f $leadId, $code) $logPath
        Start-Sleep -Milliseconds 300
        continue
    }

    if ($opps.Count -eq 0) { Start-Sleep -Milliseconds 300; continue }
    $found += $opps.Count

    foreach ($o in $opps) {
        foreach ($p in $o.PSObject.Properties) {
            if (-not $allKeys.ContainsKey($p.Name)) { $allKeys[$p.Name] = 0 }
            if ($null -ne $p.Value -and "$($p.Value)".Trim() -ne "") { $allKeys[$p.Name]++ }
        }
        # The editable fields arrive as a Fields array of {SchemaName, DisplayName, Value}.
        # Other containers are walked too in case a field lives somewhere else on this
        # account - cheap, and the alternative is assuming.
        foreach ($container in @('Fields','OpportunityFields','ActivityFields')) {
            $c = $o.$container
            if (-not $c) { continue }
            foreach ($f in @(Expand-LsqRows $c)) {
                $name = $f.SchemaName; if (-not $name) { $name = $f.Key }
                if (-not $name) { continue }
                $val = $f.Value
                if (-not $fieldSeen.ContainsKey($name)) {
                    $fieldSeen[$name] = [pscustomobject]@{
                        SchemaName  = $name
                        DisplayName = $f.DisplayName
                        DataType    = $f.DataType
                        Filled      = 0
                        Sample      = $null
                    }
                }
                if ($null -ne $val -and "$val".Trim() -ne "") {
                    $fieldSeen[$name].Filled++
                    if (-not $fieldSeen[$name].Sample) { $fieldSeen[$name].Sample = "$val" }
                }
            }
        }
        if ($samples.Count -lt 3) { $samples.Add($o) }
    }
    Start-Sleep -Milliseconds 300
}

Write-LsqLog "Opportunities found across the sample: $found" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "--- top-level keys on the opportunity object (filled / seen) ---" $logPath
foreach ($k in ($allKeys.Keys | Sort-Object)) {
    Write-LsqLog ("  {0,-40} filled on {1}" -f $k, $allKeys[$k]) $logPath
}

if ($fieldSeen.Count -gt 0) {
    Write-LsqLog "" $logPath
    Write-LsqLog "--- nested opportunity fields ---" $logPath
    foreach ($f in ($fieldSeen.Values | Sort-Object -Property @{E={-$_.Filled}}, SchemaName)) {
        Write-LsqLog ("  {0,-38} {1,-18} filled={2,-4} eg: {3}" -f `
            $f.SchemaName, $f.DataType, $f.Filled, $f.Sample) $logPath
    }
}

# ---------------------------------------------------------------------------------------
# 4. Dump the raw samples. The schema gets written against these, not against memory.
# ---------------------------------------------------------------------------------------
if ($samples.Count -gt 0) {
    $outPath = Join-Path $dataDir "opportunity_samples.json"
    $samples.ToArray() | ConvertTo-Json -Depth 12 | Set-Content -Path $outPath -Encoding UTF8
    Write-LsqLog "" $logPath
    Write-LsqLog "Wrote $($samples.Count) raw samples to data\opportunity_samples.json" $logPath
}

if ($metaHits.Count -gt 0) {
    $outPath = Join-Path $dataDir "opportunity_metadata.json"
    $metaHits.ToArray() | ConvertTo-Json -Depth 12 | Set-Content -Path $outPath -Encoding UTF8
    Write-LsqLog "Wrote $($metaHits.Count) metadata responses to data\opportunity_metadata.json" $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "Done. Deal size and closure date must be read off the list above, not guessed." $logPath
