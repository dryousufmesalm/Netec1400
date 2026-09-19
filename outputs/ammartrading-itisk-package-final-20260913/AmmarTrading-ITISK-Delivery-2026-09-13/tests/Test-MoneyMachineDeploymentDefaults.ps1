[CmdletBinding()]
param(
    [string]$AutomationRoot = (Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedRoot = (Resolve-Path -LiteralPath $AutomationRoot).Path
$configPath = Join-Path $resolvedRoot 'accounts.csv'
if(-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Deployment accounts file was not found: $configPath"
}

$rows = @(Import-Csv -LiteralPath $configPath)
if($rows.Count -ne 0) {
    throw "A clean deployment package must not contain configured accounts; found $($rows.Count)."
}

Write-Host 'MoneyMachine clean deployment defaults passed.'
