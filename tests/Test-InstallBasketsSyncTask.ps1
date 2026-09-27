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
    throw 'Installer must keep -WindowStyle Hidden on the PowerShell command line.'
}
if($scriptText -notmatch 'function\s+Write-BasketsSyncHiddenLauncher') {
    throw 'Installer must generate a hidden WScript launcher for scheduled sync.'
}
if($scriptText -notmatch 'shell\.Run\s+".*",\s*0,\s*False') {
    throw 'Hidden launcher must call WScript.Shell.Run with window style 0 (fully hidden).'
}
if($scriptText -notmatch 'New-ScheduledTaskAction\s+-Execute\s+\$WScriptPath') {
    throw 'Scheduled tasks must execute wscript.exe against the generated .vbs launcher (not powershell.exe directly).'
}
if($scriptText -notmatch '//B\s+//Nologo') {
    throw 'Scheduled tasks must launch the .vbs with wscript.exe //B //Nologo.'
}
if($scriptText -match 'New-ScheduledTaskAction\s+-Execute\s+\$PowerShellPath') {
    throw 'Scheduled tasks must not launch powershell.exe directly; that still flashes a console window.'
}

# Functional check of launcher generation (no Task Scheduler registration required).
. $ScriptPath -AsLibrary
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ammar-hidden-launcher-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $launcherPath = Join-Path $tempRoot 'MoneyMachine-Baskets-To-OneDrive-Daily.vbs'
    $powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if(-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
        # Linux CI / non-Windows hosts: skip runtime write probe; source assertions above still apply.
        Write-Host 'Scheduled-task installer identity test passed (source checks; Windows PowerShell path unavailable here).'
        return
    }
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Program Files\AmmarTrading Sync\Scripts\Sync-BasketsToOneDrive.ps1" -ConfigPath "C:\Users\Test\AppData\Local\AmarTrading\Sync\accounts.csv" -RuntimeRoot "C:\Users\Test\AppData\Local\AmarTrading\Sync"'
    Write-BasketsSyncHiddenLauncher -LauncherPath $launcherPath -PowerShellPath $powershellPath -PowerShellArguments $arguments
    $launcherText = Get-Content -LiteralPath $launcherPath -Raw
    if($launcherText -notmatch 'CreateObject\("WScript\.Shell"\)') { throw 'Generated launcher is missing WScript.Shell.' }
    if($launcherText -notmatch ',\s*0,\s*False') { throw 'Generated launcher must use window style 0.' }
    if($launcherText -notmatch '-WindowStyle Hidden') { throw 'Generated launcher must preserve -WindowStyle Hidden.' }
    if($launcherText -notmatch 'powershell\.exe') { throw 'Generated launcher must invoke powershell.exe.' }
    Write-Host 'Scheduled-task installer identity test passed.'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
