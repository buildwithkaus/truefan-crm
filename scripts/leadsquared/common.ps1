# Shared helpers for LeadSquared API scripts. Dot-source this from other scripts:
#   . "$PSScriptRoot\common.ps1"

function Import-LsqConfig {
    $envPath = Join-Path $PSScriptRoot "..\..\config\.env"
    if (-not (Test-Path $envPath)) {
        throw "Missing config\.env — copy config\.env.example to config\.env and fill in real credentials."
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

# IMPORTANT — LeadSquared API filter gotcha (discovered 2026-07-27):
#   LeadManagement.svc/Leads.Get silently IGNORES a "Query" wrapper (Query.FilterBy /
#   Query.DateRange) — it returns UNFILTERED results with no error. The correct shape
#   for Leads.Get is a SINGULAR "Parameter" object: { Parameter: { LookupName, LookupValue, SqlOperator } }.
#   CompanyManagement.svc/Company.Get DOES use the "Query" wrapper correctly (Query.FilterBy,
#   Query.CompanyType, Query.SearchText, Query.DateRange all verified working).
#   ALWAYS verify a new filter combination with a negative-control test (a value that should
#   return zero rows) before trusting it — especially before any write/update operation.
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
