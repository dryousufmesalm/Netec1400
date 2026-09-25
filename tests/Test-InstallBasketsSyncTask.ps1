[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Install-BasketsSyncTask.ps1')
)

$ErrorActionPreference = 'Stop'
$scriptText = Get-Content -LiteralPath $ScriptPath -Raw

if($scriptText -match '\$env:USERDOMAIN\\\$env:USERNAME') {
    throw 'Installer must not build the task principal from USERDOMAIN and USERNAME.'
}
if($scriptText -notmatch '\$principalUser\s*=\s*\(& whoami\)\.Trim\(\)' -or $scriptText -notmatch 'New-ScheduledTaskPrincipal -UserId \$principalUser') {
    throw 'Installer must resolve the current Windows identity and use it for the task principal.'
}

if($scriptText -notmatch '-WindowStyle\s+Hidden') {
    throw 'Installer must register scheduled PowerShell actions with -WindowStyle Hidden so sync does not flash a console window.'
}

Write-Host 'Scheduled-task installer identity test passed.'
