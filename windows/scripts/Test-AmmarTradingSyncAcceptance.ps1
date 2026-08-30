[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Installer,
    [string]$FaultInstaller,
    [string]$ExpectedInstallerSha256,
    [switch]$ProductionInstallOnly,
    [string]$ProductionInstallLogPath
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

function Get-ExactVersionDwordEvidence {
    $keyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstallSubKey"
    $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
    $evidence = [ordered]@{}
    foreach($name in @('MajorVersion','MinorVersion')) {
        if($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
            throw "$name is missing or is not an exact registry DWORD."
        }
        $evidence[$name] = [uint32]$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    return [pscustomobject]$evidence
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

function Get-ExactRegistrationBoundaryState {
    $keyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstallSubKey"
    $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
    $lines = New-Object Collections.Generic.List[string]
    foreach($name in @('DisplayName','DisplayVersion','InstallLocation','UninstallString','QuietUninstallString','MajorVersion','MinorVersion')) {
        if(-not ($key.GetValueNames() -contains $name)) {
            [void]$lines.Add("MISSING|$name")
            continue
        }
        $kind = $key.GetValueKind($name)
        $value = $key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$value))
        [void]$lines.Add("$kind|$name|$encoded")
    }
    return $lines -join "`n"
}

function Write-IncomingProofLines {
    param(
        [Parameter(Mandatory)][string]$ProofPath,
        [Parameter(Mandatory)][string]$ProofHashPath,
        [Parameter(Mandatory)][string[]]$Lines
    )
    [IO.File]::WriteAllLines($ProofPath,$Lines,(New-Object Text.UTF8Encoding($false)))
    $digest = (Get-FileHash -LiteralPath $ProofPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($ProofHashPath,$digest,(New-Object Text.UTF8Encoding($false)))
}

function Set-IncomingProofLine {
    param(
        [Parameter(Mandatory)][string]$ProofPath,
        [Parameter(Mandatory)][string]$ProofHashPath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Value
    )
    $lines = @(Get-Content -LiteralPath $ProofPath)
    if($lines.Count -ne 11 -or $Index -lt 0 -or $Index -ge $lines.Count) {
        throw 'The incoming proof fixture is not the expected V1 shape.'
    }
    $lines[$Index] = $Value
    Write-IncomingProofLines -ProofPath $ProofPath -ProofHashPath $ProofHashPath -Lines $lines
}

function Invoke-BlockedIncomingProofUninstallCase {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Uninstaller,
        [Parameter(Mandatory)][string]$ProofPath,
        [Parameter(Mandatory)][string]$ProofHashPath,
        [Parameter(Mandatory)][byte[]]$GoodProofBytes,
        [Parameter(Mandatory)][byte[]]$GoodProofHashBytes,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$ActiveRecovery,
        [Parameter(Mandatory)][string[]]$RelativePaths,
        [Parameter(Mandatory)][scriptblock]$Mutate
    )
    $beforePayload = Get-ProductPathState -InstallRoot $InstallRoot -RelativePaths $RelativePaths
    $beforeRegistration = Get-ExactRegistrationBoundaryState
    try {
        & $Mutate $ProofPath $ProofHashPath
        $exitCode = Invoke-BoundedProcess -FilePath $Uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
        if($exitCode -eq 0) { throw "$Label incoming proof uninstall unexpectedly succeeded." }
        if(-not (Test-Path -LiteralPath $ActiveRecovery -PathType Container)) {
            throw "$Label incoming proof uninstall removed ACTIVE evidence."
        }
        Assert-ExactUninstallEntry -ExpectedInstallRoot $InstallRoot | Out-Null
        $afterPayload = Get-ProductPathState -InstallRoot $InstallRoot -RelativePaths $RelativePaths
        Assert-ProductPathStateEqual -Expected $beforePayload -Actual $afterPayload -Message "$Label incoming proof uninstall mutated product payload."
        if((Get-ExactRegistrationBoundaryState) -cne $beforeRegistration) {
            throw "$Label incoming proof uninstall mutated registration."
        }
    } finally {
        if(Test-Path -LiteralPath $ProofPath) { Remove-Item -LiteralPath $ProofPath -Force }
        if(Test-Path -LiteralPath $ProofHashPath) { Remove-Item -LiteralPath $ProofHashPath -Force }
        if(Test-Path -LiteralPath $ActiveRecovery -PathType Container) {
            [IO.File]::WriteAllBytes($ProofPath,$GoodProofBytes)
            [IO.File]::WriteAllBytes($ProofHashPath,$GoodProofHashBytes)
        }
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
if($ProductionInstallOnly) {
    if($ExpectedInstallerSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Production installation requires an explicit lowercase SHA-256 pin.'
    }
    if(-not [string]::IsNullOrWhiteSpace($FaultInstaller)) { throw 'A fault-injection installer cannot be used for production installation.' }
    $actualInstallerSha256 = (Get-FileHash -LiteralPath $resolvedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    if($actualInstallerSha256 -cne $ExpectedInstallerSha256) { throw 'The installer SHA-256 does not match the approved candidate.' }
    if(Get-Process -Name 'AmmarTrading.Sync' -ErrorAction SilentlyContinue) {
        throw 'Close AmmarTrading Sync before installing or upgrading the approved candidate.'
    }
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-')
    if(-not [string]::IsNullOrWhiteSpace($ProductionInstallLogPath)) {
        $logPath = [IO.Path]::GetFullPath($ProductionInstallLogPath)
        $logDirectory = Split-Path -Parent $logPath
        if(-not (Test-Path -LiteralPath $logDirectory -PathType Container)) { New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null }
        $arguments += "/LOG=`"$logPath`""
    }
    Invoke-CheckedProcess -FilePath $resolvedInstaller -ArgumentList $arguments
    $entry = @(Get-UninstallEntry)
    if($entry.Count -ne 1 -or [string]$entry[0].DisplayName -cne 'AmmarTrading Sync') { throw 'The approved candidate did not create the exact product registration.' }
    $installRoot = [IO.Path]::GetFullPath([string]$entry[0].InstallLocation).TrimEnd('\')
    $installedExe = Join-Path $installRoot 'AmmarTrading.Sync.exe'
    if(-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) { throw 'The approved candidate did not install the desktop executable.' }
    [pscustomobject][ordered]@{
        Status='Pass'
        ProductName='AmmarTrading Sync'
        InstallerSha256=$actualInstallerSha256
        InstalledVersion=[string]$entry[0].DisplayVersion
        CapturedUtc=[DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 3
    exit 0
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
$webViewFailureLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'webview-preflight-failure.log') -AcceptanceRoot $acceptanceRoot
$incomingCompleteLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'incoming-complete-crash.log') -AcceptanceRoot $acceptanceRoot
$postMarkerLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'post-marker-crash.log') -AcceptanceRoot $acceptanceRoot
$finalIncomingLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'final-incoming-crash.log') -AcceptanceRoot $acceptanceRoot
$finalIncomingUninstallLog = Assert-SafeAcceptancePath -Path (Join-Path $acceptanceRoot 'final-incoming-uninstall.log') -AcceptanceRoot $acceptanceRoot

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
$staleIncomingProofBytes = $null
$staleIncomingProofHashBytes = $null
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
    $webViewFailureExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=webviewfail',"/LOG=`"$webViewFailureLog`"")
    if($webViewFailureExit -eq 0) { throw 'Injected WebView prerequisite failure unexpectedly succeeded.' }
    if((Test-Path -LiteralPath (Join-Path $installRoot 'AmmarTrading.Sync.exe')) -or
       (Test-Path -LiteralPath (Join-Path $installRoot '.ammar-installer-recovery.active')) -or
       @(Get-UninstallEntry).Count -ne 0) { throw 'WebView prerequisite failure changed product payload, recovery state, or registration.' }
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
        $launchedProcess = Get-Process 'AmmarTrading.Sync' -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -ieq $installedExe } catch { $false } } | Select-Object -First 1
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
    $priorDisplayVersion = [string]$priorEntry.DisplayVersion
    $priorVersionDwords = Get-ExactVersionDwordEvidence
    if($priorDisplayVersion -cne '1.0.0' -or
       $priorVersionDwords.MajorVersion -ne 1 -or
       $priorVersionDwords.MinorVersion -ne 0) {
        throw 'Production baseline version metadata was not exact.'
    }
    $priorUninsExeHash = (Get-FileHash -LiteralPath (Join-Path $installRoot 'unins000.exe') -Algorithm SHA256).Hash
    $priorUninsDatHash = (Get-FileHash -LiteralPath (Join-Path $installRoot 'unins000.dat') -Algorithm SHA256).Hash
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

    # Kill after version-changing metadata was written but before the ssDone COMMITTED marker.
    # No marker means rollback of payload, exact AppId metadata, and finalized uninstaller files.
    $incomingCompleteArguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=premarkercrash',"/LOG=`"$incomingCompleteLog`"")
    $incomingCompleteProcess = Start-Process -FilePath $resolvedFaultInstaller -ArgumentList $incomingCompleteArguments -PassThru
    $incomingCompleteReady = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'premarker-ready')
    $incomingCompleteDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path -LiteralPath $incomingCompleteReady -PathType Leaf) -and -not $incomingCompleteProcess.HasExited -and [DateTime]::UtcNow -lt $incomingCompleteDeadline) {
        Start-Sleep -Milliseconds 250
        $incomingCompleteProcess.Refresh()
    }
    if(-not (Test-Path -LiteralPath $incomingCompleteReady -PathType Leaf)) {
        if(-not $incomingCompleteProcess.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $incomingCompleteProcess.Id /T /F | Out-Null }
        throw 'Fault installer did not reach the pre-marker metadata boundary.'
    }
    & "$env:SystemRoot\System32\taskkill.exe" /PID $incomingCompleteProcess.Id /T /F | Out-Null
    [void]$incomingCompleteProcess.WaitForExit(10000)
    if(-not (Test-Path -LiteralPath $activeRecovery -PathType Container)) { throw 'Pre-marker crash did not retain ACTIVE state.' }
    if(-not (Test-Path -LiteralPath $incomingOnlyPath -PathType Leaf) -or
       (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedFaultProbeHash) {
        throw 'Pre-marker crash did not install the distinguishable incoming payload.'
    }
    if([string](Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot).DisplayVersion -cne '9.9.9') { throw 'Fault installer did not create genuinely version-changing metadata.' }
    $faultVersionDwords = Get-ExactVersionDwordEvidence
    if($faultVersionDwords.MajorVersion -ne 9 -or $faultVersionDwords.MinorVersion -ne 9) { throw 'Fault installer did not write exact 9.9 MajorVersion and MinorVersion DWORDs.' }
    $incomingRecoveryExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=recoveryonly')
    if($incomingRecoveryExit -eq 0) { throw 'Pre-marker recovery-only test unexpectedly continued into installation.' }
    if(Test-Path -LiteralPath $activeRecovery) { throw 'Pre-marker recovery did not clear ACTIVE state.' }
    $preMarkerRestored = Get-InstalledPayloadHashes -InstallRoot $installRoot
    Assert-ProductPathStateEqual -Expected $priorPayloadHashes -Actual $preMarkerRestored -Message 'Pre-marker recovery did not restore the prior payload.'
    if(Test-Path -LiteralPath $incomingOnlyPath) { throw 'Pre-marker recovery did not remove the incoming-only path.' }
    $preMarkerEntry = Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot
    $preMarkerVersionDwords = Get-ExactVersionDwordEvidence
    if([string]$preMarkerEntry.DisplayVersion -cne $priorDisplayVersion -or
       $preMarkerVersionDwords.MajorVersion -ne $priorVersionDwords.MajorVersion -or
       $preMarkerVersionDwords.MinorVersion -ne $priorVersionDwords.MinorVersion -or
       (Get-FileHash -LiteralPath (Join-Path $installRoot 'unins000.exe') -Algorithm SHA256).Hash -cne $priorUninsExeHash -or
       (Get-FileHash -LiteralPath (Join-Path $installRoot 'unins000.dat') -Algorithm SHA256).Hash -cne $priorUninsDatHash) {
        throw 'Pre-marker recovery did not restore prior uninstall metadata.'
    }
    if($preMarkerVersionDwords.MajorVersion -ne $priorVersionDwords.MajorVersion -or
       $preMarkerVersionDwords.MinorVersion -ne $priorVersionDwords.MinorVersion) { throw 'Pre-marker recovery did not restore exact prior version DWORD metadata.' }

    # Kill after the exact finalized marker is durable but before verified cleanup.
    # The next run must finalize incoming 9.9.9 without rollback.
    $postMarkerArguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=postmarkercrash',"/LOG=`"$postMarkerLog`"")
    $postMarkerProcess = Start-Process -FilePath $resolvedFaultInstaller -ArgumentList $postMarkerArguments -PassThru
    $postMarkerReady = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'postmarker-ready')
    $postMarkerDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path -LiteralPath $postMarkerReady -PathType Leaf) -and -not $postMarkerProcess.HasExited -and [DateTime]::UtcNow -lt $postMarkerDeadline) { Start-Sleep -Milliseconds 250; $postMarkerProcess.Refresh() }
    if(-not (Test-Path -LiteralPath $postMarkerReady -PathType Leaf)) { if(-not $postMarkerProcess.HasExited){& "$env:SystemRoot\System32\taskkill.exe" /PID $postMarkerProcess.Id /T /F|Out-Null}; throw 'Fault installer did not reach the post-marker boundary.' }
    & "$env:SystemRoot\System32\taskkill.exe" /PID $postMarkerProcess.Id /T /F | Out-Null
    [void]$postMarkerProcess.WaitForExit(10000)
    $firstIncomingProofPath = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'incoming-uninstaller-verified.txt')
    $firstIncomingProofHashPath = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'incoming-uninstaller-verified.sha256')
    if(-not (Test-Path -LiteralPath $firstIncomingProofPath -PathType Leaf) -or
       -not (Test-Path -LiteralPath $firstIncomingProofHashPath -PathType Leaf)) {
        throw 'Post-marker transaction did not retain the incoming uninstaller proof.'
    }
    $staleIncomingProofBytes = [IO.File]::ReadAllBytes($firstIncomingProofPath)
    $staleIncomingProofHashBytes = [IO.File]::ReadAllBytes($firstIncomingProofHashPath)
    $postMarkerRecoveryExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=recoveryonly')
    if($postMarkerRecoveryExit -eq 0) { throw 'Post-marker recovery-only test unexpectedly continued.' }
    if(Test-Path -LiteralPath $activeRecovery) { throw 'Post-marker recovery did not finalize ACTIVE state.' }
    if(-not (Test-Path -LiteralPath $incomingOnlyPath) -or (Get-FileHash $installedExe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedFaultProbeHash) { throw 'Post-marker recovery restored the prior payload.' }
    if([string](Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot).DisplayVersion -cne '9.9.9') { throw 'Post-marker recovery changed finalized incoming metadata.' }

    Invoke-CheckedProcess -FilePath $resolvedInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASKS=desktopicon',"/LOG=`"$upgradeLog`"")
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Successful upgrade removed preserved state.' }
    if(Test-Path -LiteralPath $incomingOnlyPath) { throw 'Successful upgrade retained an obsolete manifest-owned path.' }
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null

    # Uninstall must use the same classifier: corrupt ACTIVE state blocks with zero payload
    # mutation; once the exact state checksum is repaired, prior-state recovery precedes removal.
    $priorToUninstallCrash = Get-InstalledPayloadHashes -InstallRoot $installRoot
    New-Item -ItemType Directory -Path $faultCollision | Out-Null
    $uninstallCrashProcess = Start-Process -FilePath $resolvedFaultInstaller -ArgumentList $crashArguments -PassThru
    $uninstallCrashDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path -LiteralPath $crashReady -PathType Leaf) -and -not $uninstallCrashProcess.HasExited -and [DateTime]::UtcNow -lt $uninstallCrashDeadline) {
        Start-Sleep -Milliseconds 250
        $uninstallCrashProcess.Refresh()
    }
    if(-not (Test-Path -LiteralPath $crashReady -PathType Leaf)) {
        if(-not $uninstallCrashProcess.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $uninstallCrashProcess.Id /T /F | Out-Null }
        throw 'Uninstall guard setup did not reach ACTIVE state.'
    }
    & "$env:SystemRoot\System32\taskkill.exe" /PID $uninstallCrashProcess.Id /T /F | Out-Null
    [void]$uninstallCrashProcess.WaitForExit(10000)
    Remove-Item -LiteralPath $faultCollision -Force
    if(-not (Test-Path -LiteralPath $incomingOnlyPath -PathType Leaf)) { throw 'Uninstall guard crash did not create the incoming-only path.' }
    foreach($relativePath in $priorToUninstallCrash.Keys) {
        if($relativePath -in $distinguishablePayloadTargets -and
           (Get-FileHash -LiteralPath (Join-Path $installRoot $relativePath) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $priorToUninstallCrash[$relativePath]) {
            throw "Uninstall guard crash did not replace prior evidence: $relativePath"
        }
    }
    $uninstaller = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'unins000.exe')
    $noProofState = Get-ProductPathState -InstallRoot $installRoot -RelativePaths $unionRelativePaths
    $noProofExit = Invoke-BoundedProcess -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if($noProofExit -eq 0) { throw 'ACTIVE uninstall without prior-uninstaller proof unexpectedly succeeded.' }
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null
    $afterNoProof = Get-ProductPathState -InstallRoot $installRoot -RelativePaths $unionRelativePaths
    Assert-ProductPathStateEqual -Expected $noProofState -Actual $afterNoProof -Message 'No-proof ACTIVE uninstall mutated product payload.'

    $proofRecoveryExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=restorefail')
    if($proofRecoveryExit -eq 0) { throw 'Proof-producing injected restore failure unexpectedly succeeded.' }
    $proofPath = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'prior-uninstaller-verified.txt')
    $proofHashPath = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'prior-uninstaller-verified.sha256')
    if(-not (Test-Path -LiteralPath $proofPath -PathType Leaf) -or -not (Test-Path -LiteralPath $proofHashPath -PathType Leaf)) { throw 'Restore failure did not retain verified prior-uninstaller proof.' }
    $goodProofHashBytes = [IO.File]::ReadAllBytes($proofHashPath)
    $proofCorruptState = Get-ProductPathState -InstallRoot $installRoot -RelativePaths $unionRelativePaths
    [IO.File]::WriteAllText($proofHashPath,'corrupt',(New-Object Text.UTF8Encoding($false)))
    $corruptUninstallExit = Invoke-BoundedProcess -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if($corruptUninstallExit -eq 0) { throw 'Corrupt prior-uninstaller proof uninstall unexpectedly succeeded.' }
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null
    $afterBlockedUninstall = Get-ProductPathState -InstallRoot $installRoot -RelativePaths $unionRelativePaths
    Assert-ProductPathStateEqual -Expected $proofCorruptState -Actual $afterBlockedUninstall -Message 'Corrupt proof uninstall mutated product payload.'
    [IO.File]::WriteAllBytes($proofHashPath,$goodProofHashBytes)
    Invoke-CheckedProcess -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$uninstallLog`"")
    $uninstallLogContent = Get-Content -LiteralPath $uninstallLog -Raw
    if($uninstallLogContent -notmatch 'Durable prior payload and incoming-only paths verified before uninstall') { throw 'Incoming-only path was not verified absent before uninstall.' }
    if(Test-Path -LiteralPath $incomingOnlyPath) { throw 'Incoming-only path remained after uninstall.' }
    if(Test-Path -LiteralPath $activeRecovery) { throw 'Active transaction uninstall did not recover before removal.' }
    if((Test-Path -LiteralPath $installedExe) -or (Test-Path -LiteralPath $startMenuShortcut) -or (Test-Path -LiteralPath $desktopShortcut) -or @(Get-UninstallEntry).Count) { throw 'Uninstall did not remove product files and registration.' }
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) { throw 'Uninstall removed preserved state.' }

    # Reinstall, retain a finalized incoming transaction, and prove its separate proof is
    # fail-closed at every binding before the locked-DAT final-uninstall path is accepted.
    Invoke-CheckedProcess -FilePath $resolvedInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASKS=desktopicon')
    $installedExe = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'AmmarTrading.Sync.exe')
    Assert-ExactUninstallEntry -ExpectedInstallRoot $installRoot | Out-Null
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or
       $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw 'Reinstall before incoming-proof acceptance removed preserved state.'
    }

    $finalPostMarkerArguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=postmarkercrash',"/LOG=`"$finalIncomingLog`"")
    $finalPostMarkerProcess = Start-Process -FilePath $resolvedFaultInstaller -ArgumentList $finalPostMarkerArguments -PassThru
    $finalPostMarkerReady = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'postmarker-ready')
    $finalPostMarkerDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path -LiteralPath $finalPostMarkerReady -PathType Leaf) -and
          -not $finalPostMarkerProcess.HasExited -and [DateTime]::UtcNow -lt $finalPostMarkerDeadline) {
        Start-Sleep -Milliseconds 250
        $finalPostMarkerProcess.Refresh()
    }
    if(-not (Test-Path -LiteralPath $finalPostMarkerReady -PathType Leaf)) {
        if(-not $finalPostMarkerProcess.HasExited) { & "$env:SystemRoot\System32\taskkill.exe" /PID $finalPostMarkerProcess.Id /T /F | Out-Null }
        throw 'Final incoming-proof setup did not reach the post-marker boundary.'
    }
    & "$env:SystemRoot\System32\taskkill.exe" /PID $finalPostMarkerProcess.Id /T /F | Out-Null
    [void]$finalPostMarkerProcess.WaitForExit(10000)
    if(-not (Test-Path -LiteralPath $activeRecovery -PathType Container)) { throw 'Final incoming-proof setup did not retain ACTIVE state.' }
    $incomingProofPath = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'incoming-uninstaller-verified.txt')
    $incomingProofHashPath = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'incoming-uninstaller-verified.sha256')
    if(-not (Test-Path -LiteralPath $incomingProofPath -PathType Leaf) -or
       -not (Test-Path -LiteralPath $incomingProofHashPath -PathType Leaf)) {
        throw 'Final committed transaction did not retain its incoming uninstaller proof.'
    }
    if($null -eq $staleIncomingProofBytes -or $null -eq $staleIncomingProofHashBytes) {
        throw 'The earlier committed transaction did not provide a stale-proof fixture.'
    }
    $goodIncomingProofBytes = [IO.File]::ReadAllBytes($incomingProofPath)
    $goodIncomingProofHashBytes = [IO.File]::ReadAllBytes($incomingProofHashPath)
    $finalIncomingPaths = @((Get-InstalledPayloadHashes -InstallRoot $installRoot).Keys)
    $finalIncomingState = Get-ProductPathState -InstallRoot $installRoot -RelativePaths $finalIncomingPaths
    $finalIncomingRegistration = Get-ExactRegistrationBoundaryState
    $uninstaller = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'unins000.exe')

    $currentDatPath = Assert-SafeProtectedInstallPath -Path (Join-Path $installRoot 'unins000.dat')
    $goodCurrentDatBytes = [IO.File]::ReadAllBytes($currentDatPath)
    try {
        [IO.File]::WriteAllText($currentDatPath,'task9-live-dat-tamper',(New-Object Text.UTF8Encoding($false)))
        $datTamperExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=recoveryonly')
        if($datTamperExit -eq 0 -or -not (Test-Path -LiteralPath $activeRecovery -PathType Container)) {
            throw 'Valid incoming proof bypassed live DAT validation outside uninstall.'
        }
    } finally {
        [IO.File]::WriteAllBytes($currentDatPath,$goodCurrentDatBytes)
    }
    Assert-ProductPathStateEqual -Expected $finalIncomingState -Actual (Get-ProductPathState -InstallRoot $installRoot -RelativePaths $finalIncomingPaths) -Message 'Live DAT validation changed incoming payload.'
    if((Get-ExactRegistrationBoundaryState) -cne $finalIncomingRegistration) { throw 'Live DAT validation changed incoming registration.' }

    $registrationKeyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstallSubKey"
    $goodDisplayName = [string](Get-ItemProperty -LiteralPath $registrationKeyPath -Name DisplayName).DisplayName
    try {
        Set-ItemProperty -LiteralPath $registrationKeyPath -Name DisplayName -Value 'Task9 registration tamper'
        $registrationTamperExit = Invoke-BoundedProcess -FilePath $resolvedFaultInstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=`"$installRoot`"",'/TASK9MODE=recoveryonly')
        if($registrationTamperExit -eq 0 -or -not (Test-Path -LiteralPath $activeRecovery -PathType Container)) {
            throw 'Valid incoming proof bypassed live registration validation outside uninstall.'
        }
    } finally {
        Set-ItemProperty -LiteralPath $registrationKeyPath -Name DisplayName -Value $goodDisplayName
    }
    Assert-ProductPathStateEqual -Expected $finalIncomingState -Actual (Get-ProductPathState -InstallRoot $installRoot -RelativePaths $finalIncomingPaths) -Message 'Live registration validation changed incoming payload.'
    if((Get-ExactRegistrationBoundaryState) -cne $finalIncomingRegistration) { throw 'Live registration validation was not restored exactly.' }

    $zeroDigest = ('0' * 64) -join ''
    $blockedCaseParameters = @{
        Uninstaller = $uninstaller
        ProofPath = $incomingProofPath
        ProofHashPath = $incomingProofHashPath
        GoodProofBytes = $goodIncomingProofBytes
        GoodProofHashBytes = $goodIncomingProofHashBytes
        InstallRoot = $installRoot
        ActiveRecovery = $activeRecovery
        RelativePaths = $finalIncomingPaths
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Missing' -Mutate {
        param($path,$hashPath)
        Remove-Item -LiteralPath $path,$hashPath -Force
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Malformed' -Mutate {
        param($path,$hashPath)
        Write-IncomingProofLines -ProofPath $path -ProofHashPath $hashPath -Lines @('malformed')
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Corrupt-checksum' -Mutate {
        param($path,$hashPath)
        [IO.File]::WriteAllText($hashPath,'corrupt',(New-Object Text.UTF8Encoding($false)))
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-AppId' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 1 -Value 'APPID|{00000000-0000-0000-0000-000000000000}'
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-root' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 2 -Value "ROOT|$installRoot-wrong"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-transaction' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 3 -Value 'TXID|wrong-transaction'
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-state' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 4 -Value "STATE|$zeroDigest"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-marker' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 5 -Value "COMMITTED|$zeroDigest"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-manifest' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 6 -Value "INCOMINGMANIFEST|$zeroDigest"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-hashes' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 7 -Value "INCOMINGHASHES|$zeroDigest"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-registration' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 8 -Value "REGISTRATION|$zeroDigest"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-EXE' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 9 -Value "UNINSEXE|0|$zeroDigest"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Wrong-DAT' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 10 -Value "UNINSDAT|0|$zeroDigest"
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Stale' -Mutate {
        param($path,$hashPath)
        [IO.File]::WriteAllBytes($path,$staleIncomingProofBytes)
        [IO.File]::WriteAllBytes($hashPath,$staleIncomingProofHashBytes)
    }
    Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Unsafe-path' -Mutate {
        param($path,$hashPath)
        Set-IncomingProofLine -ProofPath $path -ProofHashPath $hashPath -Index 2 -Value 'ROOT|C:\'
    }
    $reparseTarget = Assert-SafeProtectedInstallPath -Path (Join-Path $activeRecovery 'incoming-proof-reparse-target.txt')
    try {
        Invoke-BlockedIncomingProofUninstallCase @blockedCaseParameters -Label 'Reparse' -Mutate {
            param($path,$hashPath)
            [IO.File]::WriteAllBytes($reparseTarget,$goodIncomingProofBytes)
            Remove-Item -LiteralPath $path -Force
            New-Item -ItemType SymbolicLink -Path $path -Target $reparseTarget | Out-Null
        }
    } finally {
        Remove-Item -LiteralPath $reparseTarget -Force -ErrorAction SilentlyContinue
    }

    Invoke-CheckedProcess -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$finalIncomingUninstallLog`"")
    if(Test-Path -LiteralPath $activeRecovery) { throw 'Incoming committed transaction did not finalize before final uninstall.' }
    $finalIncomingUninstallContent = Get-Content -LiteralPath $finalIncomingUninstallLog -Raw
    if($finalIncomingUninstallContent -notmatch 'Durable incoming uninstaller proof accepted') { throw 'Final uninstall did not validate the incoming proof.' }
    if((Test-Path -LiteralPath $installedExe) -or (Test-Path -LiteralPath $incomingOnlyPath) -or
       (Test-Path -LiteralPath $startMenuShortcut) -or (Test-Path -LiteralPath $desktopShortcut) -or @(Get-UninstallEntry).Count) {
        throw 'Incoming final uninstall did not remove product files and registration.'
    }
    if(-not (Test-Path -LiteralPath $runtimeSentinel) -or -not (Test-Path -LiteralPath $oneDriveSentinel) -or
       $null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        throw 'Incoming final uninstall removed preserved state.'
    }
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
