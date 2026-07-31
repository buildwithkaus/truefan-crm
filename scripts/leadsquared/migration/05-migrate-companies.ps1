<#
.SYNOPSIS
  Writes the new Company stage (plus Future Prospect reason and the contact-resourcing flag)
  from migration_worklist_companies.json.

.DESCRIPTION
  Uses CompanyManagement.svc/Company.Update, which matches on the internal CompanyId and is
  precise. The BULK company endpoint is deliberately NOT used: it matches on CompanyName and
  is create-OR-update, so a name mismatch silently creates a duplicate company. Single-record
  updates are slower but safe.

  This is the slowest step in the migration - one API call per company. Two mitigations:
    * Rows already at their target stage are skipped entirely.
    * If the UI rename of the most common value has been done first (see MANUAL_STEPS.md),
      the majority of companies are already correct and are skipped here for free.

  Idempotent and resumable via a checkpoint file.

.PARAMETER Execute
  Required to write.

.PARAMETER ThrottleMs
  300ms respects the account-wide 20 calls/5s cap with headroom. Do not run anything else
  against the API concurrently.

.NOTES
  pwsh ./scripts/leadsquared/migration/05-migrate-companies.ps1            # dry run
  pwsh ./scripts/leadsquared/migration/05-migrate-companies.ps1 -Execute
#>

param(
    [switch]$Execute,
    [int]$ThrottleMs = 300
)

. "$PSScriptRoot\..\common.ps1"
. "$PSScriptRoot\00-schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\..\data"
$logPath = Join-Path $dataDir "migration_companies_log.txt"
$checkpointPath = Join-Path $dataDir "migration_companies_checkpoint.txt"
$worklistPath = Join-Path $dataDir "migration_worklist_companies.json"

$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "=== Company stage migration [$mode] ===" $logPath

if (-not (Test-Path $worklistPath)) { throw "Worklist missing. Run 02-build-worklist.ps1 first." }
# Expand-LsqRows: without it this collapsed all 71,483 rows into ONE on 2026-07-30, and the run
# tried a single write whose companyId was every id concatenated together. It failed harmlessly,
# but it reported "Worklist rows: 1 ... DONE" and would otherwise read as a completed migration.
$work = @(Expand-LsqRows (Get-Content $worklistPath -Raw | ConvertFrom-Json))
# Absolute floor, NOT a fraction of $work.Count - a guard derived from the same corrupted value
# it is meant to check is no guard at all (that is exactly why the collapse above got through).
$MinExpectedWorklist = 50000
if ($work.Count -lt $MinExpectedWorklist) {
    throw "Company worklist loaded only $($work.Count) rows, expected ~71,000. Refusing to run - the worklist is truncated or collapsed. Delete it and re-run 02-build-worklist.ps1."
}
$badRows = @($work | Where-Object { [string]::IsNullOrWhiteSpace($_.CompanyId) -or @($_.CompanyId).Count -ne 1 })
if ($badRows.Count -gt 0) {
    throw "Company worklist has $($badRows.Count) row(s) whose CompanyId is missing or not a single value. Refusing to write from a malformed worklist."
}
Write-LsqLog "Worklist rows: $($work.Count)" $logPath

# Read current stages so rows already correct can be skipped. This is what makes the UI
# rename optimisation pay off - after a rename most rows need no write at all.
Write-LsqLog "Reading current company stages to compute the delta..." $logPath
$current   = @{}   # CompanyId -> current Stage
$nameOf    = @{}   # CompanyId -> CompanyName (the bulk endpoint matches on NAME, not id)
$nameCount = @{}   # normalised name -> how many companies share it
$page = 1
while ($true) {
    $resp = Invoke-LsqCompanySearch -CompanyTypeName "Company" -PageIndex $page -PageSize 1000
    $companies = @(Expand-LsqRows $resp.Companies)
    if ($companies.Count -eq 0) { break }
    foreach ($c in $companies) {
        $props = @{}
        foreach ($p in $c.companyPropertyList) { $props[$p.Attribute] = $p.Value }
        if ($props.CompanyId) {
            $current[$props.CompanyId] = $props.Stage
            $nm = "$($props.CompanyName)"
            $nameOf[$props.CompanyId] = $nm
            $k = $nm.Trim().ToLower()
            if ($k) { if ($nameCount.ContainsKey($k)) { $nameCount[$k]++ } else { $nameCount[$k] = 1 } }
        }
    }
    if ($companies.Count -lt 1000) { break }
    $page++
    Start-Sleep -Milliseconds 300
}
Write-LsqLog "Current stages read for $($current.Count) companies." $logPath

