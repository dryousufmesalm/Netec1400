Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AmmarTradingSignableExtensions = @('.exe','.dll','.ps1','.psm1','.ps1xml')
$script:AmmarTradingDefaultTimestampUrl = 'http://timestamp.digicert.com'

function Get-AmmarTradingSignableExtension {
    return @($script:AmmarTradingSignableExtensions)
}

function Get-AmmarTradingDefaultTimestampUrl {
    return $script:AmmarTradingDefaultTimestampUrl
}

function Get-AmmarTradingSignablePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    if(-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "The signing root does not exist: $Root"
    }
    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            Where-Object { $_.Extension.ToLowerInvariant() -in $script:AmmarTradingSignableExtensions } |
            ForEach-Object { $_.FullName } |
            Sort-Object -Unique
    )
}

function New-AmmarTradingCodeSigningCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][System.Security.SecureString]$Password,
        [string]$Subject = 'AmmarTrading',
        [ValidateRange(1,10)][int]$ValidYears = 5,
        [switch]$TrustOnThisMachine,
        [switch]$Force
    )

    if($null -eq (Get-Command -Name 'New-SelfSignedCertificate' -ErrorAction SilentlyContinue)) {
        throw 'New-SelfSignedCertificate is unavailable. Run this on Windows 10/11 or Windows Server 2016+.'
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $pfxPath = Join-Path $resolvedOutput 'AmmarTrading-CodeSigning.pfx'
    $cerPath = Join-Path $resolvedOutput 'AmmarTrading-CodeSigning.cer'
    $thumbprintPath = Join-Path $resolvedOutput 'AmmarTrading-CodeSigning.thumbprint.txt'
    foreach($path in @($pfxPath,$cerPath,$thumbprintPath)) {
        if((Test-Path -LiteralPath $path) -and -not $Force) {
            throw "Refusing to overwrite existing signing material: $path. Pass -Force only if the old key is retired."
        }
    }

    # A self-signed leaf is its own chain root, so the client trusts this one certificate in both
    # the Trusted Root and Trusted Publishers stores. Replacing it invalidates every prior release.
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=$Subject, O=$Subject" `
        -FriendlyName "$Subject Code Signing" `
        -KeyAlgorithm 'RSA' `
        -KeyLength 3072 `
        -HashAlgorithm 'SHA256' `
        -KeyExportPolicy 'Exportable' `
        -KeyUsage 'DigitalSignature' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3','2.5.29.19={text}') `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears($ValidYears)

    $storePath = "Cert:\CurrentUser\My\$($certificate.Thumbprint)"
    try {
        Export-PfxCertificate -Cert $storePath -FilePath $pfxPath -Password $Password -Force | Out-Null
        Export-Certificate -Cert $storePath -FilePath $cerPath -Type CERT -Force | Out-Null
        [IO.File]::WriteAllText($thumbprintPath,"$($certificate.Thumbprint)`r`n",(New-Object Text.UTF8Encoding($false)))

        if($TrustOnThisMachine) {
            Import-AmmarTradingCodeSigningTrust -CertificatePath $cerPath
        }
    } finally {
        # The signing identity lives in the exported .pfx, never in an ambient personal store.
        Remove-Item -LiteralPath $storePath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Subject    = $certificate.Subject
        Thumbprint = $certificate.Thumbprint
        NotAfter   = $certificate.NotAfter
        PfxPath    = $pfxPath
        CerPath    = $cerPath
        ThumbprintPath = $thumbprintPath
    }
}

function Import-AmmarTradingCodeSigningTrust {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CertificatePath)

    if(-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        throw "The public certificate does not exist: $CertificatePath"
    }
    $publicOnly = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (Resolve-Path -LiteralPath $CertificatePath).Path
    try {
        if($publicOnly.HasPrivateKey) {
            throw "Refusing to distribute trust material that carries a private key: $CertificatePath"
        }
    } finally {
        $publicOnly.Dispose()
    }

    foreach($storeName in @('Root','TrustedPublisher')) {
        Import-Certificate -FilePath $CertificatePath -CertStoreLocation "Cert:\LocalMachine\$storeName" | Out-Null
    }
}

