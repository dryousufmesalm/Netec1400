<#
.SYNOPSIS
Creates or reuses the self-signed identity, builds a signed installer, and zips the client package.

.DESCRIPTION
This is the operator path on a Windows build machine. The zip never contains the private .pfx.
The client unzip, trusts the .cer once, then runs setup without an unknown-publisher warning
on that machine.

.EXAMPLE
.\windows\scripts\Publish-SignedRelease.ps1 -CreateCertificateIfMissing
#>
[CmdletBinding()]
param(
    [string]$CodeSigningDirectory = (Join-Path $env:LOCALAPPDATA 'AmmarTrading\CodeSigning'),
    [string]$CodeSigningPfxPath = $env:AMMARTRADING_CODESIGN_PFX,
    [string]$CodeSigningPfxPassword = $env:AMMARTRADING_CODESIGN_PFX_PASSWORD,
    [switch]$CreateCertificateIfMissing,
    [switch]$ForceNewCertificate,
    [string]$WebView2BootstrapperPath,
    [string]$InnoCompilerPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$ProgressPreference = 'SilentlyContinue'

if($env:OS -cne 'Windows_NT') {
    throw 'Publish-SignedRelease.ps1 must run on Windows. This Linux workspace cannot create Authenticode signatures.'
}

Import-Module (Join-Path $PSScriptRoot 'AmmarTradingCodeSigning.psm1') -Force

function ConvertTo-PlainText {
    param([Parameter(Mandatory)][System.Security.SecureString]$Secret)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Assert-NoPrivateKeyInPackage {
    param([Parameter(Mandatory)][string]$Directory)
    $forbidden = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force |
        Where-Object { $_.Extension.ToLowerInvariant() -in @('.pfx','.p12','.key') })
    if($forbidden.Count -gt 0) {
        throw "Client package contains private signing material: $($forbidden.FullName -join ', ')"
    }
}

function New-ClientDeliveryPackage {
    param(
        [Parameter(Mandatory)][string]$ArtifactRoot,
        [Parameter(Mandatory)][string]$ReadmeSource,
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][string]$ZipPath
    )

    $requiredNames = @(
        'AmmarTrading Sync Setup.exe',
        'SHA256SUMS.txt',
        'AmmarTrading-CodeSigning.cer',
        'AmmarTrading-CodeSigning.thumbprint.txt',
        'Install-AmmarTradingCertificate.cmd'
    )
    foreach($name in $requiredNames) {
        $path = Join-Path $ArtifactRoot $name
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Signed release is incomplete; missing $name. The build ran without a signing identity."
        }
    }
    if(-not (Test-Path -LiteralPath $ReadmeSource -PathType Leaf)) {
        throw "Client Arabic readme is missing: $ReadmeSource"
    }

    if(Test-Path -LiteralPath $StagingRoot) { Remove-Item -LiteralPath $StagingRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
    foreach($name in $requiredNames) {
        Copy-Item -LiteralPath (Join-Path $ArtifactRoot $name) -Destination (Join-Path $StagingRoot $name)
    }
    Copy-Item -LiteralPath $ReadmeSource -Destination (Join-Path $StagingRoot 'README-AR.txt')
    Assert-NoPrivateKeyInPackage -Directory $StagingRoot

    $zipDirectory = Split-Path -Parent $ZipPath
    New-Item -ItemType Directory -Path $zipDirectory -Force | Out-Null
    if(Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    Compress-Archive -Path (Join-Path $StagingRoot '*') -DestinationPath $ZipPath -CompressionLevel Optimal
    Assert-NoPrivateKeyInPackage -Directory $StagingRoot
    return $ZipPath
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$buildScript = Join-Path $PSScriptRoot 'Build-AmmarTradingSync.ps1'
$certificateScript = Join-Path $PSScriptRoot 'New-AmmarTradingCodeSigningCertificate.ps1'
$readmeSource = Join-Path $repoRoot 'windows\installer\README-SIGNED-AR.txt'
$artifactRoot = Join-Path $repoRoot 'artifacts\windows'
$packageStaging = Join-Path $artifactRoot '.client-package'
$zipPath = Join-Path $artifactRoot 'AmmarTrading-Sync-Signed-Client.zip'

if([string]::IsNullOrWhiteSpace($CodeSigningPfxPath)) {
    $CodeSigningPfxPath = Join-Path $CodeSigningDirectory 'AmmarTrading-CodeSigning.pfx'
}

$pfxExists = Test-Path -LiteralPath $CodeSigningPfxPath -PathType Leaf
if(-not $pfxExists -and -not $CreateCertificateIfMissing -and -not $ForceNewCertificate) {
    throw "No signing .pfx at $CodeSigningPfxPath. Re-run with -CreateCertificateIfMissing, or set AMMARTRADING_CODESIGN_PFX."
}

$password = $null
if(-not [string]::IsNullOrWhiteSpace($CodeSigningPfxPassword)) {
    $password = ConvertTo-SecureString -String $CodeSigningPfxPassword -AsPlainText -Force
} else {
    $password = Read-Host -AsSecureString -Prompt 'Password for AmmarTrading-CodeSigning.pfx'
}

if($ForceNewCertificate -or (-not $pfxExists -and $CreateCertificateIfMissing)) {
    & $certificateScript -OutputDirectory $CodeSigningDirectory -Password $password -TrustOnThisMachine -Force:$ForceNewCertificate
    $CodeSigningPfxPath = Join-Path $CodeSigningDirectory 'AmmarTrading-CodeSigning.pfx'
}

$plainPassword = ConvertTo-PlainText -Secret $password
try {
    $env:AMMARTRADING_CODESIGN_PFX = $CodeSigningPfxPath
    $env:AMMARTRADING_CODESIGN_PFX_PASSWORD = $plainPassword
    $buildArguments = @{
        CodeSigningPfxPath = $CodeSigningPfxPath
        CodeSigningPfxPassword = $plainPassword
    }
    if(-not [string]::IsNullOrWhiteSpace($WebView2BootstrapperPath)) {
        $buildArguments['WebView2BootstrapperPath'] = $WebView2BootstrapperPath
    }
    if(-not [string]::IsNullOrWhiteSpace($InnoCompilerPath)) {
        $buildArguments['InnoCompilerPath'] = $InnoCompilerPath
    }
    & $buildScript @buildArguments
} finally {
    $env:AMMARTRADING_CODESIGN_PFX_PASSWORD = $null
    $plainPassword = $null
}

New-ClientDeliveryPackage -ArtifactRoot $artifactRoot -ReadmeSource $readmeSource -StagingRoot $packageStaging -ZipPath $zipPath | Out-Null
$thumbprint = (Get-Content -LiteralPath (Join-Path $artifactRoot 'AmmarTrading-CodeSigning.thumbprint.txt') -Raw).Trim()

Write-Host ''
Write-Host "Client zip:  $zipPath"
Write-Host "Thumbprint:  $thumbprint"
Write-Host 'Send the zip to the client. Send the thumbprint on a separate WhatsApp/call.'
Write-Host 'Client: unzip -> Install-AmmarTradingCertificate.cmd -> YES -> AmmarTrading Sync Setup.exe'
Write-Host 'Never send AmmarTrading-CodeSigning.pfx.'
