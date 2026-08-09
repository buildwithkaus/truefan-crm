<#
.SYNOPSIS
  Measure how often each Opportunity custom field is actually filled in, sampled across every
  deal stage and status rather than only the recently-touched ones.

.DESCRIPTION
  CORRECTS AN EARLIER MISREADING. 04-probe-opportunity-fields.ps1 sampled 23 opportunities off
  20 recently-active Prospect-stage leads, saw mx_Custom_6 and mx_Custom_8 present but empty
  with no DisplayName in the payload, and concluded the account had no deal-value or
  closure-date field. Wrong. The API returns SCHEMA names only - the display names live in the
  LSQ form designer, where these are:

      mx_Custom_6   Expected Deal Size        Number
      mx_Custom_7   Actual Deal Size          Number
      mx_Custom_8   Expected Closure Date     DateTime
      mx_Custom_9   Actual Closure Date       DateTime
      mx_Custom_4   Loss Reason               String
      mx_Custom_16  Agreement Sent Date       DateTime
      mx_Custom_17  Invoice Sent Date         DateTime

  An unlabelled field in a payload is not a missing field. The question was never "do these
  exist" - it is "how often are they filled, and on which deals".

  That distinction decides the whole remediation: a missing field is an admin task, an empty
  field is a process problem, and the two get completely different plans.

  This samples ACROSS stage and status - Won deals especially, which the first probe never
  looked at and which are the ones most likely to carry an actual deal size.

  READ-ONLY.

.NOTES
  ASCII only. Needs SUPABASE_URL / SUPABASE_SERVICE_KEY in config\.env to pick the sample.
#>