# A SHORT read here is silently expensive, not obviously broken: every company missing from
# $current is treated as "not at target" and queued for a write. Truncating this read would
# turn ~26,000 writes into ~71,000 - five extra hours - while the run looks entirely normal.
# The worklist itself is the reference count; require the live read to cover essentially all
# of it before trusting the delta.
$MinExpectedCompanies = [Math]::Max(50000, [int]($work.Count * 0.95))
if ($current.Count -lt $MinExpectedCompanies) {
    throw "Read current stages for only $($current.Count) companies against a worklist of $($work.Count). Refusing to compute the write delta from an incomplete read - it would silently rewrite companies that are already correct. Re-run."
}

$pending = @($work | Where-Object {
    -not $current.ContainsKey($_.CompanyId) -or $current[$_.CompanyId] -ne $_.NewStage
})
Write-LsqLog "Already at target stage (skipped): $($work.Count - $pending.Count)" $logPath
Write-LsqLog "Companies needing a write: $($pending.Count)" $logPath

$estMin = [Math]::Round(($pending.Count * $ThrottleMs) / 60000, 1)
Write-LsqLog "Estimated run time: ~$estMin min at ${ThrottleMs}ms per record" $logPath

if (-not $Execute) {
    $dist = $pending | Group-Object NewStage | Sort-Object Count -Descending
    Write-LsqLog "--- Would write these target stages ---" $logPath
    foreach ($g in $dist) { Write-LsqLog ("  {0,-18} {1}" -f $g.Name, $g.Count) $logPath }
    Write-LsqLog "" $logPath
    Write-LsqLog "TIP: the largest bucket above is the one to apply as a UI RENAME of the" $logPath
    Write-LsqLog "existing 'Prospect' value before running this - it removes those writes entirely." $logPath
    Write-LsqLog "DRY RUN complete - nothing written. Re-run with -Execute." $logPath
    return
}

$startIdx = 0
if (Test-Path $checkpointPath) {
    $startIdx = [int](Get-Content $checkpointPath -Raw).Trim()
    Write-LsqLog "Resuming from index $startIdx (checkpoint found)." $logPath
}

$cfg = Import-LsqConfig
$base = $cfg['LSQ_API_HOST']; $ak = $cfg['LSQ_ACCESS_KEY']; $sk = $cfg['LSQ_SECRET_KEY']
$okCount = 0; $failCount = 0

# ---------------------------------------------------------------------------------------
# Split the work. CompanyManagement.svc/Company/Bulk/CreateOrUpdate does 25 records per call
# (~2,850 calls instead of ~71,000 - minutes instead of hours), but it matches on COMPANY NAME,
# not CompanyId. Two consequences:
#   * a name shared by more than one company is ambiguous - LeadSquared picks one and we cannot
#     say which - so those must go one-at-a-time through Company.Update, keyed on CompanyId;
#   * it is CreateOrUpdate, so a name that fails to match CREATES a new company. Every response
#     row is therefore checked for CompanyCreated=true and for the CompanyId we expected.
# Verified live 2026-07-30: no-op write returned CompanyCreated=false/CompanyUpdated=true, the
# company total was unchanged, and OverwriteAllFields left all 27 other populated fields intact
# (it only overwrites attributes actually sent).
# ---------------------------------------------------------------------------------------
# A name containing anything beyond letters, digits and spaces is NOT safe to match on.
# Proven live 2026-07-30: "VARDAN GEM & JEWELS PRIVATE LIMITED" failed to match and the endpoint
# CREATED a duplicate company instead of updating the intended one. A no-op retest on a second
# "&" name created another. LeadSquared's name matching evidently normalises or chokes on these
# characters, and because the endpoint is CreateOrUpdate, a match failure silently manufactures
# a new account rather than erroring. 1,521 names contain "&" and 6,066 contain other
# punctuation, so this is routed conservatively: only plain alphanumeric/space names go through
# the bulk path; everything else is updated one at a time by CompanyId, which cannot mismatch.
$bulkRows   = New-Object System.Collections.Generic.List[object]
$singleRows = New-Object System.Collections.Generic.List[object]
foreach ($row in $pending) {
    $id = "$($row.CompanyId)"
    $nm = if ($nameOf.ContainsKey($id)) { "$($nameOf[$id])" } else { "" }
    $k  = $nm.Trim().ToLower()
    $nameIsSafe = ($nm -ne "") -and ($nm -match '^[A-Za-z0-9 ]+$')
    $nameIsUnique = $k -and $nameCount.ContainsKey($k) -and $nameCount[$k] -eq 1
    if ($nameIsSafe -and $nameIsUnique) {
        [void]$bulkRows.Add([pscustomobject]@{ Row = $row; Name = $nm })
    } else {
        [void]$singleRows.Add($row)
    }
}
Write-LsqLog "Bulk-eligible (unique name): $($bulkRows.Count)   per-record fallback (ambiguous/missing name): $($singleRows.Count)" $logPath

