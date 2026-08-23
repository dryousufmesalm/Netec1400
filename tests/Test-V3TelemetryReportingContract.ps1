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

Write-Host 'V3 telemetry reporting contract passed.'
