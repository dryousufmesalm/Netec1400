[CmdletBinding()]
param(
    [ValidateSet('Debug','Release')]
    [string]$Configuration = 'Release',
    [string]$WebView2BootstrapperPath,
    [string]$InnoCompilerPath
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
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$prototypeRoot = Join-Path $repoRoot 'prototypes\money-machine-sync-wizard'
$solutionPath = Join-Path $repoRoot 'windows\AmmarTrading.Sync.sln'
$appProject = Join-Path $repoRoot 'windows\src\AmmarTrading.Sync.App\AmmarTrading.Sync.App.csproj'
$installerScript = Join-Path $repoRoot 'windows\installer\AmmarTradingSync.iss'
$automationRoot = Join-Path $repoRoot 'automation\MoneyMachineCsvSync'
$artifactRoot = Join-Path $repoRoot 'artifacts\windows'
$buildRoot = Join-Path $artifactRoot '.build'
$publishRoot = Join-Path $buildRoot 'publish'
$bootstrapperStagingPath = Join-Path $buildRoot 'MicrosoftEdgeWebView2Setup.exe'
$installerPath = Join-Path $artifactRoot 'AmmarTrading Sync Setup.exe'
$manifestPath = Join-Path $artifactRoot 'SHA256SUMS.txt'
$iscc = Resolve-InnoCompiler -RequestedPath $InnoCompilerPath

if(Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null

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
Assert-ReleasePayload -PublishDirectory $publishRoot

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

if(Test-Path -LiteralPath $installerPath) { Remove-Item -LiteralPath $installerPath -Force }
Invoke-NativeCommand -FilePath $iscc -ArgumentList @(
    "/DPublishDir=$publishRoot",
    "/DBootstrapperPath=$bootstrapperStagingPath",
    "/DOutputDir=$artifactRoot",
    $installerScript
) -WorkingDirectory $repoRoot

if(-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Installer was not produced: $installerPath"
}
$installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText(
    $manifestPath,
    "$installerHash *AmmarTrading Sync Setup.exe`r`n",
    (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Installer: $installerPath"
Write-Host "SHA-256: $installerHash"