function ConvertTo-JsonScalar {
    # ConvertTo-Json on a bare string returns a correctly escaped, quoted JSON literal.
    # Safer than hand-rolling escapes for 218 non-ASCII company names.
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    return ($Value | ConvertTo-Json)
}

function Get-AttrBlock {
    param([Parameter(Mandatory)]$Row, [string]$CompanyName)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($CompanyName) { [void]$parts.Add('{"Attribute":"CompanyName","Value":' + (ConvertTo-JsonScalar $CompanyName) + '}') }
    [void]$parts.Add('{"Attribute":"Stage","Value":' + (ConvertTo-JsonScalar "$($Row.NewStage)") + '}')
    if ($Row.FutureProspectReason) {
        [void]$parts.Add('{"Attribute":"Future_Prospect_Reason","Value":' + (ConvertTo-JsonScalar "$($Row.FutureProspectReason)") + '}')
    }
    if ($Row.NeedsContactResourcing) {
        [void]$parts.Add('{"Attribute":"Needs_Contact_Resourcing","Value":"Yes"}')
    }
    return '[' + ($parts -join ',') + ']'
}

# ---- Phase 1: bulk, 25 per call ----
$BulkSize = 25
$bulkBatches = [Math]::Ceiling($bulkRows.Count / $BulkSize)
$bulkUrl = "$base/CompanyManagement.svc/Company/Bulk/CreateOrUpdate?accessKey=$ak&secretKey=$sk"
$createdAccidentally = 0
$startBatch = $startIdx   # checkpoint counts BATCHES during the bulk phase

Write-LsqLog "Bulk phase: $bulkBatches batches of $BulkSize" $logPath
for ($b = $startBatch; $b -lt $bulkBatches; $b++) {
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
            $expectId = "$($slice[$idx].Row.CompanyId)"
            if ($res.CompanyCreated -eq $true) {
                $createdAccidentally++
                $failCount++
                Write-LsqLog "CREATED A COMPANY (should not happen) name=[$($slice[$idx].Name)] newId=$($res.CompanyId) expected=$expectId" $logPath
            } elseif ("$($res.CompanyId)" -ne $expectId) {
                $failCount++
                Write-LsqLog "WRONG COMPANY updated for name=[$($slice[$idx].Name)] got=$($res.CompanyId) expected=$expectId" $logPath
            } else {
                $okCount++
            }
        }
        if ($r.Count -ne $slice.Count) {
            Write-LsqLog "Batch $b returned $($r.Count) rows for $($slice.Count) sent - unaccounted records" $logPath
        }
    } catch {
        $failCount += $slice.Count
        Write-LsqLog "Bulk batch $b EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }

    Set-Content -Path $checkpointPath -Value ($b + 1)
    if ($b % 20 -eq 0) { Write-LsqLog "Bulk progress: batch $b/$bulkBatches  ok=$okCount fail=$failCount" $logPath }

    # A created company means the name-matching assumption is broken. Stop immediately rather
    # than manufacturing thousands of junk accounts.
    if ($createdAccidentally -gt 0) {
        throw "ABORTING: the bulk endpoint CREATED $createdAccidentally company record(s) instead of updating. Name matching is not behaving as verified. Investigate before re-running; delete the created records listed in the log."
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

# ---- Phase 2: per-record fallback, keyed on CompanyId ----
Write-LsqLog "Per-record phase: $($singleRows.Count) companies with an ambiguous or missing name" $logPath
foreach ($row in $singleRows) {
    # Company.Update requires the array wrapped in "CompanyProperties" - a bare array returns
    # MXInvalidDataTypeException "You're missing Company details" on every call. See CLAUDE.md.
    $attrs = Get-AttrBlock -Row $row -CompanyName $null
    $body = '{"CompanyProperties":' + $attrs + '}'
    $url = "$base/CompanyManagement.svc/Company.Update?accessKey=$ak&secretKey=$sk&companyId=$($row.CompanyId)"
    try {
        $r = Invoke-LsqPost -Uri $url -JsonBody $body
        if ($r.Status -eq "Success") { $okCount++ }
        else { $failCount++; Write-LsqLog "Company $($row.CompanyId) FAILURE -> $($r | ConvertTo-Json -Compress)" $logPath }
    } catch {
        $failCount++
        Write-LsqLog "Company $($row.CompanyId) EXCEPTION -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    }
    Start-Sleep -Milliseconds $ThrottleMs
}

Write-LsqLog "Company migration DONE. ok=$okCount fail=$failCount of $($pending.Count)." $logPath
if ($failCount -eq 0) {
    Remove-Item $checkpointPath -ErrorAction SilentlyContinue
    Write-LsqLog "Checkpoint cleared (clean run)." $logPath
} else {
    Write-LsqLog "Checkpoint retained - re-run to retry failures." $logPath
}
Write-LsqLog "=== Company stage migration complete [$mode] ===" $logPath
