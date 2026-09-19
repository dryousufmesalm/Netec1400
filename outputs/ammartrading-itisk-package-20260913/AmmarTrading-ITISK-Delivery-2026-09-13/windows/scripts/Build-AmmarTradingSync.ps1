[CmdletBinding()]
param(
    [ValidateSet('Debug','Release')]
    [string]$Configuration = 'Release',
    [string]$WebView2BootstrapperPath,
    [string]$InnoCompilerPath,
    [ValidateSet('None','Preflight','PostPromotionCleanup')]
    [string]$Task9TestLifecycleFault = 'None'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$ProgressPreference = 'SilentlyContinue'

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @ArgumentList
        if($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
        }
    } finally {
        Pop-Location
    }
}

function Resolve-InnoCompiler {
    param([string]$RequestedPath)

    $candidates = @()
    if(-not [string]::IsNullOrWhiteSpace($RequestedPath)) { $candidates += $RequestedPath }
    if(-not [string]::IsNullOrWhiteSpace($env:INNO_SETUP_ISCC)) { $candidates += $env:INNO_SETUP_ISCC }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    foreach($candidate in $candidates) {
        if(-not [string]::IsNullOrWhiteSpace($candidate) -and
           (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'Inno Setup 6 compiler was not found. Install Inno Setup 6 or pass -InnoCompilerPath.'
}

function Assert-MicrosoftBootstrapper {
    param([Parameter(Mandatory)][string]$Path)

    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "WebView2 bootstrapper was not found: $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
    if($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
       $subject -notmatch 'Microsoft Corporation') {
        throw 'The WebView2 bootstrapper does not have a valid Microsoft Corporation Authenticode signature.'
    }
}

function Assert-ReleasePayload {
    param([Parameter(Mandatory)][string]$PublishDirectory)

    $required = @(
        'AmmarTrading.Sync.exe',
        'AmmarTrading.Sync.payload-manifest.txt',
        'Assets\Web\index.html',
        'Scripts\Install-BasketsSyncTask.ps1',
        'Scripts\Invoke-AmmarTradingDesktopOperation.ps1',
        'Scripts\MoneyMachineCsvSchemaV3.psm1',
        'Scripts\MoneyMachineSyncSetup.psm1',
        'Scripts\Sync-BasketsToOneDrive.ps1',
        'Scripts\Test-MoneyMachineSyncStatus.ps1'
    )
    foreach($relativePath in $required) {
        if(-not (Test-Path -LiteralPath (Join-Path $PublishDirectory $relativePath) -PathType Leaf)) {
            throw "Release payload is missing: $relativePath"
        }
    }

    $forbiddenExtensions = @('.cmd','.bat','.map','.pdb','.cs','.csproj','.sln')
    $forbiddenNames = @('Start-MoneyMachineSyncWizard.ps1','Start-MoneyMachineSyncWizard.cmd')
    foreach($file in @(Get-ChildItem -LiteralPath $PublishDirectory -File -Recurse -Force)) {
        if($file.Extension.ToLowerInvariant() -in $forbiddenExtensions -or $file.Name -in $forbiddenNames) {
            throw "Forbidden release payload file: $($file.FullName)"
        }
        if($file.FullName -match '[\\/](?:tests?|fixtures?)[\\/]') {
            throw "Test content must not be shipped: $($file.FullName)"
        }
    }
    $allowedExecutables = @('AmmarTrading.Sync.exe')
    $actualExecutables = @(Get-ChildItem -LiteralPath $PublishDirectory -File -Recurse -Filter '*.exe' | ForEach-Object Name | Sort-Object -Unique)
    if(Compare-Object -ReferenceObject $allowedExecutables -DifferenceObject $actualExecutables) {
        throw 'The release executable payload is not explicitly allowlisted.'
    }
}

function Remove-CanonicalReleaseArtifacts {
    param([string]$InstallerPath,[string]$ManifestPath,[string]$FaultPath,[string]$FaultProbeHashPath)
    Remove-Item -LiteralPath $InstallerPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ManifestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $FaultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $FaultProbeHashPath -Force -ErrorAction SilentlyContinue
    $faultDirectory = Split-Path -Parent $FaultPath
    if((Test-Path -LiteralPath $faultDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $faultDirectory -Force).Count -eq 0) {
        Remove-Item -LiteralPath $faultDirectory -Force
    }
}

function Assert-CanonicalReleaseArtifactsAbsent {
    param([string]$InstallerPath,[string]$ManifestPath,[string]$FaultPath,[string]$FaultProbeHashPath)
    foreach($path in @($InstallerPath,$ManifestPath,$FaultPath,$FaultProbeHashPath)) {
        if(Test-Path -LiteralPath $path) { throw "Canonical release artifact was not invalidated: $path" }
    }
}

function Publish-ReleaseArtifacts {
    param(
        [string]$StagedInstaller,[string]$StagedManifest,[string]$StagedFaultInstaller,[string]$StagedFaultProbeHash,
        [string]$InstallerPath,[string]$ManifestPath,[string]$FaultPath,[string]$FaultProbeHashPath
    )
    Remove-CanonicalReleaseArtifacts -InstallerPath $InstallerPath -ManifestPath $ManifestPath -FaultPath $FaultPath -FaultProbeHashPath $FaultProbeHashPath
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $FaultPath) -Force | Out-Null
        [IO.File]::Move($StagedFaultInstaller,$FaultPath)
        [IO.File]::Move($StagedFaultProbeHash,$FaultProbeHashPath)
        [IO.File]::Move($StagedManifest,$ManifestPath)
        [IO.File]::Move($StagedInstaller,$InstallerPath)
    } catch {
        Remove-CanonicalReleaseArtifacts -InstallerPath $InstallerPath -ManifestPath $ManifestPath -FaultPath $FaultPath -FaultProbeHashPath $FaultProbeHashPath
        throw
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$prototypeRoot = Join-Path $repoRoot 'prototypes\money-machine-sync-wizard'
$solutionPath = Join-Path $repoRoot 'windows\AmmarTrading.Sync.sln'
$appProject = Join-Path $repoRoot 'windows\src\AmmarTrading.Sync.App\AmmarTrading.Sync.App.csproj'
$installerScript = Join-Path $repoRoot 'windows\installer\AmmarTradingSync.iss'
$automationRoot = Join-Path $repoRoot 'automation\MoneyMachineCsvSync'
$artifactRoot = Join-Path $repoRoot 'artifacts\windows'
$buildRoot = Join-Path $artifactRoot ('.build-' + [Guid]::NewGuid().ToString('N'))
$publishRoot = Join-Path $buildRoot 'publish'
$productionOutputRoot = Join-Path $buildRoot 'production-output'
$faultOutputRoot = Join-Path $buildRoot 'fault-output'
$faultProbeRoot = Join-Path $buildRoot 'fault-probe'
$faultProbePath = Join-Path $faultProbeRoot 'Task9FaultProbe.bin'
$faultPayloadManifestPath = Join-Path $faultProbeRoot 'AmmarTrading.Sync.fault-payload-manifest.txt'
$productionPayloadHashesPath = Join-Path $faultProbeRoot 'AmmarTrading.Sync.payload-hashes.txt'
$faultPayloadHashesPath = Join-Path $faultProbeRoot 'AmmarTrading.Sync.fault-payload-hashes.txt'
$bootstrapperStagingPath = Join-Path $buildRoot 'MicrosoftEdgeWebView2Setup.exe'
$installerPath = Join-Path $artifactRoot 'AmmarTrading Sync Setup.exe'
$manifestPath = Join-Path $artifactRoot 'SHA256SUMS.txt'
$faultInstallerPath = Join-Path $artifactRoot '.acceptance\AmmarTrading Sync Upgrade Fault Test.exe'
$faultProbeHashPath = Join-Path $artifactRoot '.acceptance\AmmarTrading Sync Upgrade Fault Probe.sha256'
$stagedInstallerPath = Join-Path $productionOutputRoot 'AmmarTrading Sync Setup.exe'
$stagedManifestPath = Join-Path $buildRoot 'SHA256SUMS.txt'
$stagedFaultInstallerPath = Join-Path $faultOutputRoot 'AmmarTrading Sync Upgrade Fault Test.exe'
$stagedFaultProbeHashPath = Join-Path $buildRoot 'AmmarTrading Sync Upgrade Fault Probe.sha256'
$releasePromoted = $false

try {
Remove-CanonicalReleaseArtifacts -InstallerPath $installerPath -ManifestPath $manifestPath -FaultPath $faultInstallerPath -FaultProbeHashPath $faultProbeHashPath
Assert-CanonicalReleaseArtifactsAbsent -InstallerPath $installerPath -ManifestPath $manifestPath -FaultPath $faultInstallerPath -FaultProbeHashPath $faultProbeHashPath
if($Task9TestLifecycleFault -ceq 'Preflight') { throw 'Task 9 injected preflight failure.' }
$iscc = Resolve-InnoCompiler -RequestedPath $InnoCompilerPath
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
New-Item -ItemType Directory -Path $productionOutputRoot,$faultOutputRoot,$faultProbeRoot -Force | Out-Null
Invoke-NativeCommand -FilePath 'npm.cmd' -ArgumentList @('ci','--ignore-scripts') -WorkingDirectory $prototypeRoot
$priorQaBrowser = $env:QA_BROWSER
try {
    if([string]::IsNullOrWhiteSpace($env:QA_BROWSER)) {
        $browserCandidates = @(
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
        )
        $env:QA_BROWSER = @($browserCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
        if([string]::IsNullOrWhiteSpace($env:QA_BROWSER)) {
            throw 'A Chromium-compatible browser is required to run the UI release tests.'
        }
    }
    Invoke-NativeCommand -FilePath 'npm.cmd' -ArgumentList @('test') -WorkingDirectory $prototypeRoot
} finally {
    $env:QA_BROWSER = $priorQaBrowser
}
Invoke-NativeCommand -FilePath 'npm.cmd' -ArgumentList @('run','package:windows') -WorkingDirectory $prototypeRoot
Invoke-NativeCommand -FilePath 'dotnet.exe' -ArgumentList @('test',$solutionPath,'--configuration',$Configuration,'--nologo') -WorkingDirectory $repoRoot
Invoke-NativeCommand -FilePath 'dotnet.exe' -ArgumentList @(
    'publish',$appProject,
    '--configuration',$Configuration,
    '--runtime','win-x64',
    '--self-contained','true',
    '--output',$publishRoot,
    '--nologo',
    '-p:ContinuousIntegrationBuild=true',
    '-p:DebugSymbols=false',
    '-p:DebugType=None',
    '-p:SatelliteResourceLanguages=en'
) -WorkingDirectory $repoRoot

$allowedScripts = @(
    'Install-BasketsSyncTask.ps1',
    'Invoke-AmmarTradingDesktopOperation.ps1',
    'MoneyMachineCsvSchemaV3.psm1',
    'MoneyMachineSyncSetup.psm1',
    'Sync-BasketsToOneDrive.ps1',
    'Test-MoneyMachineSyncStatus.ps1'
)
$publishedScripts = Join-Path $publishRoot 'Scripts'
if(Test-Path -LiteralPath $publishedScripts) {
    Remove-Item -LiteralPath $publishedScripts -Recurse -Force
}
New-Item -ItemType Directory -Path $publishedScripts -Force | Out-Null
foreach($scriptName in $allowedScripts) {
    Copy-Item -LiteralPath (Join-Path $automationRoot $scriptName) -Destination (Join-Path $publishedScripts $scriptName)
}
$createdumpPath = Join-Path $publishRoot 'createdump.exe'
if(Test-Path -LiteralPath $createdumpPath -PathType Leaf) { Remove-Item -LiteralPath $createdumpPath -Force }
$payloadManifestName = 'AmmarTrading.Sync.payload-manifest.txt'
$payloadManifestPath = Join-Path $publishRoot $payloadManifestName
$publishPrefixLength = $publishRoot.TrimEnd('\').Length + 1
$payloadRelativePaths = @(
    Get-ChildItem -LiteralPath $publishRoot -File -Recurse -Force |
        Where-Object { $_.FullName -ine $payloadManifestPath } |
        ForEach-Object { $_.FullName.Substring($publishPrefixLength).Replace('/','\') }
)
$payloadRelativePaths += $payloadManifestName
$payloadRelativePaths = @($payloadRelativePaths | Sort-Object -Unique)
foreach($relativePath in $payloadRelativePaths) {
    if([string]::IsNullOrWhiteSpace($relativePath) -or
       [IO.Path]::IsPathRooted($relativePath) -or
       $relativePath -match '(^|\\)\.\.?($|\\)' -or
       $relativePath.Contains(':') -or
       $relativePath.Contains('/')) {
        throw "Unsafe release payload manifest path: $relativePath"
    }
}
[IO.File]::WriteAllLines($payloadManifestPath,$payloadRelativePaths,(New-Object Text.UTF8Encoding($false)))
Assert-ReleasePayload -PublishDirectory $publishRoot

[IO.File]::WriteAllText($faultProbePath,'Task9 fault payload - never distribute',(New-Object Text.UTF8Encoding($false)))
$faultPayloadRelativePaths = @($payloadRelativePaths + 'Assets\Web\Task9IncomingOnly.bin' | Sort-Object -Unique)
[IO.File]::WriteAllLines($faultPayloadManifestPath,$faultPayloadRelativePaths,(New-Object Text.UTF8Encoding($false)))
$faultProbeHash = (Get-FileHash -LiteralPath $faultProbePath -Algorithm SHA256).Hash.ToLowerInvariant()
$faultProbeSize = (Get-Item -LiteralPath $faultProbePath).Length
$productionPayloadHashLines = foreach($relativePath in $payloadRelativePaths) {
    $file = Get-Item -LiteralPath (Join-Path $publishRoot $relativePath)
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$relativePath|$($file.Length)|$hash"
}
[IO.File]::WriteAllLines($productionPayloadHashesPath,$productionPayloadHashLines,(New-Object Text.UTF8Encoding($false)))
$faultProbeTargets = @('AmmarTrading.Sync.exe','AmmarTrading.Sync.Core.dll','Assets\Web\index.html','Scripts\Sync-BasketsToOneDrive.ps1','Assets\Web\Task9IncomingOnly.bin')
$faultPayloadHashLines = foreach($relativePath in $faultPayloadRelativePaths) {
    if($relativePath -in $faultProbeTargets) {
        "$relativePath|$faultProbeSize|$faultProbeHash"
    } elseif($relativePath -ceq $payloadManifestName) {
        $file = Get-Item -LiteralPath $faultPayloadManifestPath
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relativePath|$($file.Length)|$hash"
    } else {
        $file = Get-Item -LiteralPath (Join-Path $publishRoot $relativePath)
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relativePath|$($file.Length)|$hash"
    }
}
[IO.File]::WriteAllLines($faultPayloadHashesPath,$faultPayloadHashLines,(New-Object Text.UTF8Encoding($false)))
$productionExeHash = (Get-FileHash -LiteralPath (Join-Path $publishRoot 'AmmarTrading.Sync.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
if($faultProbeHash -ceq $productionExeHash) { throw 'The acceptance fault probe must differ from the production executable.' }
[IO.File]::WriteAllText($stagedFaultProbeHashPath,"$faultProbeHash`r`n",(New-Object Text.UTF8Encoding($false)))

if([string]::IsNullOrWhiteSpace($WebView2BootstrapperPath)) {
    $downloadPath = Join-Path $buildRoot 'MicrosoftEdgeWebView2Setup.download'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $downloadPath
    Assert-MicrosoftBootstrapper -Path $downloadPath
    Move-Item -LiteralPath $downloadPath -Destination $bootstrapperStagingPath
} else {
    $providedBootstrapper = [System.IO.Path]::GetFullPath($WebView2BootstrapperPath)
    Assert-MicrosoftBootstrapper -Path $providedBootstrapper
    Copy-Item -LiteralPath $providedBootstrapper -Destination $bootstrapperStagingPath
}
Assert-MicrosoftBootstrapper -Path $bootstrapperStagingPath

Invoke-NativeCommand -FilePath $iscc -ArgumentList @(
    "/DPublishDir=$publishRoot",
    "/DBootstrapperPath=$bootstrapperStagingPath",
    "/DPayloadHashesPath=$productionPayloadHashesPath",
    "/DOutputDir=$productionOutputRoot",
    $installerScript
) -WorkingDirectory $repoRoot
Invoke-NativeCommand -FilePath $iscc -ArgumentList @(
    '/DAcceptanceFaultInjection=1',
    '/DFaultProductVersion=9.9.9',
    "/DFaultProbePath=$faultProbePath",
    "/DFaultManifestPath=$faultPayloadManifestPath",
    "/DPayloadHashesPath=$faultPayloadHashesPath",
    "/DPublishDir=$publishRoot",
    "/DBootstrapperPath=$bootstrapperStagingPath",
    "/DOutputDir=$faultOutputRoot",
    $installerScript
) -WorkingDirectory $repoRoot

if(-not (Test-Path -LiteralPath $stagedInstallerPath -PathType Leaf)) {
    throw "Installer was not produced: $stagedInstallerPath"
}
if(-not (Test-Path -LiteralPath $stagedFaultInstallerPath -PathType Leaf)) {
    throw "Fault-injection installer was not produced: $stagedFaultInstallerPath"
}
$installerHash = (Get-FileHash -LiteralPath $stagedInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $stagedManifestPath,
    "$installerHash *AmmarTrading Sync Setup.exe`r`n",
    (New-Object System.Text.UTF8Encoding($false)))
if((Get-Content -LiteralPath $stagedManifestPath -Raw).Trim() -cne "$installerHash *AmmarTrading Sync Setup.exe") {
    throw 'The staged SHA-256 manifest failed validation.'
}
Publish-ReleaseArtifacts -StagedInstaller $stagedInstallerPath -StagedManifest $stagedManifestPath -StagedFaultInstaller $stagedFaultInstallerPath -StagedFaultProbeHash $stagedFaultProbeHashPath -InstallerPath $installerPath -ManifestPath $manifestPath -FaultPath $faultInstallerPath -FaultProbeHashPath $faultProbeHashPath
$releasePromoted = $true

Write-Host "Installer: $installerPath"
Write-Host "SHA-256: $installerHash"
} catch {
    Remove-CanonicalReleaseArtifacts -InstallerPath $installerPath -ManifestPath $manifestPath -FaultPath $faultInstallerPath -FaultProbeHashPath $faultProbeHashPath
    Assert-CanonicalReleaseArtifactsAbsent -InstallerPath $installerPath -ManifestPath $manifestPath -FaultPath $faultInstallerPath -FaultProbeHashPath $faultProbeHashPath
    throw
} finally {
    try {
        if(Test-Path -LiteralPath $buildRoot -PathType Container) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
        if($releasePromoted -and $Task9TestLifecycleFault -ceq 'PostPromotionCleanup') {
            throw 'Task 9 injected post-promotion cleanup failure.'
        }
    } catch {
        Remove-CanonicalReleaseArtifacts -InstallerPath $installerPath -ManifestPath $manifestPath -FaultPath $faultInstallerPath -FaultProbeHashPath $faultProbeHashPath
        Assert-CanonicalReleaseArtifactsAbsent -InstallerPath $installerPath -ManifestPath $manifestPath -FaultPath $faultInstallerPath -FaultProbeHashPath $faultProbeHashPath
        throw
    }
}
