<#
.SYNOPSIS
  Load the whole lead book at row level, with its ICP attributes, into dim_contact_book.
  READ-ONLY against LeadSquared.

.DESCRIPTION
  dim_contact holds only the ~17,800 contacts the calling pipeline has enriched on demand.
  Every ICP question needs the other 73,000 too: a conversion rate by category computed on
  the enriched slice describes whichever contacts happened to be called recently, not the
  category.

  Deliberately a SEPARATE script from 03-snapshot-book.ps1 rather than another extension of
  it. That job is the daily production snapshot and it already carries the aggregate book,
  dim_rep and the disqualification tally; adding a 91,000-row row-level upsert to it would
  put the day's book numbers behind the slowest part of the run. ~92 extra LSQ calls against
  a 10,000/day cap is a price worth paying for that separation.

  FIELD CHOICE IS MEASURED, not assumed (enumerate-icp-readiness.ps1, 2026-08-11):
    mx_Ads           99.7% filled on the ICP list, exactly Yes/No   -> the Meta-ads flag
    mx_Category      100%  filled on the ICP list, 55 clean values  -> the industry dimension
    mx_City          97.9% filled on the ICP list
    mx_Designation   97.0% filled on the ICP list
    mx_Industry_Type carried as DATA ONLY - 11,515 stored values against a 15-option
                     dropdown, so it can never be a rep-reproducible filter.

.EXAMPLE
  powershell.exe -File scripts\pipeline\12-load-contact-book.ps1 -WhatIf
  powershell.exe -File scripts\pipeline\12-load-contact-book.ps1

.NOTES
  ASCII only. Migration 023 must be applied first. Do not run alongside another LSQ script -
  the rate limit is account-wide.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$MinExpectedLeads = 80000,
    [int]$BatchSize = 500
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\lib\common.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "contact_book_log.txt"

$cfg = Import-LsqConfig
foreach ($k in @("SUPABASE_URL", "SUPABASE_SERVICE_KEY")) {
    if (-not $cfg[$k]) { throw "Missing $k in config\.env" }
}
$sbUrl = $cfg['SUPABASE_URL'].TrimEnd('/')
$sbKey = $cfg['SUPABASE_SERVICE_KEY']
$headers = @{ apikey = $sbKey; Authorization = "Bearer $sbKey"
              Prefer = "resolution=merge-duplicates,return=minimal" }

Write-LsqLog "" $logPath
Write-LsqLog "=== Contact book load ===" $logPath

# Negative control before trusting the filter. A zero result is exactly as suspect as a wrong
# non-zero one - two unverified zeros once silently skipped 20,076 leads.
$neg = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
    LookupName = "CreatedOn"; LookupValue = "2099-01-01 00:00:00"; SqlOperator = ">"
} -ColumnsCsv "ProspectID" -PageSize 10 -SortColumn "CreatedOn"))
Write-LsqLog "Negative control: $($neg.Count) rows -- must be 0" $logPath
if ($neg.Count -ne 0) { throw "NEGATIVE CONTROL FAILED - the filter is being ignored." }

$cols = "ProspectID,RelatedCompanyId,Company,OwnerId,OwnerIdName,ProspectStage,Source," +
        "mx_Ads,mx_Category,mx_Industry_Type,mx_City,mx_Designation," +
        "mx_Disqualification_Reason,CreatedOn,ProspectActivityDate_Max"

$buffer = New-Object System.Collections.Generic.List[object]
$total = 0; $written = 0; $page = 1
$columnsChecked = $false
$now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

function Save-Buffer {
    if ($buffer.Count -eq 0) { return }
    $arr = $buffer.ToArray()
    for ($i = 0; $i -lt $arr.Count; $i += $BatchSize) {
        $slice = $arr[$i..([Math]::Min($i + $BatchSize - 1, $arr.Count - 1))]
        $json = ConvertTo-Json -InputObject $slice -Depth 4
        if ($slice.Count -eq 1) { $json = "[$json]" }
        [void](Invoke-LsqWithRetry -What "upsert dim_contact_book" -Action {
            Invoke-RestMethod -Uri "$sbUrl/rest/v1/dim_contact_book" -Method Post `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -Headers $headers `
                -ContentType "application/json; charset=utf-8" -ErrorAction Stop
        })
        $Script:written += $slice.Count
    }
    $buffer.Clear()
}