function Import-AmmarTradingSigningIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PfxPath,
        [Parameter(Mandatory)][System.Security.SecureString]$Password
    )

    if(-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) {
        throw "The code signing .pfx does not exist: $PfxPath"
    }
    $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(
        (Resolve-Path -LiteralPath $PfxPath).Path,
        $Password
    )
    if(-not $certificate.HasPrivateKey) {
        $certificate.Dispose()
        throw "The code signing .pfx does not contain a private key: $PfxPath"
    }
    if($certificate.NotAfter -lt (Get-Date)) {
        $expiry = $certificate.NotAfter
        $thumbprint = $certificate.Thumbprint
        $certificate.Dispose()
        throw "The code signing certificate expired on ${expiry}: $thumbprint"
    }
    return $certificate
}

function Set-AmmarTradingCodeSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$TimestampUrl = $script:AmmarTradingDefaultTimestampUrl,
        [ValidateRange(1,10)][int]$TimestampAttempt = 4
    )

    foreach($target in $Path) {
        if(-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Cannot sign a file that does not exist: $target"
        }
        $extension = [IO.Path]::GetExtension($target).ToLowerInvariant()
        if($extension -notin $script:AmmarTradingSignableExtensions) {
            throw "Refusing to sign an unsupported file type: $target"
        }

        # Timestamping is what keeps already-shipped releases verifiable after the certificate expires,
        # so a transient timestamp-server failure must fail the build rather than produce a weaker signature.
        $signature = $null
        for($attempt = 1; $attempt -le $TimestampAttempt; $attempt++) {
            try {
                $signature = Set-AuthenticodeSignature `
                    -LiteralPath $target `
                    -Certificate $Certificate `
                    -HashAlgorithm 'SHA256' `
                    -IncludeChain 'All' `
                    -TimestampServer $TimestampUrl `
                    -Force `
                    -ErrorAction Stop
                break
            } catch {
                if($attempt -eq $TimestampAttempt) { throw }
                Start-Sleep -Seconds ([Math]::Pow(2,$attempt))
            }
        }
        if($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
            throw "Signing produced an unusable signature for ${target}: $($signature.Status) - $($signature.StatusMessage)"
        }
    }
}

function Assert-AmmarTradingCodeSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        [Parameter(Mandatory)][string]$ExpectedThumbprint
    )

    $normalizedThumbprint = $ExpectedThumbprint.Replace(' ','').ToUpperInvariant()
    foreach($target in $Path) {
        $signature = Get-AuthenticodeSignature -LiteralPath $target
        if($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
            throw "Release payload is not validly signed: $target ($($signature.Status) - $($signature.StatusMessage)). Install the signing certificate on this build machine with New-AmmarTradingCodeSigningCertificate.ps1 -TrustOnThisMachine."
        }
        if($null -eq $signature.SignerCertificate -or
           $signature.SignerCertificate.Thumbprint.ToUpperInvariant() -cne $normalizedThumbprint) {
            throw "Release payload was signed by an unexpected certificate: $target"
        }
        if($null -eq $signature.TimeStamperCertificate) {
            throw "Release payload is signed without a trusted timestamp and will stop verifying when the certificate expires: $target"
        }
    }
}

Export-ModuleMember -Function @(
    'Assert-AmmarTradingCodeSignature',
    'Get-AmmarTradingDefaultTimestampUrl',
    'Get-AmmarTradingSignableExtension',
    'Get-AmmarTradingSignablePath',
    'Import-AmmarTradingCodeSigningTrust',
    'Import-AmmarTradingSigningIdentity',
    'New-AmmarTradingCodeSigningCertificate',
    'Set-AmmarTradingCodeSignature'
)
