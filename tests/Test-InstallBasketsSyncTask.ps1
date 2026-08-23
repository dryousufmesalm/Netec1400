[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Install-BasketsSyncTask.ps1')
)

$ErrorActionPreference = 'Stop'
$scriptText = Get-Content -LiteralPath $ScriptPath -Raw

if($scriptText -match '\$env:USERDOMAIN\\\$env:USERNAME') {
    throw 'Installer must not build the task principal from USERDOMAIN and USERNAME.'
}
if($scriptText -notmatch '\[System\.Security\.Principal\.WindowsIdentity\]::GetCurrent\(\)\.Name') {
    throw 'Installer must use the current Windows identity for the task principal.'
}

Write-Host 'Scheduled-task installer identity test passed.'
