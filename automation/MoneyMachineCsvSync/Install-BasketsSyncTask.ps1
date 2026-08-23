[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'accounts.csv'),
    [datetime]$DailyTime = ([datetime]::Today.AddHours(23).AddMinutes(59)),
    [string]$TaskName = 'MoneyMachine-Baskets-To-OneDrive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration file not found: $ConfigPath" }
$syncScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Sync-BasketsToOneDrive.ps1')).Path
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if(-not (Test-Path -LiteralPath $powershell)) { throw "Windows PowerShell 5.1 was not found: $powershell" }
$workingDirectory = Split-Path -Parent $syncScript
$quotedScript = '"{0}"' -f $syncScript
$quotedConfig = '"{0}"' -f $resolvedConfig

$dailyAction = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quotedScript -ConfigPath $quotedConfig" -WorkingDirectory $workingDirectory
$catchupAction = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $quotedScript -ConfigPath $quotedConfig -StartupCatchup" -WorkingDirectory $workingDirectory
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyTime
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$principalUser = (& whoami).Trim()
if([string]::IsNullOrWhiteSpace($principalUser)) { throw 'Could not resolve the current Windows account with whoami.' }
$principal = New-ScheduledTaskPrincipal -UserId $principalUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

if($PSCmdlet.ShouldProcess($TaskName, 'Register or replace scheduled CSV synchronization tasks')) {
    # Task Scheduler cannot select a different action per trigger, so keep these as two
    # idempotent tasks: the daily task always copies; the logon task only catches up.
    Register-ScheduledTask -TaskName "$TaskName-Daily" -Action $dailyAction -Trigger $dailyTrigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Register-ScheduledTask -TaskName "$TaskName-StartupCatchup" -Action $catchupAction -Trigger $logonTrigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "Installed scheduled tasks '$TaskName-Daily' and '$TaskName-StartupCatchup' for $($DailyTime.ToString('HH:mm')) local VPS time."
}
