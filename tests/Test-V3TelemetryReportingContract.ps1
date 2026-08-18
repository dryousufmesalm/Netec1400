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

Write-Host 'V3 telemetry reporting contract passed.'
