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
    return Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json"
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
    return Invoke-RestMethod -Uri $Uri -Method Post -Body $bytes -ContentType "application/json; charset=utf-8"
}

# Log to console and to a file at once. Every migration step writes an audit trail to
# data/ so there is a record independent of LeadSquared's own history.
function Write-LsqLog {
    param(
        [Parameter(Mandatory)][string]$Message,
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
    return Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json"
}
