# Shared helpers for LeadSquared API scripts. Dot-source this from other scripts:
#   . "$PSScriptRoot\common.ps1"

function Import-LsqConfig {
    $envPath = Join-Path $PSScriptRoot "..\..\config\.env"
    if (-not (Test-Path $envPath)) {
        throw "Missing config\.env - copy config\.env.example to config\.env and fill in real credentials."
    }
    $config = @{}
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)=(.*)$') {
            $config[$matches[1]] = $matches[2]
        }
    }
    return $config
}

function Get-LsqUrl {
    param([string]$Path)
    $cfg = Import-LsqConfig
    $accessKey = $cfg['LSQ_ACCESS_KEY']
    $secretKey = $cfg['LSQ_SECRET_KEY']
    $host_ = $cfg['LSQ_API_HOST']
    return "$host_/$Path`?accessKey=$accessKey&secretKey=$secretKey"
}

# IMPORTANT - LeadSquared API filter gotcha (discovered 2026-07-27):
#   LeadManagement.svc/Leads.Get silently IGNORES a "Query" wrapper (Query.FilterBy /
#   Query.DateRange) - it returns UNFILTERED results with no error. The correct shape
#   for Leads.Get is a SINGULAR "Parameter" object: { Parameter: { LookupName, LookupValue, SqlOperator } }.
#   CompanyManagement.svc/Company.Get DOES use the "Query" wrapper correctly (Query.FilterBy,
#   Query.CompanyType, Query.SearchText, Query.DateRange all verified working).
#   ALWAYS verify a new filter combination with a negative-control test (a value that should
#   return zero rows) before trusting it - especially before any write/update operation.
function Invoke-LsqLeadSearch {
    param(
        [Parameter(Mandatory)][hashtable]$Filter,   # @{ LookupName=...; LookupValue=...; SqlOperator=... }
        [string]$ColumnsCsv = "*",
        [int]$PageIndex = 1,
        [int]$PageSize = 1000,
        [string]$SortColumn = "ProspectActivityDate_Max",
        [string]$SortDirection = "1"
    )
    $url = Get-LsqUrl "LeadManagement.svc/Leads.Get"
    $body = @{
        Parameter = $Filter
        Columns   = @{ Include_CSV = $ColumnsCsv }
        Sorting   = @{ ColumnName = $SortColumn; Direction = $SortDirection }
        Paging    = @{ PageIndex = $PageIndex; PageSize = $PageSize }
    } | ConvertTo-Json -Depth 6
    return Invoke-LsqWithRetry -What "Leads.Get page $PageIndex" -Action {
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
    }
}

# Invoke-RestMethod has been observed (2026-07-29) returning a Leads.Get page NESTED one level
# deeper - Object[1] wrapping the real Object[1000] - instead of flat, for byte-identical
# requests. It is decided per-PROCESS: a process that gets the nested shape gets it on every
# call, and a process that gets the flat shape never sees it. Reading .Count on the nested
# shape returns 1, so a paginating scan reads "1 record, less than PageSize, stop" and reports
# a complete scan of the whole account after one page. This is the same silent-undercount
# failure family as the "Invalid/ Junk" bug - it looks like an empty account, not an error.
# Always unwrap a page through this before counting or iterating it.
function Expand-LsqRows {
    param([AllowNull()]$Response)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($Response)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Management.Automation.PSCustomObject]) { $out.Add($item); continue }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($sub in $item) { if ($null -ne $sub) { $out.Add($sub) } }
            continue
        }
        $out.Add($item)
    }
    return $out.ToArray()
}

# LeadSquared returns boolean-ish Lead fields (IsPrimaryContact, etc) as the STRING "1" or
# "0" - not $true/$false and not "true"/"false". Verified live 2026-07-28: comparing against
# $true or "true" is False for every record, which silently makes every primary contact look
# non-primary. Filtering has the mirror-image quirk: LookupValue="true" returns HTTP 500,
# LookupValue="1" works. Writing, however, accepts "true".
function Test-LsqTrue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    $s = "$Value".Trim().ToLower()
    return ($s -eq "1" -or $s -eq "true" -or $s -eq "yes")
}

# LeadSquared stores and returns ModifiedOn / CreatedOn / ProspectActivityDate_Max in UTC,
# while this account operates in IST (UTC+5:30). Verified live 2026-07-28: the newest
# ModifiedOn in the account read 09:56 UTC while the local clock read 15:29 IST.
# A watermark computed from local Get-Date is therefore ~5.5 hours in the FUTURE and matches
# ZERO rows - a sync loop built on it would silently never fire. Always use this.
function Get-LsqTimestamp {
    param([datetime]$LocalTime = (Get-Date))
    return $LocalTime.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
}

