<#
.SYNOPSIS
  Re-derives every Company's Stage from the CURRENT state of its contacts and writes the deltas.

.DESCRIPTION
  05-migrate-companies.ps1 worked from the migration worklist - a snapshot of contact stages at
  09:12 on 2026-07-30. Contacts have moved since (reps working, plus the reconciliation in
  12-reconcile-contacts.ps1), so company stages drift out of step with the contacts underneath
  them. This recomputes from live contact state instead of a snapshot.

  Derivation follows STAGE_RESTRUCTURE_PLAN section 3:
    * Company follows its PRIMARY contact when one exists.
    * Otherwise the furthest-along contact wins, by the canonical rank below.
    * Contact Disqualified -> Company Future Prospect, EXCEPT where the disqualification reason
      is "Invalid Contact Data" (legacy "Wrong Number"): the account is qualified and only the
      phone number is wrong, so it stays workable at Nurture with Needs Contact Resourcing.
      That is approved deviation (a) in the plan, and it has to be re-applied here or this
      script would quietly undo it.

  Uses the bulk endpoint for plain alphanumeric company names and per-record updates keyed on
  CompanyId for everything else - names containing "&" and other punctuation fail to match and
  the endpoint CREATES a duplicate instead of updating (proven live 2026-07-30).

.PARAMETER Execute
  Required to write. Without it, reports the deltas.

.NOTES
  pwsh ./scripts/leadsquared/migration/11-audit-post-migration.ps1   # refresh the snapshot
  pwsh ./scripts/leadsquared/migration/13-reconcile-companies.ps1
  pwsh ./scripts/leadsquared/migration/13-reconcile-companies.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$ThrottleMs = 300,
    [int]$BulkSize = 25
)

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir  = Join-Path $PSScriptRoot "..\..\data"
$logPath  = Join-Path $dataDir "migration_reconcile_companies_log.txt"
$snapPath = Join-Path $dataDir "migration_audit_state.json"

$mode = if ($Execute) { "EXECUTE" } else { "REPORT ONLY" }
Write-LsqLog "=== Company reconciliation [$mode] ===" $logPath

if (-not (Test-Path $snapPath)) { throw "Snapshot missing: $snapPath - run 11-audit-post-migration.ps1 first." }
$snap = @(Expand-LsqRows (Get-Content $snapPath -Raw | ConvertFrom-Json))
Write-LsqLog "Snapshot leads: $($snap.Count)" $logPath
if ($snap.Count -lt 80000) { throw "Snapshot has only $($snap.Count) leads - refusing to reconcile from a truncated snapshot." }

# Contact stage -> Company stage, and the rank used to pick the furthest-along contact.
$contactToCompany = @{
    "Fresh"        = "Fresh"
    "Engaged"      = "Nurture"
    "Prospect"     = "Opportunity"
    "Customer"     = "Customer"
    "Disqualified" = "Future Prospect"
}
$companyRank = @{ "Fresh" = 1; "Future Prospect" = 2; "Nurture" = 3; "Opportunity" = 4; "Customer" = 5 }

# Group contacts by company.
$byCompany = @{}
$noCompany = 0
foreach ($l in $snap) {
    $cid = "$($l.CompanyId)"
    if ([string]::IsNullOrWhiteSpace($cid)) { $noCompany++; continue }
    if (-not $byCompany.ContainsKey($cid)) { $byCompany[$cid] = New-Object System.Collections.Generic.List[object] }
    [void]$byCompany[$cid].Add($l)
}
Write-LsqLog "Companies represented: $($byCompany.Count)   (leads with no company: $noCompany)" $logPath

function Get-CompanyTarget {
    param($Members)
    # Primary contact wins outright when there is one.
    $primary = @($Members | Where-Object { $_.IsPrimary })
    $driver = $null
    if ($primary.Count -gt 0) {
        $driver = @($primary | Sort-Object { $companyRank["$($contactToCompany["$($_.Stage)"])"] } -Descending)[0]
    } else {
        $driver = @($Members | Sort-Object { $companyRank["$($contactToCompany["$($_.Stage)"])"] } -Descending)[0]
    }
    $target = $contactToCompany["$($driver.Stage)"]
    if (-not $target) { return $null }

    # Approved deviation (a): a contact disqualified purely for bad phone data leaves the
    # ACCOUNT qualified. Keep it workable at Nurture rather than burying it in Future Prospect.
    if ($target -eq "Future Prospect" -and "$($driver.Reason)" -eq "Invalid Contact Data") {
        return [pscustomobject]@{ Stage = "Nurture"; Reason = $null; NeedsResourcing = $true }
    }
    $reason = $null
    if ($target -eq "Future Prospect") { $reason = "$($driver.Category)" }
    return [pscustomobject]@{ Stage = $target; Reason = $reason; NeedsResourcing = $false }
}

