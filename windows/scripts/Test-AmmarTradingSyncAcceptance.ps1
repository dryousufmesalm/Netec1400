[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Installer,
    [string]$FaultInstaller
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$ProgressPreference = 'SilentlyContinue'
$uninstallSubKey = '{8F488698-AB96-45DB-A2BB-D9E868823F43}_is1'

function Invoke-BoundedProcess {
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
    return $process.ExitCode
}

function Invoke-CheckedProcess {
    param([string]$FilePath,[string[]]$ArgumentList)
    $exitCode = Invoke-BoundedProcess -FilePath $FilePath -ArgumentList $ArgumentList
    if($exitCode -ne 0) { throw "Process failed with exit code ${exitCode}: $FilePath" }
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    if((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Acceptance paths cannot contain reparse points.'
    }
}

function Assert-SafeAcceptancePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AcceptanceRoot,
        [switch]$AllowRoot
    )
    $canonicalRoot = [IO.Path]::GetFullPath($AcceptanceRoot).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootPrefix = $canonicalRoot + '\'
    if($canonicalPath -ieq $canonicalRoot) {
        if(-not $AllowRoot) { throw 'The acceptance path cannot be the isolated root.' }
    } elseif(-not $canonicalPath.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The acceptance path escaped its isolated root.'
    }
    if($canonicalPath -ieq [IO.Path]::GetPathRoot($canonicalPath)) { throw 'A drive root is never a valid acceptance path.' }

    $cursor = $canonicalPath
    while(-not [string]::IsNullOrWhiteSpace($cursor)) {
        if(Test-Path -LiteralPath $cursor) { Assert-NoReparsePoint -Path $cursor }
        if($cursor -ieq $canonicalRoot) { break }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if([string]::IsNullOrWhiteSpace($parent) -or $parent -ieq $cursor) {
            throw 'The acceptance path escaped its isolated root.'
        }
        $cursor = $parent.TrimEnd('\')
    }
    if($cursor -ine $canonicalRoot) { throw 'The acceptance path escaped its isolated root.' }
    return $canonicalPath
}

function Assert-SafeProtectedInstallPath {
    param([Parameter(Mandatory)][string]$Path)
    $programFilesRoot = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if(-not $canonicalPath.StartsWith($programFilesRoot + '\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The test installation must be strictly beneath the machine Program Files directory.'
    }
    $cursor = $canonicalPath
    while($cursor.Length -ge $programFilesRoot.Length) {
        if(Test-Path -LiteralPath $cursor) { Assert-NoReparsePoint -Path $cursor }
        if($cursor -ieq $programFilesRoot) { return $canonicalPath }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if([string]::IsNullOrWhiteSpace($parent) -or $parent -ieq $cursor) { break }
        $cursor = $parent.TrimEnd('\')
    }
    throw 'The protected test installation path escaped Program Files.'
}

function Get-UninstallEntry {
    $keys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstallSubKey",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$uninstallSubKey"
    )
    return @(Get-ItemProperty -LiteralPath $keys -ErrorAction SilentlyContinue)
}

function Assert-ExactUninstallEntry {
    param([Parameter(Mandatory)][string]$ExpectedInstallRoot)
    $entries = @(Get-UninstallEntry)
    if($entries.Count -ne 1) { throw 'The exact AmmarTrading Sync uninstall key is missing or ambiguous.' }
    $entry = $entries[0]
    if([string]$entry.DisplayName -cne 'AmmarTrading Sync') { throw 'The uninstall display name is not canonical.' }
    $registeredRoot = [IO.Path]::GetFullPath([string]$entry.InstallLocation).TrimEnd('\')
    if($registeredRoot -ine $ExpectedInstallRoot.TrimEnd('\')) { throw 'Uninstall metadata points to the wrong installation directory.' }
    return $entry
}

function Get-PeSubsystem {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if($reader.ReadUInt32() -ne 0x00004550) { throw 'Invalid PE signature.' }
        $stream.Position = $peOffset + 24
        $magic = $reader.ReadUInt16()
        if($magic -notin @(0x20b,0x10b)) { throw 'Unsupported PE optional header.' }
        $stream.Position = $peOffset + 24 + 0x44
        return $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-InstalledPayloadHashes {
    param(
        [Parameter(Mandatory)][string]$InstallRoot
    )
    $manifestPath = Assert-SafeProtectedInstallPath -Path (Join-Path $InstallRoot 'AmmarTrading.Sync.payload-manifest.txt')
    if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Installed product payload manifest is missing.' }
    $relativePaths = @(Get-Content -LiteralPath $manifestPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if($relativePaths.Count -eq 0) { throw 'Installed product payload manifest is empty.' }
    $hashes = @{}
    foreach($relativePath in $relativePaths) {
        if([IO.Path]::IsPathRooted($relativePath) -or
           $relativePath -match '(^|\\)\.\.?($|\\)' -or
           $relativePath.Contains(':') -or
           $relativePath.Contains('/') -or
           $hashes.ContainsKey($relativePath)) {
            throw 'Installed product payload manifest contains an unsafe or duplicate path.'
        }
        $payloadPath = Assert-SafeProtectedInstallPath -Path (Join-Path $InstallRoot $relativePath)
        if(-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) { throw "Installed product payload file is missing: $relativePath" }
        $hashes[$relativePath] = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $hashes
}

function Get-ProductPathState {
    param([string]$InstallRoot,[string[]]$RelativePaths)
    $state = @{}
    foreach($relativePath in $RelativePaths) {
        $path = Assert-SafeProtectedInstallPath -Path (Join-Path $InstallRoot $relativePath)
        if(Test-Path -LiteralPath $path -PathType Leaf) {
            $state[$relativePath] = 'FILE:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        } elseif(Test-Path -LiteralPath $path -PathType Container) {
            $state[$relativePath] = 'DIRECTORY'
        } else {
            $state[$relativePath] = 'ABSENT'
        }
    }
    return $state
}

function Assert-ProductPathStateEqual {
    param([hashtable]$Expected,[hashtable]$Actual,[string]$Message)
    if($Expected.Count -ne $Actual.Count) { throw $Message }
    foreach($key in $Expected.Keys) {
        if(-not $Actual.ContainsKey($key) -or $Actual[$key] -cne $Expected[$key]) { throw "$Message Path: $key" }
    }
}

function Repair-FailedSetupAttempt {
    param(
        [Parameter(Mandatory)][string]$AcceptanceRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$StartMenuShortcut,
        [Parameter(Mandatory)][string]$DesktopShortcut
    )
    $safeInstallRoot = Assert-SafeProtectedInstallPath -Path $InstallRoot
    $entries = @(Get-UninstallEntry)
    if($entries.Count -gt 1) { throw 'Cleanup refused ambiguous exact AppId registrations.' }
    if($entries.Count -eq 1) {
        $registeredRoot = [IO.Path]::GetFullPath([string]$entries[0].InstallLocation).TrimEnd('\')
        if($registeredRoot -ine $safeInstallRoot) { throw 'Cleanup refused an AppId registered outside the isolated root.' }
        $uninstaller = Join-Path $safeInstallRoot 'unins000.exe'
        if(Test-Path -LiteralPath $uninstaller -PathType Leaf) {
            Assert-SafeProtectedInstallPath -Path $uninstaller | Out-Null
            Invoke-CheckedProcess -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
        }
    }
    if(@(Get-UninstallEntry).Count -ne 0) { throw 'Failed setup cleanup left the exact AppId registered.' }
    Remove-Item -LiteralPath $StartMenuShortcut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $DesktopShortcut -Force -ErrorAction SilentlyContinue
    if((Test-Path -LiteralPath $StartMenuShortcut) -or (Test-Path -LiteralPath $DesktopShortcut)) {
        throw 'Failed setup cleanup left an AmmarTrading Sync shortcut.'
    }
}

$resolvedInstaller = [IO.Path]::GetFullPath($Installer)
if(-not (Test-Path -LiteralPath $resolvedInstaller -PathType Leaf)) { throw "Installer missing: $resolvedInstaller" }
if([IO.Path]::GetFileName($resolvedInstaller) -cne 'AmmarTrading Sync Setup.exe') { throw 'The installer filename is not canonical.' }
$installerVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedInstaller)
if(([string]$installerVersion.ProductName).Trim() -cne 'AmmarTrading Sync') {
    throw 'The installer product name is not canonical.'
}
if([string]::IsNullOrWhiteSpace($FaultInstaller)) {
    $FaultInstaller = Join-Path (Split-Path -Parent $resolvedInstaller) '.acceptance\AmmarTrading Sync Upgrade Fault Test.exe'
}
$resolvedFaultInstaller = [IO.Path]::GetFullPath($FaultInstaller)
if(-not (Test-Path -LiteralPath $resolvedFaultInstaller -PathType Leaf)) { throw "Fault-injection installer missing: $resolvedFaultInstaller" }
if([IO.Path]::GetFileName($resolvedFaultInstaller) -cne 'AmmarTrading Sync Upgrade Fault Test.exe') { throw 'The fault installer filename is not test-scoped.' }
$faultProbeHashPath = Join-Path (Split-Path -Parent $resolvedFaultInstaller) 'AmmarTrading Sync Upgrade Fault Probe.sha256'
if(-not (Test-Path -LiteralPath $faultProbeHashPath -PathType Leaf)) { throw "Fault probe hash missing: $faultProbeHashPath" }
$expectedFaultProbeHash = (Get-Content -LiteralPath $faultProbeHashPath -Raw).Trim().ToLowerInvariant()
if($expectedFaultProbeHash -cnotmatch '^[0-9a-f]{64}$') { throw 'Fault probe hash is malformed.' }

if(@(Get-UninstallEntry).Count -gt 0) { throw 'AmmarTrading Sync is already installed.' }
if(Get-Process -Name 'AmmarTrading.Sync' -ErrorAction SilentlyContinue) { throw 'AmmarTrading Sync is already running.' }

$workerRoot = [IO.Path]::GetFullPath('C:\CodexWorker').TrimEnd('\')
if(-not (Test-Path -LiteralPath $workerRoot -PathType Container)) { throw 'The configured Windows worker root is missing.' }
Assert-NoReparsePoint -Path $workerRoot
$acceptanceId = [Guid]::NewGuid().ToString('N')
$acceptanceRoot = Join-Path $workerRoot "AmmarTrading-Sync-Acceptance-$acceptanceId"
if(Test-Path -LiteralPath $acceptanceRoot) { throw 'The unique acceptance root already exists.' }
New-Item -ItemType Directory -Path $acceptanceRoot | Out-Null
Assert-SafeAcceptancePath -Path $acceptanceRoot -AcceptanceRoot $acceptanceRoot -AllowRoot | Out-Null
$protectedAcceptanceRoot = Join-Path $env:ProgramFiles "AmmarTrading Task9 Acceptance\$acceptanceId"
if(Test-Path -LiteralPath $protectedAcceptanceRoot) { throw 'The unique protected acceptance root already exists.' }
$installRoot = Assert-SafeProtectedInstallPath -Path (Join-Path $protectedAcceptanceRoot 'AmmarTrading Sync')
$oneDriveRoot = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'OneDrive') -AcceptanceRoot $acceptanceRoot
$oneDriveSentinel = Assert-SafeAcceptancePath -Path (Join-Path $oneDriveRoot 'AmmarTrading\Account_10000001\Baskets.csv') -AcceptanceRoot $acceptanceRoot
$setupLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'install.log') -AcceptanceRoot $acceptanceRoot
$upgradeLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'upgrade.log') -AcceptanceRoot $acceptanceRoot
$faultLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'failed-upgrade.log') -AcceptanceRoot $acceptanceRoot
$restoreFailureLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'restore-failure.log') -AcceptanceRoot $acceptanceRoot
$recoveryLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'recovery-only.log') -AcceptanceRoot $acceptanceRoot
$crashLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'crash.log') -AcceptanceRoot $acceptanceRoot
$uninstallLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'uninstall.log') -AcceptanceRoot $acceptanceRoot

$runtimeRoot = Join-Path $env:LOCALAPPDATA 'AmmarTrading\Sync'
$runtimeExisted = Test-Path -LiteralPath $runtimeRoot -PathType Container
$runtimeSentinel = Join-Path $runtimeRoot "task9-acceptance-$acceptanceId.json"
$taskName = "AmmarTrading-Task9-Acceptance-$acceptanceId"
$launchTaskName = "$taskName-Launch"
$startMenuShortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\AmmarTrading Sync.lnk'
$desktopShortcut = Join-Path $env:PUBLIC 'Desktop\AmmarTrading Sync.lnk'
if((Test-Path -LiteralPath $startMenuShortcut) -or (Test-Path -LiteralPath $desktopShortcut)) { throw 'Acceptance refuses pre-existing product shortcuts.' }

$setupAttempted = $false
$taskCreated = $false
$launchTaskCreated = $false
$launchedProcessId = $null
try {
    Assert-SafeAcceptancePath -Path $oneDriveSentinel -AcceptanceRoot $acceptanceRoot | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $oneDriveSentinel) -Force | Out-Null
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    [IO.File]::WriteAllText($runtimeSentinel,'{"preserve":true}',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($oneDriveSentinel,'acceptance-history',(New-Object Text.UTF8Encoding($false)))

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType Interactive -RunLevel Limited
    $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/d /c exit 0'
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $taskPrincipal -Force | Out-Null
    $taskCreated = $true

    Assert-SafeProtectedInstallPath -Path $installRoot | Out-Null
    $setupAttempted = $true
    Invoke-CheckedProcess -FilePath $resolvedInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASKS=desktopicon',"/LOG=`"$setupLog`"")
    $installedExe = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'AmmarTrading.Sync.exe')
    if(-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) { throw 'Desktop executable is missing.' }
    if((Get-PeSubsystem -Path $installedExe) -ne 2) { throw 'Desktop executable is not a Windows GUI application.' }
    $allowedInstalledExecutables = @('AmmarTrading.Sync.exe','unins000.exe')
    $actualInstalledExecutables = @(Get-ChildItem -LiteralPath $installRoot -File -Recurse -Filter '*.exe' | ForEach-Object Name | Sort-Object -Unique)
    if(Compare-Object -ReferenceObject $allowedInstalledExecutables -DifferenceObject $actualInstalledExecutables) { throw 'Installed executable payload is not allowlisted.' }
    if(@(Get-ChildItem -LiteralPath $installRoot -File -Recurse -Force | Where-Object { $_.Extension -in @('.cmd','.bat','.map','.pdb','.cs','.csproj','.sln') -or $_.FullName -match '[\\/](?:tests?|fixtures?)[\\/]' }).Count -gt 0) { throw 'Installed payload contains forbidden development content.' }
    if(-not (Test-Path $startMenuShortcut) -or -not (Test-Path $desktopShortcut)) { throw 'Expected shortcuts are missing.' }
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null

    $edgeBefore = @(Get-Process msedge -ErrorAction SilentlyContinue | ForEach-Object Id)
    $launchAction = New-ScheduledTaskAction -Execute $installedExe -WorkingDirectory $installRoot
    Register-ScheduledTask -TaskName $launchTaskName -Action $launchAction -Principal $taskPrincipal -Force | Out-Null
    $launchTaskCreated = $true
    $registeredLaunchTask = Get-ScheduledTask -TaskName $launchTaskName -ErrorAction Stop
    if(([string]$registeredLaunchTask.Principal.RunLevel) -cne 'Limited') { throw 'Launch task is not limited-token.' }
    $launchStartedUtc = [DateTime]::UtcNow
    Start-ScheduledTask $launchTaskName
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        $launchedProcess = @(Get-Process 'AmmarTrading.Sync' -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -ieq $installedExe } catch { $false } } | Select-Object -First 1)
        if($launchedProcess -is [array]) { $launchedProcess = @($launchedProcess)[0] }
    } while($null -eq $launchedProcess -and [DateTime]::UtcNow -lt $deadline)
    if($null -eq $launchedProcess) { throw 'The installed application did not start.' }
    $launchedProcessId = $launchedProcess.Id
    if($launchedProcess.SessionId -notin @(Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object SessionId)) { throw 'The app did not start interactively.' }
    $applicationLog = Join-Path $runtimeRoot 'Logs\application.jsonl'
    $initialized = $false
    do {
        Start-Sleep -Milliseconds 250
        foreach($line in @(Get-Content $applicationLog -Tail 40 -ErrorAction SilentlyContinue)) {
            try { $event=$line|ConvertFrom-Json; if($event.eventCode -ceq 'WebViewInitialized' -and [DateTime]$event.timestampUtc -ge $launchStartedUtc){$initialized=$true;break} } catch { }
        }
    } while(-not $initialized -and [DateTime]::UtcNow -lt $deadline)
    if(-not $initialized) { throw 'WebView did not initialize.' }
    if(@(Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.Id -notin $edgeBefore }).Count) { throw 'The app opened Edge.' }
    [void]$launchedProcess.CloseMainWindow(); if(-not $launchedProcess.WaitForExit(5000)){Stop-Process $launchedProcess.Id -Force}
    $launchedProcessId=$null; Unregister-ScheduledTask $launchTaskName -Confirm:$false; $launchTaskCreated=$false

    $priorExeHash = (Get-FileHash $installedExe -Algorithm SHA256).Hash
    if($expectedFaultProbeHash -ceq $priorExeHash.ToLowerInvariant()) { throw 'Fault probe hash unexpectedly matches the production executable.' }
    $priorPayloadHashes = Get-InstalledPayloadHashes -InstallRoot $installRoot
    $priorManifestHash = $priorPayloadHashes['AmmarTrading.Sync.payload-manifest.txt']
    $distinguishablePayloadTargets = @(
        'AmmarTrading.Sync.exe',
        'AmmarTrading.Sync.Core.dll',
        'Assets\Web\index.html',
        'Scripts\Sync-BasketsToOneDrive.ps1'
    )
    foreach($relativePath in $distinguishablePayloadTargets) {
        if(-not $priorPayloadHashes.ContainsKey($relativePath)) { throw "Rollback probe target is absent from the product payload manifest: $relativePath" }
        if($priorPayloadHashes[$relativePath] -ceq $expectedFaultProbeHash) { throw "Fault probe hash unexpectedly matches a production payload file: $relativePath" }
    }
    $priorEntry = Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot
    $incomingOnlyPath = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'Assets\Web\Task9IncomingOnly.bin')
    if((Test-Path -LiteralPath $incomingOnlyPath) -or (Test-Path -LiteralPath (Join-Path $installRoot 'Task9UpgradeFault.blocked'))) {
        throw 'Production installation contains an acceptance-only rollback seam.'
    }
    $faultCollision = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'Task9UpgradeFault.blocked')
    if(Test-Path -LiteralPath $faultCollision) { throw 'The task-scoped fault collision path already exists.' }
    New-Item -ItemType Directory -Path $faultCollision | Out-Null
    $faultExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASKS=desktopicon',"/LOG=`"$faultLog`"")
    if($faultExit -eq 0) { throw 'Fault-injection installer unexpectedly succeeded.' }
    Assert-SafeProtectedInstallPath -Path $faultCollision | Out-Null
    Remove-Item -LiteralPath $faultCollision -Force
    $faultLogContent = Get-Content -LiteralPath $faultLog -Raw
    $probeLogIndex = $faultLogContent.IndexOf('Task9IncomingOnly.bin',[StringComparison]::OrdinalIgnoreCase)
    $collisionLogIndex = $faultLogContent.IndexOf('Task9UpgradeFault.blocked',[StringComparison]::OrdinalIgnoreCase)
    if($probeLogIndex -lt 0 -or $collisionLogIndex -le $probeLogIndex) { throw 'Fault installer did not copy the distinguishable probe before rollback.' }
    if(Test-Path -LiteralPath $incomingOnlyPath) { throw 'Failed upgrade left the manifest-owned incoming-only payload installed.' }
    if((Get-FileHash $installedExe -Algorithm SHA256).Hash -cne $priorExeHash) { throw 'Failed upgrade changed the installed executable.' }
    $afterFaultPayloadHashes = Get-InstalledPayloadHashes -InstallRoot $installRoot
    if($afterFaultPayloadHashes.Count -ne $priorPayloadHashes.Count) { throw 'Failed upgrade changed the allowlisted product payload.' }
    foreach($relativePath in $priorPayloadHashes.Keys) {
        if(-not $afterFaultPayloadHashes.ContainsKey($relativePath) -or
           $afterFaultPayloadHashes[$relativePath] -cne $priorPayloadHashes[$relativePath]) {
            throw "Failed upgrade changed the allowlisted product payload: $relativePath"
        }
    }
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Failed upgrade removed preserved state.' }
    $afterFaultEntry = Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot
    if([string]$afterFaultEntry.UninstallString -cne [string]$priorEntry.UninstallString) { throw 'Failed upgrade changed uninstall registration.' }

    # A restore failure must retain the durable active transaction, then recover on the next run.
    New-Item -ItemType Directory -Path $faultCollision | Out-Null
    $restoreFailureExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASKS=desktopicon','/TASK9MODE=restorefail',"/LOG=`"$restoreFailureLog`"")
    if($restoreFailureExit -eq 0) { throw 'Injected restore failure unexpectedly succeeded.' }
    Remove-Item -LiteralPath $faultCollision -Force
    $activeRecovery = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot '.ammar-installer-recovery.active')
    if(-not (Test-Path -LiteralPath $activeRecovery -PathType Container)) { throw 'Injected restore failure did not retain active durable state.' }
    $recoveryExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=recoveryonly',"/LOG=`"$recoveryLog`"")
    if($recoveryExit -eq 0) { throw 'Recovery-only test unexpectedly continued into installation.' }
    if(Test-Path -LiteralPath $activeRecovery) { throw 'Normal recovery did not clear retained active durable state.' }
    $afterRestoreFailureHashes = Get-InstalledPayloadHashes -InstallRoot $installRoot
    Assert-ProductPathStateEqual -Expected $priorPayloadHashes -Actual $afterRestoreFailureHashes -Message 'Recovery after injected restore failure did not restore the old product payload.'
    if(Test-Path -LiteralPath $incomingOnlyPath) { throw 'Recovery after injected restore failure left the incoming-only path.' }
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null

    # Kill setup after its durable ACTIVE marker, corrupt state, prove validation is mutation-free,
    # then restore the state checksum and prove stale recovery runs before any new mutation.
    New-Item -ItemType Directory -Path $faultCollision | Out-Null
    $crashArguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=crash',"/LOG=`"$crashLog`"")
    $crashProcess = Start-Process -FilePath $resolvedFaultInstaller -ArgumentList $crashArguments -PassThru
    $crashReady = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'crash-ready')
    $crashDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path -LiteralPath $crashReady -PathType Leaf) -and -not $crashProcess.HasExited -and [DateTime]::UtcNow -lt $crashDeadline) {
        Start-Sleep -Milliseconds 250
        $crashProcess.Refresh()
    }
    if(-not (Test-Path -LiteralPath $crashReady -PathType Leaf)) {
        if(-not $crashProcess.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $crashProcess.Id /T /F | Out-Null }
        throw 'Fault installer did not reach the durable crash-ready marker.'
    }
    & "$env:SystemRoot\System32\taskkill.exe" /PID $crashProcess.Id /T /F | Out-Null
    [void]$crashProcess.WaitForExit(10000)
    Remove-Item -LiteralPath $faultCollision -Force
    if(-not (Test-Path -LiteralPath $activeRecovery -PathType Container)) { throw 'Killed setup did not retain active durable state.' }
    $unionRelativePaths = @($priorPayloadHashes.Keys) + 'Assets\Web\Task9IncomingOnly.bin'
    $postCrashState = Get-ProductPathState -InstallRoot $installRoot -RelativePaths $unionRelativePaths
    $stateHashPath = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'state.sha256')
    $goodStateHashBytes = [IO.File]::ReadAllBytes($stateHashPath)
    [IO.File]::WriteAllText($stateHashPath,'corrupt',(New-Object Text.UTF8Encoding($false)))
    $corruptRecoveryExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=recoveryonly')
    if($corruptRecoveryExit -eq 0) { throw 'Corrupt recovery state unexpectedly passed validation.' }
    $afterCorruptState = Get-ProductPathState -InstallRoot $installRoot -RelativePaths $unionRelativePaths
    Assert-ProductPathStateEqual -Expected $postCrashState -Actual $afterCorruptState -Message 'Corrupt recovery state changed product payload before validation.'
    if(-not (Test-Path -LiteralPath $activeRecovery -PathType Container)) { throw 'Corrupt recovery state was not retained for support.' }
    [IO.File]::WriteAllBytes($stateHashPath,$goodStateHashBytes)
    $crashRecoveryExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=recoveryonly')
    if($crashRecoveryExit -eq 0) { throw 'Crash recovery-only test unexpectedly continued into installation.' }
    if(Test-Path -LiteralPath $activeRecovery) { throw 'Crash recovery left active durable state.' }
    $afterCrashRecoveryHashes = Get-InstalledPayloadHashes -InstallRoot $installRoot
    Assert-ProductPathStateEqual -Expected $priorPayloadHashes -Actual $afterCrashRecoveryHashes -Message 'Crash recovery did not restore the old product payload.'
    if($afterCrashRecoveryHashes['AmmarTrading.Sync.payload-manifest.txt'] -cne $priorManifestHash) { throw 'Crash recovery did not restore the old manifest bytes and hash.' }
    if(Test-Path -LiteralPath $incomingOnlyPath) { throw 'Crash recovery did not remove the manifest-owned incoming-only path.' }
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Recovery tests removed preserved state.' }

    Invoke-CheckedProcess -FilePath $resolvedInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASKS=desktopicon',"/LOG=`"$upgradeLog`"")
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Successful upgrade removed preserved state.' }
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null

    $uninstaller = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'unins000.exe')
    Invoke-CheckedProcess -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$uninstallLog`"")
    if((Test-Path -LiteralPath $installedExe) -or (Test-Path -LiteralPath $startMenuShortcut) -or (Test-Path -LiteralPath $desktopShortcut) -or @(Get-UninstallEntry).Count) { throw 'Uninstall did not remove product files and registration.' }
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Uninstall removed preserved state.' }
    $setupAttempted = $false
    Write-Host 'AmmarTrading Sync install, failed-upgrade rollback, successful upgrade, and uninstall acceptance passed.'
} finally {
    if($null -ne $launchedProcessId) {
        $runningApp = Get-Process -Id $launchedProcessId -ErrorAction SilentlyContinue
        if($null -ne $runningApp) {
            try {
                if($runningApp.Path -ieq (Join-Path $installRoot 'AmmarTrading.Sync.exe')) { Stop-Process $runningApp.Id -Force }
            } catch { }
        }
    }
    if($launchTaskCreated) { Unregister-ScheduledTask -TaskName $launchTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    if($setupAttempted) { Repair-FailedSetupAttempt -AcceptanceRoot $acceptanceRoot -InstallRoot $installRoot -StartMenuShortcut $startMenuShortcut -DesktopShortcut $desktopShortcut }
    if($taskCreated) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $runtimeSentinel -Force -ErrorAction SilentlyContinue
    if(-not $runtimeExisted -and (Test-Path $runtimeRoot) -and @(Get-ChildItem $runtimeRoot -Force -ErrorAction SilentlyContinue).Count -eq 0){Remove-Item $runtimeRoot -Force}
    Assert-SafeAcceptancePath -Path $acceptanceRoot -AcceptanceRoot $acceptanceRoot -AllowRoot | Out-Null
    if(Test-Path $acceptanceRoot){Remove-Item -LiteralPath $acceptanceRoot -Recurse -Force}
    $retainedRecovery = @(Get-ChildItem -LiteralPath $protectedAcceptanceRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object Name -like '.ammar-installer-recovery.*')
    if((Test-Path $protectedAcceptanceRoot) -and $retainedRecovery.Count -eq 0 -and @(Get-UninstallEntry).Count -eq 0){
        Assert-SafeProtectedInstallPath -Path $protectedAcceptanceRoot | Out-Null
        Remove-Item -LiteralPath $protectedAcceptanceRoot -Recurse -Force
    } elseif($retainedRecovery.Count -gt 0) {
        Write-Warning "Retained durable recovery evidence for support: $($retainedRecovery.FullName -join ', ')"
    }
}