# Retry wrapper for TRANSIENT network failures. api-in21.leadsquared.com is an Akamai edge host
# (*.edgekey.net) and its IP rotates - observed live 2026-07-30 changing from 23.64.1.219 to
# 96.17.194.243 mid-session. During rotation, DNS resolution briefly fails outright:
# "The remote name could not be resolved" (19 such failures in one backup run, clustered in
# two bursts), plus occasional "connection was expected to be kept alive was closed".
#
# This matters far more for WRITES than reads: the migration writers advance their checkpoint
# even when a write throws, so an unretried blip means that record is skipped permanently and
# a re-run resumes past it - a silent, unrecoverable gap whose only trace is a log line.
#
# Only genuinely transient conditions are retried. A real 4xx (bad body shape, invalid value)
# must still fail fast and loudly rather than be retried into looking like a flake.
# Classify by exception TYPE, not by message text. Matching on wording is unreliable: the first
# version of this looked for "connection was closed" and missed "An existing connection was
# FORCIBLY closed by the remote host", which killed a worklist build on its very first page.
# The transport layer has a small set of failure types; the wording around them does not.
function Test-LsqTransientError {
    param([Parameter(Mandatory)]$ErrorRecord)
    $probe = $ErrorRecord.Exception
    for ($depth = 0; $depth -lt 5 -and $probe; $depth++) {
        if ($probe -is [System.Net.WebException]) {
            $resp = $probe.Response
            if ($resp -and $resp.StatusCode) {
                $code = [int]$resp.StatusCode
                if ($code -eq 429 -or $code -ge 500) { return $true }   # throttled or server-side
                return $false   # a real 4xx: bad body shape, bad value, auth. Retrying hides bugs.
            }
            return $true        # no HTTP response at all = DNS / connect / reset
        }
        if ($probe -is [System.IO.IOException])                { return $true }
        if ($probe -is [System.Net.Sockets.SocketException])   { return $true }
        if ($probe -is [System.TimeoutException])              { return $true }
        $probe = $probe.InnerException
    }
    return $false
}

function Invoke-LsqWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        # Worst case is bounded at ~14s (2+4+8). LeadSquared returns HTTP 500 for some malformed
        # inputs, not just genuine server faults, and 500 is treated as transient here - so an
        # unbounded backoff would turn one bad field value into hours of pointless retrying
        # across thousands of records. Keep the ceiling low; a systematic bad value should be
        # caught by the single-record test that precedes every bulk run, not absorbed here.
        [int]$MaxAttempts = 4,
        [string]$What = "request"
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        } catch {
            if (-not (Test-LsqTransientError $_) -or $attempt -eq $MaxAttempts) { throw }
            Write-Warning "$What transient failure (attempt $attempt/$MaxAttempts): $($_.Exception.Message) - retrying"
            Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt)))
        }
    }
}

# UTF-8 safe POST. Windows PowerShell 5.1's Invoke-RestMethod -Body <string> does NOT
# reliably send UTF-8 bytes; any non-ASCII character in a value being written (accented
# letters, degree signs, (R), etc - common in real CompanyName values) gets mis-encoded and
# the server returns a genuine 400 "Unexpected character encountered while parsing value".
# Not transient - every retry fails identically until the encoding is fixed. Always use this
# helper for writes rather than passing a string body directly.
function Invoke-LsqPost {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$JsonBody
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonBody)
    return Invoke-LsqWithRetry -What "POST" -Action {
        Invoke-RestMethod -Uri $Uri -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -ErrorAction Stop
    }
}

# Log to console and to a file at once. Every migration step writes an audit trail to
# data/ so there is a record independent of LeadSquared's own history.
function Write-LsqLog {
    param(
        # AllowEmptyString: several scripts use Write-LsqLog "" as a blank separator line, which
        # otherwise throws a binding error mid-run and buries the real output in noise.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][string]$LogPath
    )
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
    Write-Output $line
    Add-Content -Path $LogPath -Value $line
}

function Invoke-LsqCompanySearch {
    param(
        [hashtable]$FilterBy = $null,               # @{ LookupName=...; LookupValue=...; SqlOperator=... }
        [string]$CompanyTypeName = "Company",
        [string]$ColumnsCsv = $null,
        [int]$PageIndex = 1,
        [int]$PageSize = 1000
    )
    $url = Get-LsqUrl "CompanyManagement.svc/Company.Get"
    $query = @{ CompanyType = @{ CompanyTypeName = $CompanyTypeName } }
    if ($FilterBy) { $query["FilterBy"] = $FilterBy }
    $bodyObj = @{ Query = $query; Paging = @{ PageIndex = $PageIndex; PageSize = $PageSize } }
    if ($ColumnsCsv) { $bodyObj["Columns"] = @{ Include_CSV = $ColumnsCsv } }
    $body = $bodyObj | ConvertTo-Json -Depth 6
    return Invoke-LsqWithRetry -What "Company.Get page $PageIndex" -Action {
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
    }
}