$desired = @{}
foreach ($cid in $byCompany.Keys) {
    $t = Get-CompanyTarget -Members $byCompany[$cid]
    if ($t) { $desired[$cid] = $t }
}
Write-LsqLog "Companies with a derived target: $($desired.Count)" $logPath

# Live company state.
$current = @{}; $nameOf = @{}; $nameCount = @{}
$page = 1
while ($true) {
    $resp = Invoke-LsqCompanySearch -CompanyTypeName "Company" -PageIndex $page -PageSize 1000
    $companies = @(Expand-LsqRows $resp.Companies)
    if ($companies.Count -eq 0) { break }
    foreach ($c in $companies) {
        $p = @{}
        foreach ($x in $c.companyPropertyList) { $p[$x.Attribute] = $x.Value }
        if ($p.CompanyId) {
            $current[$p.CompanyId] = "$($p.Stage)"
            $nm = "$($p.CompanyName)"
            $nameOf[$p.CompanyId] = $nm
            $k = $nm.Trim().ToLower()
            if ($k) { if ($nameCount.ContainsKey($k)) { $nameCount[$k]++ } else { $nameCount[$k] = 1 } }
        }
    }
    if ($page % 20 -eq 0) { Write-LsqLog "  read $($current.Count) companies..." $logPath }
    if ($companies.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 300
}
Write-LsqLog "Live companies read: $($current.Count)" $logPath
if ($current.Count -lt 50000) { throw "Read only $($current.Count) companies, expected ~72,000. Refusing to compute deltas from an incomplete read." }

$pending = New-Object System.Collections.Generic.List[object]
$dist = @{}
$blockedRegression = @{}
foreach ($cid in $desired.Keys) {
    if (-not $current.ContainsKey($cid)) { continue }
    $t = $desired[$cid]
    $cur = "$($current[$cid])"
    if ($cur -eq "$($t.Stage)") { continue }

    # NEVER regress a Customer. Company = Customer means an Opportunity reached Payment
    # Received - the account has paid. Derivation looks only at CONTACT stages, so if the
    # customer's contact was reassigned, replaced or reset the rule would happily drop a paying
    # account back to Fresh and erase that fact. The Opportunity, not the contact, is the source
    # of truth for Customer, so this stays put and is reported for a human to look at.
    if ($cur -eq "Customer" -and "$($t.Stage)" -ne "Customer") {
        $key = "BLOCKED $cur -> $($t.Stage)"
        if ($blockedRegression.ContainsKey($key)) { $blockedRegression[$key]++ } else { $blockedRegression[$key] = 1 }
        Write-LsqLog "   BLOCKED regression: company $cid is Customer, derivation wanted [$($t.Stage)] - left as Customer for review" $logPath
        continue
    }

    [void]$pending.Add([pscustomobject]@{ CompanyId = $cid; NewStage = $t.Stage; Reason = $t.Reason; NeedsResourcing = $t.NeedsResourcing })
    $key = "$cur -> $($t.Stage)"
    if ($dist.ContainsKey($key)) { $dist[$key]++ } else { $dist[$key] = 1 }
}
if ($blockedRegression.Count -gt 0) {
    Write-LsqLog "--- regressions blocked (left unchanged, need a human look) ---" $logPath
    foreach ($k in $blockedRegression.Keys) { Write-LsqLog ("   {0,-42} {1}" -f $k, $blockedRegression[$k]) $logPath }
}
Write-LsqLog "Companies needing a stage change: $($pending.Count)" $logPath
foreach ($k in ($dist.Keys | Sort-Object { -$dist[$_] })) { Write-LsqLog ("   {0,-42} {1}" -f $k, $dist[$k]) $logPath }

if ($pending.Count -eq 0) { Write-LsqLog "Nothing to reconcile." $logPath; return }
if (-not $Execute) { Write-LsqLog "REPORT ONLY - nothing written. Re-run with -Execute." $logPath; return }

function ConvertTo-JsonScalar {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return ($Value | ConvertTo-Json)
}
function Get-AttrBlock {
    param($Row, [string]$CompanyName)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($CompanyName) { [void]$parts.Add('{"Attribute":"CompanyName","Value":' + (ConvertTo-JsonScalar $CompanyName) + '}') }
    [void]$parts.Add('{"Attribute":"Stage","Value":' + (ConvertTo-JsonScalar "$($Row.NewStage)") + '}')
    if ($Row.Reason)          { [void]$parts.Add('{"Attribute":"Future_Prospect_Reason","Value":' + (ConvertTo-JsonScalar "$($Row.Reason)") + '}') }
    if ($Row.NeedsResourcing) { [void]$parts.Add('{"Attribute":"Needs_Contact_Resourcing","Value":"Yes"}') }
    return '[' + ($parts -join ',') + ']'
}

# Only plain alphanumeric/space names are safe for the name-matched bulk endpoint.
$bulkRows = New-Object System.Collections.Generic.List[object]
$singleRows = New-Object System.Collections.Generic.List[object]
foreach ($row in $pending) {
    $nm = "$($nameOf[$row.CompanyId])"
    $k = $nm.Trim().ToLower()
    if ($nm -and ($nm -match '^[A-Za-z0-9 ]+$') -and $nameCount.ContainsKey($k) -and $nameCount[$k] -eq 1) {
        [void]$bulkRows.Add([pscustomobject]@{ Row = $row; Name = $nm })
    } else {
        [void]$singleRows.Add($row)
    }
}
Write-LsqLog "Bulk-eligible: $($bulkRows.Count)   per-record: $($singleRows.Count)" $logPath

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
$ok = 0; $fail = 0; $createdAccidentally = 0

$bulkUrl = "$base/CompanyManagement.svc/Company/Bulk/CreateOrUpdate?accessKey=$ak&secretKey=$sk"
$batches = [Math]::Ceiling($bulkRows.Count / $BulkSize)
for ($b = 0; $b -lt $batches; $b++) {
    $slice = @($bulkRows[($b * $BulkSize)..([Math]::Min(($b + 1) * $BulkSize - 1, $bulkRows.Count - 1))])
    $blocks = foreach ($e in $slice) { Get-AttrBlock -Row $e.Row -CompanyName $e.Name }
    $body = '{"CompanyType":{"CompanyTypeName":"Company"},' +
            '"Options":{"SearchBy":"CompanyName","CollisionResolutionStrategy":"OverwriteAllFields"},' +
            '"Companies":[' + ($blocks -join ',') + ']}'
    try {
        $r = @(Expand-LsqRows (Invoke-LsqPost -Uri $bulkUrl -JsonBody $body))
        foreach ($res in $r) {
            $idx = [int]$res.RowNumber - 1
            if ($idx -lt 0 -or $idx -ge $slice.Count) { continue }
            $expect = "$($slice[$idx].Row.CompanyId)"
            if ($res.CompanyCreated -eq $true) {
                $createdAccidentally++; $fail++
                Write-LsqLog "CREATED A COMPANY (should not happen) name=[$($slice[$idx].Name)] newId=$($res.CompanyId) expected=$expect" $logPath
            } elseif ("$($res.CompanyId)" -ne $expect) {
                $fail++
                Write-LsqLog "WRONG COMPANY updated name=[$($slice[$idx].Name)] got=$($res.CompanyId) expected=$expect" $logPath
            } else { $ok++ }
        }
    } catch {
        $fail += $slice.Count
        Write-LsqLog "Bulk batch $b EXCEPTION -> $($_.Exception.Message)" $logPath
    }
    if ($createdAccidentally -gt 0) { throw "ABORTING: bulk endpoint created $createdAccidentally company record(s). Investigate before re-running." }
    if ($b % 20 -eq 0) { Write-LsqLog "Bulk progress: batch $b/$batches ok=$ok fail=$fail" $logPath }
    Start-Sleep -Milliseconds $ThrottleMs
}

foreach ($row in $singleRows) {
    $body = '{"CompanyProperties":' + (Get-AttrBlock -Row $row -CompanyName $null) + '}'
    try {
        $r = Invoke-LsqPost -Uri "$base/CompanyManagement.svc/Company.Update?accessKey=$ak&secretKey=$sk&companyId=$($row.CompanyId)" -JsonBody $body
        if ($r.Status -eq "Success") { $ok++ } else { $fail++; Write-LsqLog "Company $($row.CompanyId) FAILURE -> $($r | ConvertTo-Json -Compress)" $logPath }
    } catch {
        $fail++
        Write-LsqLog "Company $($row.CompanyId) EXCEPTION -> $($_.Exception.Message)" $logPath
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Company reconciliation DONE. ok=$ok fail=$fail of $($pending.Count)." $logPath
Write-LsqLog "=== Company reconciliation complete [$mode] ===" $logPath