function ConvertTo-Utc {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $formats = @("yyyy-MM-dd HH:mm:ss.fff", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd")
    $parsed = [datetime]::MinValue
    foreach ($f in $formats) {
        if ([datetime]::TryParseExact($Value.Trim(), $f, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        }
    }
    return $null
}

Write-LsqLog "Scanning the full book (about 92 pages)..." $logPath
while ($true) {
    $rows = @(Expand-LsqRows (Invoke-LsqLeadSearch -Filter @{
        LookupName = "CreatedOn"; LookupValue = "2000-01-01 00:00:00"; SqlOperator = ">"
    } -ColumnsCsv $cols -PageIndex $page -PageSize 1000 -SortColumn "CreatedOn"))
    if ($rows.Count -eq 0) { break }

    # Leads.Get silently returns FEWER columns rather than erroring on a name it does not
    # know, so an unrecognised field would tally as 100% empty and read as a real finding.
    if (-not $columnsChecked) {
        $present = @($rows[0].PSObject.Properties.Name)
        $want = @("mx_Ads", "mx_Category", "mx_City", "mx_Designation", "mx_Industry_Type")
        $absent = @($want | Where-Object { $present -notcontains $_ })
        if ($absent.Count -gt 0) { throw "Leads.Get did not return: $($absent -join ', '). Fix the names before trusting anything." }
        Write-LsqLog "  all ICP columns present in the payload" $logPath
        $columnsChecked = $true
    }

    foreach ($r in $rows) {
        $total++
        # Fixed key set on every row - PostgREST rejects a bulk insert whose objects differ
        # at all (PGRST102).
        [void]$buffer.Add([ordered]@{
            prospect_id      = "$($r.ProspectID)"
            company_id       = "$($r.RelatedCompanyId)"
            company_name     = "$($r.Company)"
            owner_id         = "$($r.OwnerId)"
            owner_name       = "$($r.OwnerIdName)"
            contact_stage    = "$($r.ProspectStage)"
            source           = "$($r.Source)"
            ads              = "$($r.mx_Ads)".Trim()
            category         = "$($r.mx_Category)".Trim()
            industry_type    = "$($r.mx_Industry_Type)".Trim()
            city             = "$($r.mx_City)".Trim()
            designation      = "$($r.mx_Designation)".Trim()
            disq_reason      = "$($r.mx_Disqualification_Reason)".Trim()
            created_on       = ConvertTo-Utc "$($r.CreatedOn)"
            last_activity_at = ConvertTo-Utc "$($r.ProspectActivityDate_Max)"
            refreshed_at     = $now
        })
    }

    if ($buffer.Count -ge 2000 -and -not $WhatIfPreference) { Save-Buffer }
    if ($page % 20 -eq 0) { Write-LsqLog "  page $page -> $total leads ($written written)" $logPath }
    if ($rows.Count -lt 1000) { break }
    $page++
    if ($page -gt 300) { Write-LsqLog "  WARNING: stopped at 300 pages" $logPath; break }
}

# Absolute guard from an INDEPENDENT source. A truncated scan reconciles perfectly against
# itself - that is exactly how a one-page scan once reported as a whole-account sweep.
Write-LsqLog "Scanned $total leads across $page pages" $logPath
if ($total -lt $MinExpectedLeads) {
    throw "Scanned only $total leads, expected at least $MinExpectedLeads. Refusing to write a partial book."
}

if ($WhatIfPreference) {
    Write-LsqLog "DRY RUN - nothing written. Would upsert $total rows." $logPath
    return
}

Save-Buffer
Write-LsqLog "Wrote $written rows to dim_contact_book." $logPath

# Refresh the ICP snapshot built on top of this table. CONCURRENTLY so the tabs keep serving
# while it rebuilds - without it the refresh takes the ICP tab offline for its duration,
# which is trading one outage for another. Left stale it would silently describe an older
# book, so v_qc_icp compares its row count against dim_contact_book.
[void](Invoke-LsqWithRetry -What "refresh mv_icp_contact" -Action {
    Invoke-RestMethod -Uri "$sbUrl/rest/v1/rpc/refresh_icp_snapshot" -Method Post `
        -Body "{}" -Headers @{ apikey = $sbKey; Authorization = "Bearer $sbKey" } `
        -ContentType "application/json" -ErrorAction Stop
})
Write-LsqLog "Refreshed mv_icp_contact." $logPath
Write-LsqLog "" $logPath
Write-LsqLog "VERIFY INDEPENDENTLY - a write response is not evidence:" $logPath
Write-LsqLog "  GET /rest/v1/v_qc_icp?select=*" $logPath
Write-LsqLog "  GET /rest/v1/v_icp_funnel?select=*&dimension=eq.ads" $logPath
