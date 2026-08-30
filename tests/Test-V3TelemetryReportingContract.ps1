[CmdletBinding()]
param(
    [string]$SourcePath = (Join-Path $PSScriptRoot '..\AmmarTradingGoldEA - ref reset every bar - V3.mq4')
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath $SourcePath -Raw
$required = @(
    'RunID',
    'RunStartTime',
    'RunStartBalance',
    'CsvSchemaVersion',
    'TelemetryBeginRun',
    'TelemetryEnsureRunContext',
    'TelemetryRunContextIsValid',
    'TelemetryClearRunContext',
    'TelemetryRunResetDeferredKey',
    'TelemetryRunResetDeferredIsPersisted',
    'TelemetryMarkRunResetDeferred',
    'TELEMETRY_IDENTITY_FILE_NAME',
    'TelemetryWriteIdentityFile',
    'NewBasketDelaySeconds',
    'UseBasketTrailingTP',
    'EnableRecoveryStepUp'
)

$missing = @($required | Where-Object { $source -notmatch [regex]::Escape($_) })
if($missing.Count -gt 0) {
    throw "Schema-v3 reporting contract is incomplete. Missing: $($missing -join ', ')"
}

if($source -notmatch 'line\s*=\s*line\s*\+\s*"3"') {
    throw 'Telemetry writer does not emit CsvSchemaVersion=3.'
}

if($source -notmatch 'TelemetryEnsureRunContext\(\);\s*\r?\n\s*CheckBasketStateConsistency\(\);') {
    throw 'Run reset detection must execute before telemetry can observe an external basket closure.'
}
if($source -notmatch 'CheckBasketStateConsistency\(\);\s*(?://[^\r\n]*\r?\n\s*)*TelemetryEnsureRunContext\(true\);\s*\r?\n\s*UpdateReferenceExtremes\(\);') {
    throw 'A deferred run reset must be reconciled after external closure and before same-tick entry processing.'
}

if($source -notmatch '#define\s+TELEMETRY_IDENTITY_FILE_NAME\s+"AGOLD___Identity\.csv"') {
    throw 'The EA must publish the canonical immediate account identity sidecar.'
}
if($source -notmatch 'AccountNumber,BrokerName,CsvSchemaVersion,EAVersion') {
    throw 'The immediate account identity sidecar header is incomplete.'
}
foreach($identityValue in @('AccountNumber()','AccountCompany()','"3"','"3.00"')) {
    if($source -notmatch [regex]::Escape($identityValue)) {
        throw "The immediate account identity sidecar is missing $identityValue."
    }
}
$onInitBody = [regex]::Match($source, '(?s)int\s+OnInit\s*\(\s*\).*?return\s*\(\s*INIT_SUCCEEDED\s*\)')
if(-not $onInitBody.Success -or
   $onInitBody.Value.IndexOf('TelemetryWriteIdentityFile()', [StringComparison]::Ordinal) -lt 0 -or
   $onInitBody.Value.IndexOf('TelemetryWriteIdentityFile()', [StringComparison]::Ordinal) -gt
   $onInitBody.Value.IndexOf('TelemetryEnsureRunContext(true)', [StringComparison]::Ordinal)) {
    throw 'OnInit must publish account identity before initializing the reporting run.'
}
$missingCsvBranch = [regex]::Match($source, '(?s)if\s*\(\s*!csvExists\s*\).*?\n\s*}')
if(-not $missingCsvBranch.Success -or $missingCsvBranch.Value -notmatch 'TelemetryEnsureSchemaV3Header\s*\(') {
    throw 'A missing basket CSV must receive its schema-v3 header even when an existing basket delays the new run.'
}

if($source -notmatch 'string\s+TelemetryCsvEscape\s*\(\s*string\s+value\s*\)') {
    throw 'Telemetry writer is missing TelemetryCsvEscape.'
}
foreach($escapedValue in @('brokerName','Symbol()','symbolNormalized','dirStr','closeReasonOut','outcomeClass','g_Telemetry_RunID','"AmmarTradingGoldEA"','"3.00"')) {
    $pattern = 'TelemetryCsvEscape\s*\(\s*{0}\s*\)' -f [regex]::Escape($escapedValue)
    if($source -notmatch $pattern) { throw "Telemetry text field is not CSV-escaped: $escapedValue" }
}
if($source -notmatch 'StringReplace\s*\(\s*value\s*,\s*"\\""\s*,\s*"\\"\\""\s*\)') {
    throw 'TelemetryCsvEscape must double embedded quotes.'
}
foreach($trigger in @(',', '\r', '\n')) {
    if($source -notmatch ('StringFind\s*\(\s*value\s*,\s*"{0}"\s*\)' -f [regex]::Escape($trigger))) {
        throw "TelemetryCsvEscape does not detect '$trigger'."
    }
}
if($source -match 'if\s*\(\s*g_Telemetry_MaxOrdersInBasketSnap\s*>\s*0\s*\)') {
    throw 'MaxOrdersInBasket must serialize disabled value 0 instead of a legacy blank.'
}
if($source -notmatch 'IntegerToString\s*\(\s*g_Telemetry_MaxOrdersInBasketSnap\s*\)') {
    throw 'MaxOrdersInBasket is not serialized as an integer.'
}

$appendWriter = [regex]::Match(
    $source,
    '(?s)int\s+fh\s*=\s*FileOpen\s*\(\s*fileName\s*,\s*FILE_READ\s*\|\s*FILE_WRITE.*?FileWrite\s*\(\s*fh\s*,\s*line\s*\)'
)
if(-not $appendWriter.Success) {
    throw 'Telemetry append writer could not be identified.'
}
if($appendWriter.Value -match 'TelemetryFileIsSchemaV3\s*\(') {
    throw 'Telemetry append writer reopens its already-open CSV while checking the schema.'
}
if($appendWriter.Value -notmatch 'FileSeek\s*\(\s*fh\s*,\s*0\s*,\s*SEEK_SET\s*\)' -or
   $appendWriter.Value -notmatch 'FileReadString\s*\(\s*fh\s*\)' -or
   $appendWriter.Value -notmatch 'TelemetryHeaderIsSchemaV3\s*\(' -or
   $appendWriter.Value -notmatch 'FileSeek\s*\(\s*fh\s*,\s*0\s*,\s*SEEK_END\s*\)') {
    throw 'Telemetry append writer must validate and append using its existing CSV handle.'
}

if($source -match '\bFILE_UTF8\b') {
    throw 'Telemetry must pass CP_UTF8 as FileOpen codepage, not treat FILE_UTF8 as an open flag.'
}
$utf8TelemetryOpens = [regex]::Matches(
    $source,
    'FileOpen\s*\([^;\r\n]+FILE_ANSI\s*,\s*0\s*,\s*CP_UTF8\s*\)'
)
if($utf8TelemetryOpens.Count -lt 4) {
    throw 'Every telemetry text-file open must use FILE_ANSI with delimiter 0 and CP_UTF8 codepage.'
}

Write-Host 'V3 telemetry reporting contract passed.'
