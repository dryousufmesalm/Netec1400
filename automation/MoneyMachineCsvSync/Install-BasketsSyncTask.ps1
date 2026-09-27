[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$RuntimeRoot,
    [datetime]$DailyTime = ((Get-Date).AddMinutes(1)),
    [ValidateRange(1,1440)][int]$SyncIntervalMinutes = 5,
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
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$WScriptPath
    )

    if(-not (Test-Path -LiteralPath $PowerShellPath -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found: $PowerShellPath" }
    if(-not (Test-Path -LiteralPath $WScriptPath -PathType Leaf)) { throw "Windows Script Host was not found: $WScriptPath" }
    $requiredCommands = @(
        'New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal',
        'New-ScheduledTaskSettingsSet','Register-ScheduledTask'
    )
    foreach($command in $requiredCommands) {
        if(-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required ScheduledTasks command is unavailable: $command" }
    }
}

function Write-BasketsSyncHiddenLauncher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$PowerShellArguments
    )

    if(-not [IO.Path]::IsPathRooted($LauncherPath)) { throw "Launcher path is not absolute: $LauncherPath" }
    if(-not [IO.Path]::IsPathRooted($PowerShellPath)) { throw "PowerShell path is not absolute: $PowerShellPath" }
    if([string]::IsNullOrWhiteSpace($PowerShellArguments)) { throw 'PowerShell arguments are required.' }

    # Task Scheduler still flashes a console when it launches powershell.exe directly,
    # even with -WindowStyle Hidden. WScript.Shell.Run with window style 0 starts the
    # process fully hidden in the background.
    $commandLine = '"{0}" {1}' -f $PowerShellPath, $PowerShellArguments
    $escapedCommand = $commandLine.Replace('"', '""')
    $launcherDirectory = Split-Path -Parent $LauncherPath
    if(-not (Test-Path -LiteralPath $launcherDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $launcherDirectory -Force | Out-Null
    }

    $vbs = @(
        'Option Explicit',
        'Dim shell',
        'Set shell = CreateObject("WScript.Shell")',
        ('shell.Run "{0}", 0, False' -f $escapedCommand)
    ) -join "`r`n"
    Set-Content -LiteralPath $LauncherPath -Value $vbs -Encoding ASCII -Force
}

function Get-BasketsSyncTaskDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResolvedConfig,
        [Parameter(Mandatory)][string]$SyncScript,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$WScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$DailyLauncherPath,
        [Parameter(Mandatory)][string]$CatchupLauncherPath,
        [datetime]$DailyTime = ((Get-Date).AddMinutes(1)),
        [ValidateRange(1,1440)][int]$SyncIntervalMinutes = 5,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$PrincipalUser
    )

    foreach($path in @($ResolvedConfig,$SyncScript,$PowerShellPath,$WScriptPath,$WorkingDirectory,$DailyLauncherPath,$CatchupLauncherPath)) {
        if(-not [IO.Path]::IsPathRooted($path)) { throw "Task definition path is not absolute: $path" }
    }
    if([string]::IsNullOrWhiteSpace($PrincipalUser)) { throw 'Task principal user is required.' }

    $effectiveRuntimeRoot = if([string]::IsNullOrWhiteSpace($RuntimeRoot)) { Split-Path -Parent $ResolvedConfig } else { [IO.Path]::GetFullPath($RuntimeRoot) }
    $baseArguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -RuntimeRoot "{2}"' -f $SyncScript,$ResolvedConfig,$effectiveRuntimeRoot

    Write-BasketsSyncHiddenLauncher -LauncherPath $DailyLauncherPath -PowerShellPath $PowerShellPath -PowerShellArguments $baseArguments
    Write-BasketsSyncHiddenLauncher -LauncherPath $CatchupLauncherPath -PowerShellPath $PowerShellPath -PowerShellArguments "$baseArguments -StartupCatchup"

    $dailyAction = New-ScheduledTaskAction -Execute $WScriptPath -Argument ('//B //Nologo "{0}"' -f $DailyLauncherPath) -WorkingDirectory $WorkingDirectory
    $catchupAction = New-ScheduledTaskAction -Execute $WScriptPath -Argument ('//B //Nologo "{0}"' -f $CatchupLauncherPath) -WorkingDirectory $WorkingDirectory
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyTime
    $repetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClientOnly -Property @{
        Interval = [Xml.XmlConvert]::ToString([TimeSpan]::FromMinutes($SyncIntervalMinutes))
        Duration = 'P1D'
        StopAtDurationEnd = $false
    }
    $dailyTrigger.Repetition = $repetition
    return [pscustomobject]@{
        TaskName = $TaskName
        DailyAction = $dailyAction
        CatchupAction = $catchupAction
        DailyTrigger = $dailyTrigger
        LogonTrigger = New-ScheduledTaskTrigger -AtLogOn
        Principal = New-ScheduledTaskPrincipal -UserId $PrincipalUser -LogonType Interactive -RunLevel Limited
        Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
        DailyLauncherPath = $DailyLauncherPath
        CatchupLauncherPath = $CatchupLauncherPath
    }
}

if(-not $AsLibrary) {
    if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Configuration file not found: $ConfigPath" }
    $syncScript = (Resolve-Path -LiteralPath (Join-Path $ScriptRoot 'Sync-BasketsToOneDrive.ps1')).Path
    $resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $workingDirectory = Split-Path -Parent $syncScript
    $principalUser = (& whoami).Trim()
    if([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Split-Path -Parent $resolvedConfig }
    $RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $launcherDirectory = Join-Path $RuntimeRoot 'launchers'
    $dailyLauncherPath = Join-Path $launcherDirectory ("{0}-Daily.vbs" -f $TaskName)
    $catchupLauncherPath = Join-Path $launcherDirectory ("{0}-StartupCatchup.vbs" -f $TaskName)

    Assert-BasketsSyncTaskPrerequisites -PowerShellPath $powershell -WScriptPath $wscript
    $definition = Get-BasketsSyncTaskDefinition `
        -ResolvedConfig $resolvedConfig `
        -SyncScript $syncScript `
        -PowerShellPath $powershell `
        -WScriptPath $wscript `
        -WorkingDirectory $workingDirectory `
        -DailyLauncherPath $dailyLauncherPath `
        -CatchupLauncherPath $catchupLauncherPath `
        -DailyTime $DailyTime `
        -SyncIntervalMinutes $SyncIntervalMinutes `
        -TaskName $TaskName `
        -PrincipalUser $principalUser

    if($PSCmdlet.ShouldProcess($TaskName, 'Register or replace scheduled CSV synchronization tasks')) {
        Register-ScheduledTask -TaskName "$TaskName-Daily" -Action $definition.DailyAction -Trigger $definition.DailyTrigger -Principal $definition.Principal -Settings $definition.Settings -Force -ErrorAction Stop | Out-Null
        Register-ScheduledTask -TaskName "$TaskName-StartupCatchup" -Action $definition.CatchupAction -Trigger $definition.LogonTrigger -Principal $definition.Principal -Settings $definition.Settings -Force -ErrorAction Stop | Out-Null
        Write-Host "Installed scheduled tasks '$TaskName-Daily' (every $SyncIntervalMinutes minutes) and '$TaskName-StartupCatchup' via hidden WScript launchers."
    }
}
