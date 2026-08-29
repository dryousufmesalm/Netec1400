[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Installer,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$ProgressPreference = 'SilentlyContinue'

function Invoke-CheckedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
    if(-not $process.WaitForExit(180000)) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-Null
        throw "Process exceeded the three-minute acceptance limit: $FilePath"
    }
    $process.Refresh()
    if($process.ExitCode -ne 0) {
        throw "Process failed with exit code $($process.ExitCode): $FilePath"
    }
}

function Get-UninstallEntry {
    $registryPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return @(
        Get-ItemProperty -Path $registryPaths -ErrorAction SilentlyContinue |
            Where-Object {
                $null -ne $_.PSObject.Properties['DisplayName'] -and
                [string]$_.DisplayName -ceq 'AmmarTrading Sync'
            }
    )
}

function Get-PeSubsystem {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = New-Object System.IO.BinaryReader($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid PE signature.' }
        $stream.Position = $peOffset + 4 + 20
        $magic = $reader.ReadUInt16()
        $subsystemOffset = if($magic -in @(0x20b,0x10b)) { 0x44 } else { throw 'Unsupported PE optional header.' }
        $stream.Position = $peOffset + 4 + 20 + $subsystemOffset
        return $reader.ReadUInt16()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$resolvedInstaller = [System.IO.Path]::GetFullPath($Installer)
if(-not (Test-Path -LiteralPath $resolvedInstaller -PathType Leaf)) {
    throw "Installer missing: $resolvedInstaller"
}
if([System.IO.Path]::GetFileName($resolvedInstaller) -cne 'AmmarTrading Sync Setup.exe') {
    throw 'The installer filename is not canonical.'
}
$installerVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedInstaller)
if(([string]$installerVersion.ProductName).Trim() -cne 'AmmarTrading Sync') {
    throw "Unexpected installer product name: $($installerVersion.ProductName)"
}

$existingEntries = @(Get-UninstallEntry)
if($existingEntries.Count -gt 0) {
    throw 'AmmarTrading Sync is already installed. Acceptance refuses to modify an existing installation.'
}
if(Get-Process -Name 'AmmarTrading.Sync' -ErrorAction SilentlyContinue) {
    throw 'AmmarTrading Sync is already running. Acceptance refuses to stop an existing process.'
}

$acceptanceId = [Guid]::NewGuid().ToString('N')
$acceptanceRoot = Join-Path 'C:\CodexWorker' "AmmarTrading-Sync-Acceptance-$acceptanceId"
if([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $acceptanceRoot 'Program Files\AmmarTrading Sync'
} else {
    $InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
}
$runtimeRoot = Join-Path $env:LOCALAPPDATA 'AmmarTrading\Sync'
$runtimeExisted = Test-Path -LiteralPath $runtimeRoot -PathType Container
$runtimeSentinel = Join-Path $runtimeRoot "task9-acceptance-$acceptanceId.json"
$oneDriveRoot = Join-Path $acceptanceRoot 'OneDrive'
$oneDriveSentinel = Join-Path $oneDriveRoot 'AmmarTrading\Account_10000001\Baskets.csv'
$taskName = "AmmarTrading-Task9-Acceptance-$acceptanceId"
$launchTaskName = "$taskName-Launch"
$startMenuShortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\AmmarTrading Sync.lnk'
$desktopShortcut = Join-Path $env:PUBLIC 'Desktop\AmmarTrading Sync.lnk'
$setupLog = Join-Path $acceptanceRoot 'install.log'
$upgradeLog = Join-Path $acceptanceRoot 'upgrade.log'
$uninstallLog = Join-Path $acceptanceRoot 'uninstall.log'
$installedByAcceptance = $false
$taskCreated = $false
$launchTaskCreated = $false
$launchedProcessId = $null

try {
    New-Item -ItemType Directory -Path $acceptanceRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $oneDriveSentinel) -Force | Out-Null
    [System.IO.File]::WriteAllText($runtimeSentinel, '{"preserve":true}', (New-Object Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($oneDriveSentinel, 'acceptance-history', (New-Object Text.UTF8Encoding($false)))

    $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/d /c exit 0'
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $taskPrincipal -Force | Out-Null
    $taskCreated = $true

    $installArguments = @(
        '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',
        "/DIR=`"$InstallRoot`"",'/TASKS=desktopicon',"/LOG=`"$setupLog`""
    )
    Invoke-CheckedProcess -FilePath $resolvedInstaller -ArgumentList $installArguments
    $installedByAcceptance = $true

    $installedExe = Join-Path $InstallRoot 'AmmarTrading.Sync.exe'
    if(-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) { throw 'Desktop executable is missing.' }
    if((Get-PeSubsystem -Path $installedExe) -ne 2) { throw 'Desktop executable is not a Windows GUI application.' }
    if(Test-Path -LiteralPath (Join-Path $InstallRoot 'Start-MoneyMachineSyncWizard.cmd')) { throw 'Legacy browser launcher must not be installed.' }
    if(Test-Path -LiteralPath (Join-Path $InstallRoot 'Start-MoneyMachineSyncWizard.ps1')) { throw 'Legacy HTTP host must not be installed.' }
    if(@(Get-ChildItem -LiteralPath $InstallRoot -File -Recurse -Force | Where-Object {
        $_.Extension -in @('.cmd','.bat','.map','.pdb','.cs','.csproj','.sln') -or
        $_.FullName -match '[\\/](?:tests?|fixtures?)[\\/]'
    }).Count -gt 0) { throw 'The installed payload contains development, legacy launcher, or test files.' }
    if(-not (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)) { throw 'Start Menu shortcut is missing.' }
    if(-not (Test-Path -LiteralPath $desktopShortcut -PathType Leaf)) { throw 'Opt-in desktop shortcut is missing.' }
    $entry = @(Get-UninstallEntry)
    if($entry.Count -ne 1 -or $entry[0].DisplayName -cne 'AmmarTrading Sync') { throw 'Uninstall metadata is missing or ambiguous.' }
    if([string]$entry[0].InstallLocation -and ([System.IO.Path]::GetFullPath([string]$entry[0].InstallLocation).TrimEnd('\') -ine $InstallRoot.TrimEnd('\'))) {
        throw 'Uninstall metadata points to the wrong installation directory.'
    }

    $edgeProcessIdsBefore = @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | ForEach-Object Id)
    $launchAction = New-ScheduledTaskAction -Execute $installedExe -WorkingDirectory $InstallRoot
    Register-ScheduledTask -TaskName $launchTaskName -Action $launchAction -Principal $taskPrincipal -Force | Out-Null
    $launchTaskCreated = $true
    $registeredLaunchTask = Get-ScheduledTask -TaskName $launchTaskName -ErrorAction Stop
    if([string]$registeredLaunchTask.Principal.RunLevel -cne 'Limited') { throw 'The application launch check is not configured for a limited token.' }
    $launchStartedUtc = [DateTime]::UtcNow
    Start-ScheduledTask -TaskName $launchTaskName
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $launchedProcess = $null
    while([DateTime]::UtcNow -lt $deadline -and $null -eq $launchedProcess) {
        Start-Sleep -Milliseconds 250
        $launchedProcess = @(Get-Process -Name 'AmmarTrading.Sync' -ErrorAction SilentlyContinue | Where-Object {
            try { $_.Path -ieq $installedExe } catch { $false }
        } | Select-Object -First 1)
        if($launchedProcess -is [array]) { $launchedProcess = @($launchedProcess)[0] }
    }
    if($null -eq $launchedProcess) { throw 'The installed application did not start in the interactive limited-token test.' }
    $launchedProcessId = $launchedProcess.Id
    $interactiveSessionIds = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | ForEach-Object SessionId)
    if($launchedProcess.SessionId -notin $interactiveSessionIds) { throw 'The installed application did not start in an interactive Windows session.' }
    $applicationLog = Join-Path $runtimeRoot 'Logs\application.jsonl'
    $webViewInitialized = $false
    $windowDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while([DateTime]::UtcNow -lt $windowDeadline -and -not $webViewInitialized) {
        Start-Sleep -Milliseconds 250
        if(Test-Path -LiteralPath $applicationLog -PathType Leaf) {
            foreach($line in @(Get-Content -LiteralPath $applicationLog -Tail 40 -ErrorAction SilentlyContinue)) {
                try {
                    $event = $line | ConvertFrom-Json -ErrorAction Stop
                    if([string]$event.eventCode -ceq 'WebViewInitialized' -and
                       [DateTime]$event.timestampUtc -ge $launchStartedUtc) {
                        $webViewInitialized = $true
                        break
                    }
                } catch { }
            }
        }
    }
    if(-not $webViewInitialized) { throw 'The installed application did not initialize its interactive WebView window.' }
    $newEdgeProcesses = @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $edgeProcessIdsBefore })
    if($newEdgeProcesses.Count -gt 0) { throw 'Launching the desktop application opened Microsoft Edge.' }
    [void]$launchedProcess.CloseMainWindow()
    if(-not $launchedProcess.WaitForExit(5000)) { Stop-Process -Id $launchedProcess.Id -Force }
    $launchedProcessId = $null
    Unregister-ScheduledTask -TaskName $launchTaskName -Confirm:$false -ErrorAction Stop
    $launchTaskCreated = $false

    Invoke-CheckedProcess -FilePath $resolvedInstaller -ArgumentList @(
        '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',
        "/DIR=`"$InstallRoot`"",'/TASKS=desktopicon',"/LOG=`"$upgradeLog`""
    )
    if(-not (Test-Path -LiteralPath $runtimeSentinel -PathType Leaf)) { throw 'Upgrade removed local mappings or runtime history.' }
    if(-not (Test-Path -LiteralPath $oneDriveSentinel -PathType Leaf)) { throw 'Upgrade removed OneDrive history.' }
    if($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Upgrade removed an existing scheduled task.' }

    $uninstaller = Join-Path $InstallRoot 'unins000.exe'
    if(-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) { throw 'Uninstaller is missing.' }
    Invoke-CheckedProcess -FilePath $uninstaller -ArgumentList @(
        '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$uninstallLog`""
    )
    $installedByAcceptance = $false

    if(Test-Path -LiteralPath $installedExe -PathType Leaf) { throw 'Uninstall left the desktop executable behind.' }
    if(Test-Path -LiteralPath $startMenuShortcut -PathType Leaf) { throw 'Uninstall left the Start Menu shortcut behind.' }
    if(Test-Path -LiteralPath $desktopShortcut -PathType Leaf) { throw 'Uninstall left the desktop shortcut behind.' }
    if(@(Get-UninstallEntry).Count -ne 0) { throw 'Uninstall metadata remains registered.' }
    if(-not (Test-Path -LiteralPath $runtimeSentinel -PathType Leaf)) { throw 'Uninstall removed local mappings or runtime history.' }
    if(-not (Test-Path -LiteralPath $oneDriveSentinel -PathType Leaf)) { throw 'Uninstall removed OneDrive history.' }
    if($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Uninstall removed an existing scheduled task.' }

    Write-Host 'AmmarTrading Sync install, upgrade, and uninstall acceptance passed.'
} finally {
    if($null -ne $launchedProcessId) {
        $taskProcess = Get-Process -Id $launchedProcessId -ErrorAction SilentlyContinue
        if($null -ne $taskProcess) {
            try {
                if($taskProcess.Path -ieq (Join-Path $InstallRoot 'AmmarTrading.Sync.exe')) { Stop-Process -Id $launchedProcessId -Force }
            } catch { }
        }
    }
    if($launchTaskCreated) {
        Unregister-ScheduledTask -TaskName $launchTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if($installedByAcceptance -and (Test-Path -LiteralPath (Join-Path $InstallRoot 'unins000.exe') -PathType Leaf)) {
        try {
            Invoke-CheckedProcess -FilePath (Join-Path $InstallRoot 'unins000.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
        } catch { Write-Warning 'Acceptance cleanup could not uninstall its task-specific installation.' }
    }
    if($taskCreated) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $runtimeSentinel -Force -ErrorAction SilentlyContinue
    if(-not $runtimeExisted -and (Test-Path -LiteralPath $runtimeRoot -PathType Container) -and
       @(Get-ChildItem -LiteralPath $runtimeRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $runtimeRoot -Force -ErrorAction SilentlyContinue
    }
    if(Test-Path -LiteralPath $acceptanceRoot -PathType Container) {
        Remove-Item -LiteralPath $acceptanceRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