param(
    [int]$PerBucket = 25
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\activity.ps1"

$cfg  = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/'); $sbKey = $cfg['SUPABASE_SERVICE_KEY']
$sbHead = @{ apikey = $sbKey; Authorization = "Bearer $sbKey" }

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "opportunity_population_log.txt"

# Display names, from the LSQ form designer. Kept here so the output is readable without
# cross-referencing, and so the next person does not repeat the mistake above.
$FieldNames = @{
    'mx_Custom_1'  = 'Opportunity Name'
    'mx_Custom_2'  = 'Deal Stage (dependent)'
    'mx_Custom_3'  = 'Source'
    'mx_Custom_4'  = 'Loss Reason'
    'mx_Custom_5'  = 'Description'
    'mx_Custom_6'  = 'Expected Deal Size'
    'mx_Custom_7'  = 'Actual Deal Size'
    'mx_Custom_8'  = 'Expected Closure Date'
    'mx_Custom_9'  = 'Actual Closure Date'
    'mx_Custom_10' = 'Product'
    'mx_Custom_11' = 'Origin'
    'mx_Custom_12' = 'Renewed From'
    'mx_Custom_13' = 'Celebrity Assigned'
    'mx_Custom_14' = 'Contract Start Date'
    'mx_Custom_15' = 'Contract End Date'
    'mx_Custom_16' = 'Agreement Sent Date'
    'mx_Custom_17' = 'Invoice Sent Date'
    'Status'       = 'Deal Stage (Open/Won/Lost)'
}

Write-LsqLog "=== Opportunity field population probe ===" $logPath

# ---------------------------------------------------------------------------------------
# Sample ACROSS buckets, not off the top of one sorted list. The first probe's whole error
# of scope was that it looked at one slice - recently-touched Prospect deals - and
# generalised from it.
# ---------------------------------------------------------------------------------------
function Get-SbRows {
    param([string]$Query)
    $sep = if ($Query -match '\?') { '&' } else { '?' }
    return @((Invoke-WebRequest -Uri "$sbUrl/rest/v1/$Query$sep" -Headers $sbHead -UseBasicParsing).Content | ConvertFrom-Json)
}

$buckets = Get-SbRows "fact_opportunity?select=stage,status&limit=2000"
$stageList = @($buckets | Group-Object stage, status | Sort-Object Count -Descending)
Write-LsqLog "Buckets present in the warehouse:" $logPath
foreach ($b in $stageList) { Write-LsqLog ("  {0,6}  {1}" -f $b.Count, $b.Name) $logPath }

$sample = New-Object System.Collections.Generic.List[object]
foreach ($b in $stageList) {
    $parts  = $b.Name -split ', '
    $stage  = $parts[0]
    $status = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $q = "fact_opportunity?select=prospect_id,stage,status&stage=eq." +
         [uri]::EscapeDataString($stage) + "&status=eq." + [uri]::EscapeDataString($status) +
         "&limit=$PerBucket"
    foreach ($r in (Get-SbRows $q)) { [void]$sample.Add($r) }
}
Write-LsqLog "" $logPath
Write-LsqLog "Sampling $($sample.Count) opportunities across $($stageList.Count) buckets" $logPath

# ---------------------------------------------------------------------------------------
# Read each one. POST with an empty body; there is NO /Opportunity/ path segment (gotcha 23).
# ---------------------------------------------------------------------------------------
$seen    = @{}   # schema name -> times returned at all
$filled  = @{}   # schema name -> times carrying a non-empty value
$byBucket = @{}
$examples = @{}
$read = 0; $failed = 0

foreach ($row in $sample) {
    $url = "$base/OpportunityManagement.svc/GetOpportunitiesOfLead" +
           "?accessKey=$ak&secretKey=$sk&leadId=$($row.prospect_id)&opportunityType=12000"
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post -Body "" -ContentType "application/json" `
                 -UseBasicParsing -ErrorAction Stop
        $opps = @(Expand-LsqRows (($r.Content | ConvertFrom-Json).List))
    } catch { $failed++; Start-Sleep -Milliseconds 250; continue }

    $key = "$($row.stage) / $($row.status)"
    if (-not $byBucket.ContainsKey($key)) {
        $byBucket[$key] = [pscustomobject]@{ N = 0; ExpSize = 0; ExpDate = 0; ActSize = 0; ActDate = 0; Loss = 0 }
    }

    foreach ($o in $opps) {
        $read++
        $byBucket[$key].N++
        foreach ($p in $o.PSObject.Properties) {
            if ($p.Name -notmatch '^mx_Custom_\d+$' -and $p.Name -ne 'Status') { continue }
            if (-not $seen.ContainsKey($p.Name))   { $seen[$p.Name] = 0 }
            if (-not $filled.ContainsKey($p.Name)) { $filled[$p.Name] = 0 }
            $seen[$p.Name]++
            $v = "$($p.Value)".Trim()
            if ($v -ne "") {
                $filled[$p.Name]++
                if (-not $examples.ContainsKey($p.Name)) { $examples[$p.Name] = $v }
            }
        }
        if ("$($o.mx_Custom_6)".Trim() -ne "") { $byBucket[$key].ExpSize++ }
        if ("$($o.mx_Custom_8)".Trim() -ne "") { $byBucket[$key].ExpDate++ }
        if ("$($o.mx_Custom_7)".Trim() -ne "") { $byBucket[$key].ActSize++ }
        if ("$($o.mx_Custom_9)".Trim() -ne "") { $byBucket[$key].ActDate++ }
        if ("$($o.mx_Custom_4)".Trim() -ne "") { $byBucket[$key].Loss++ }
    }
    Start-Sleep -Milliseconds 250
}

Write-LsqLog "" $logPath
Write-LsqLog "Opportunities read: $read (lead reads failed: $failed)" $logPath
Write-LsqLog "" $logPath
Write-LsqLog ("{0,-14} {1,-26} {2,8} {3,8} {4,7}  {5}" -f "Schema","Display name","Returned","Filled","Fill%","Example") $logPath
Write-LsqLog ("-" * 108) $logPath
foreach ($k in ($seen.Keys | Sort-Object { if ($_ -match '(\d+)') { [int]$matches[1] } else { 0 } })) {
    $name = $FieldNames[$k]; if (-not $name) { $name = "<unmapped>" }
    $pct = if ($seen[$k] -gt 0) { 100.0 * $filled[$k] / $seen[$k] } else { 0 }
    $ex = $examples[$k]; if (-not $ex) { $ex = "" }
    if ($ex.Length -gt 26) { $ex = $ex.Substring(0, 26) }
    Write-LsqLog ("{0,-14} {1,-26} {2,8} {3,8} {4,6:N0}%  {5}" -f $k, $name, $seen[$k], $filled[$k], $pct, $ex) $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "--- the four forecast fields, by deal bucket ---" $logPath
Write-LsqLog ("{0,-34} {1,5} {2,9} {3,9} {4,9} {5,9}" -f "Stage / Status","N","ExpSize","ExpDate","ActSize","ActDate") $logPath
Write-LsqLog ("-" * 92) $logPath
foreach ($k in ($byBucket.Keys | Sort-Object)) {
    $b = $byBucket[$k]
    Write-LsqLog ("{0,-34} {1,5} {2,9} {3,9} {4,9} {5,9}" -f $k, $b.N, $b.ExpSize, $b.ExpDate, $b.ActSize, $b.ActDate) $logPath
}

Write-LsqLog "" $logPath
Write-LsqLog "A field that is RETURNED but never FILLED is a process gap." $logPath
Write-LsqLog "A field that is never RETURNED at all is not on this opportunity type." $logPath
