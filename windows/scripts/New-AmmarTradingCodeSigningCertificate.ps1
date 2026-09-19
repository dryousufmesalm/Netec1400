<#
.SYNOPSIS
Creates the self-signed AmmarTrading code signing identity used by Build-AmmarTradingSync.ps1.

.DESCRIPTION
Produces AmmarTrading-CodeSigning.pfx (private, never distributed) and
AmmarTrading-CodeSigning.cer (public, shipped beside the installer so the target machine can
trust it). A self-signed certificate is free but is only trusted where its .cer has been
imported, so this is for machines under our control or the client's VPS - it does not satisfy
SmartScreen for public download.

.EXAMPLE
.\New-AmmarTradingCodeSigningCertificate.ps1 -TrustOnThisMachine
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'AmmarTrading\CodeSigning'),
    [string]$Subject = 'AmmarTrading',
    [ValidateRange(1,10)][int]$ValidYears = 5,
    [System.Security.SecureString]$Password,
    [switch]$TrustOnThisMachine,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'AmmarTradingCodeSigning.psm1') -Force

if($null -eq $Password) {
    $Password = Read-Host -AsSecureString -Prompt 'Password to protect AmmarTrading-CodeSigning.pfx'
}
if($Password.Length -lt 12) {
    throw 'The .pfx password must be at least 12 characters; it is the only thing protecting the signing key.'
}

$identity = New-AmmarTradingCodeSigningCertificate `
    -OutputDirectory $OutputDirectory `
    -Password $Password `
    -Subject $Subject `
    -ValidYears $ValidYears `
    -TrustOnThisMachine:$TrustOnThisMachine `
    -Force:$Force

Write-Host "Subject:    $($identity.Subject)"
Write-Host "Thumbprint: $($identity.Thumbprint)"
Write-Host "Expires:    $($identity.NotAfter)"
Write-Host "Private:    $($identity.PfxPath)"
Write-Host "Public:     $($identity.CerPath)"
Write-Host ''
Write-Host 'Next: point the build at this identity, then rebuild.'
Write-Host "  `$env:AMMARTRADING_CODESIGN_PFX = '$($identity.PfxPath)'"
Write-Host '  $env:AMMARTRADING_CODESIGN_PFX_PASSWORD = ''<the password you just entered>'''
