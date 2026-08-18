[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'accounts.csv'),
    [datetime]$DailyTime = ([datetime]::Today.AddHours(23).AddMinutes(59)),
    [string]$TaskName = 'MoneyMachine-Baskets-To-OneDrive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $ConfigPath)) { throw "Configuration file not found: $ConfigPath" }
$syncScript = Join-Path $PSScriptRoot 'Sync-BasketsToOneDrive.ps1'
$powershell = Join-Path $PSHOME 'powershell.exe'
$quotedScript = '"{0}"' -f $syncScript
$quotedConfig = '"{0}"' -f $ConfigPath

$dailyAction = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy Bypass -File $quotedScript -ConfigPath $quotedConfig"
$catchupAction = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -ExecutionPolicy Bypass -File $quotedScript -ConfigPath $quotedConfig -StartupCatchup"
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyTime
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

if($PSCmdlet.ShouldProcess($TaskName, 'Register or replace scheduled CSV synchronization tasks')) {
    # Task Scheduler cannot select a different action per trigger, so keep these as two
    # idempotent tasks: the daily task always copies; the logon task only catches up.
    Register-ScheduledTask -TaskName "$TaskName-Daily" -Action $dailyAction -Trigger $dailyTrigger -Principal $principal -Settings $settings -Force | Out-Null
    Register-ScheduledTask -TaskName "$TaskName-StartupCatchup" -Action $catchupAction -Trigger $logonTrigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Installed scheduled tasks '$TaskName-Daily' and '$TaskName-StartupCatchup' for $($DailyTime.ToString('HH:mm')) local VPS time."
}
