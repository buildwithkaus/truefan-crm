<#
.SYNOPSIS
  Creates the new Lead custom fields defined in 00-schema.ps1. Idempotent - checks live
  metadata first and skips anything that already exists.

.DESCRIPTION
  Only Lead custom fields are creatable via API (LeadManagement.svc/CreateLeadField, verified
  working). Company fields, Opportunity fields, and dropdown values on the SYSTEM field
  ProspectStage are UI-only - see MANUAL_STEPS.md. This script prints those as a reminder and
  does not attempt them.

.PARAMETER Execute
  Without this switch the script only reports what it WOULD create. Nothing is written.

.NOTES
  pwsh ./scripts/leadsquared/migration/01-create-fields.ps1            # dry run
  pwsh ./scripts/leadsquared/migration/01-create-fields.ps1 -Execute   # actually create
#>

param([switch]$Execute)

. "$PSScriptRoot\..\lib\common.ps1"
. "$PSScriptRoot\..\lib\schema.ps1"

$dataDir = Join-Path $PSScriptRoot "..\..\data"
$logPath = Join-Path $dataDir "migration_fields_log.txt"
$mode = if ($Execute) { "EXECUTE" } else { "DRY RUN" }
Write-LsqLog "=== Field creation started [$mode] ===" $logPath

# Fetch live metadata so we can skip fields that already exist.
$metaUrl = Get-LsqUrl "LeadManagement.svc/LeadsMetaData.Get"
$existing = @{}
try {
    $meta = Invoke-RestMethod -Uri $metaUrl -Method Get
    foreach ($f in $meta) { $existing[$f.SchemaName] = $f.DisplayName }
    Write-LsqLog "Live Lead schema has $($existing.Count) fields." $logPath
} catch {
    Write-LsqLog "FATAL: could not read Lead metadata -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
    throw
}

$createUrl = Get-LsqUrl "LeadManagement.svc/CreateLeadField"
$created = 0; $skipped = 0; $failed = 0

foreach ($field in $Script:NewLeadFields) {
    if ($existing.ContainsKey($field.SchemaName)) {
        Write-LsqLog "SKIP  $($field.SchemaName) - already exists as '$($existing[$field.SchemaName])'" $logPath
        $skipped++
        continue
    }

    $payload = @{
        SchemaName  = $field.SchemaName
        DisplayName = $field.DisplayName
        DataType    = $field.DataType
        IsMandatory = $false
    }
    if ($field.Options) {
        # A real JSON ARRAY, not a stringified one. Piping through ConvertTo-Json here produced
        # a STRING, which the outer ConvertTo-Json then escaped again - the API rejected every
        # dropdown field with 400 'Error converting value "[{...}]" to type List<Options>'
        # (2026-07-30). All option lists here have 2+ entries, so the PS 5.1 single-element
        # array collapse does not apply.
        # Each option needs an explicit 1-based Order. Without it CreateLeadField returns 500
        # MXMandatoryAttributeMissingException "You have skipped number in Order: 1,2."
        # (The key must be OptionsJson - passing "Options" instead yields "You have not passed
        # any option value.")
        $ord = 0
        $payload["OptionsJson"] = @($field.Options | ForEach-Object { $ord++; @{ Value = $_; Order = $ord } })
    }
    # RenderTypeTextValue is mandatory - without it CreateLeadField returns 500
    # MXMandatoryAttributeMissingException "You have not passed RenderTypeTextValue."
    # Values taken from the live schema of an existing field of each kind rather than guessed:
    # mx_Call_Disposition (DataType "Select") reports RenderTypeTextValue "Dropdown".
    if ($field.DataType -eq "Date")   { $payload["RenderTypeTextValue"] = "Date" }
    if ($field.DataType -eq "Select") { $payload["RenderTypeTextValue"] = "Dropdown" }
    $json = $payload | ConvertTo-Json -Depth 6

    if (-not $Execute) {
        Write-LsqLog "WOULD CREATE  $($field.SchemaName) ('$($field.DisplayName)', $($field.DataType))$(if ($field.Options) { " with $($field.Options.Count) options" })" $logPath
        continue
    }

    try {
        $r = Invoke-LsqPost -Uri $createUrl -JsonBody $json
        if ($r.Status -eq "Success" -or $r.Message) {
            Write-LsqLog "CREATED  $($field.SchemaName)" $logPath
            $created++
        } else {
            Write-LsqLog "FAILED   $($field.SchemaName) -> $($r | ConvertTo-Json -Compress)" $logPath
            $failed++
        }
    } catch {
        Write-LsqLog "FAILED   $($field.SchemaName) -> $($_.Exception.Message) | HTTP: $($_.ErrorDetails.Message)" $logPath
        $failed++
    }
    Start-Sleep -Milliseconds 400
}

Write-LsqLog "Fields: created=$created skipped=$skipped failed=$failed" $logPath

Write-LsqLog "" $logPath
Write-LsqLog "--- MANUAL (UI-only) STEPS STILL REQUIRED - see MANUAL_STEPS.md ---" $logPath
foreach ($s in $Script:ManualFieldSteps) { Write-LsqLog "  [ ] $s" $logPath }
Write-LsqLog "=== Field creation done [$mode] ===" $logPath
