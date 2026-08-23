[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [datetime]$DailyTime = ([datetime]::Today.AddHours(23).AddMinutes(59)),
    [string]$TaskName = 'MoneyMachine-Baskets-To-OneDrive',
    [switch]$AsLibrary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $PSCommandPath
if([string]::IsNullOrWhiteSpace($ScriptRoot)) { throw 'Could not resolve the installer directory.' }
if([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'accounts.csv' }

function Assert-BasketsSyncTaskPrerequisites {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PowerShellPath)

    if(-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found: $PowerShellPath" }
    $requiredCommands = @(
        'New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal',
        'New-ScheduledTaskSettingsSet','Register-ScheduledTask'
    )
    foreach($command in $requiredCommands) {
        if(-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required ScheduledTasks command is unavailable: $command" }
    }
}

function Get-BasketsSyncTaskDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResolvedConfig,
        [Parameter(Mandatory)][string]$SyncScript,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][datetime]$DailyTime,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$PrincipalUser
    )

    foreach($path in @($ResolvedConfig,$SyncScript,$PowerShellPath,$WorkingDirectory)) {
        if(-not [IO.Path]::IsPathRooted($path)) { throw "Task definition path is not absolute: $path" }
    }
    if([string]::IsNullOrWhiteSpace($PrincipalUser)) { throw 'Task principal user is required.' }

    $baseArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $SyncScript,$ResolvedConfig
    $dailyAction = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $baseArguments -WorkingDirectory $WorkingDirectory
    $catchupAction = New-ScheduledTaskAction -Execute $PowerShellPath -Argument "$baseArguments -StartupCatchup" -WorkingDirectory $WorkingDirectory
    return [pscustomobject]@{
        TaskName = $TaskName
        DailyAction = $dailyAction
        CatchupAction = $catchupAction
        DailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyTime
        LogonTrigger = New-ScheduledTaskTrigger -AtLogOn
        Principal = New-ScheduledTaskPrincipal -UserId $PrincipalUser -LogonType Interactive -RunLevel Limited
        Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    }
}

if(-not $AsLibrary) {
    if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Configuration file not found: $ConfigPath" }
    $syncScript = (Resolve-Path -LiteralPath (Join-Path $ScriptRoot 'Sync-BasketsToOneDrive.ps1')).Path
    $resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $workingDirectory = Split-Path -Parent $syncScript
    $principalUser = (& whoami).Trim()

    Assert-BasketsSyncTaskPrerequisites -PowerShellPath $powershell
    $definition = Get-BasketsSyncTaskDefinition -ResolvedConfig $resolvedConfig -SyncScript $syncScript -PowerShellPath $powershell -WorkingDirectory $workingDirectory -DailyTime $DailyTime -TaskName $TaskName -PrincipalUser $principalUser

    if($PSCmdlet.ShouldProcess($TaskName, 'Register or replace scheduled CSV synchronization tasks')) {
        Register-ScheduledTask -TaskName "$TaskName-Daily" -Action $definition.DailyAction -Trigger $definition.DailyTrigger -Principal $definition.Principal -Settings $definition.Settings -Force -ErrorAction Stop | Out-Null
        Register-ScheduledTask -TaskName "$TaskName-StartupCatchup" -Action $definition.CatchupAction -Trigger $definition.LogonTrigger -Principal $definition.Principal -Settings $definition.Settings -Force -ErrorAction Stop | Out-Null
        Write-Host "Installed scheduled tasks '$TaskName-Daily' and '$TaskName-StartupCatchup' for $($DailyTime.ToString('HH:mm')) local VPS time."
    }
}
