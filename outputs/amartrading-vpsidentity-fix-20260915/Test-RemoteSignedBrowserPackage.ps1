Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = 'D:\CodexWorker\ammartrading-vpsid-remotesigned-test-20260915\package\AmarTradingSync'
$rootThumb = '38B79244D76FD3CA939BFC7A8DCE298B3EB46954'
$publisherThumb = '78CD4F582A134F1AFAC7C1E63EC5EFA7567A9F3B'
$hadRoot = Test-Path -LiteralPath ("Cert:\LocalMachine\Root\$rootThumb")
$hadPublisher = Test-Path -LiteralPath ("Cert:\LocalMachine\TrustedPublisher\$publisherThumb")
$process = $null

try {
    if(-not $hadRoot) {
        Import-Certificate -FilePath (Join-Path $root 'AmarTrading-Test-Root.cer') -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
    }
    if(-not $hadPublisher) {
        Import-Certificate -FilePath (Join-Path $root 'AmarTrading-Test-Publisher.cer') -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
    }

    $module = Join-Path $root 'MoneyMachineSyncSetup.psm1'
    $signature = Get-AuthenticodeSignature -FilePath $module
    if($signature.Status -ne 'Valid') { throw "Module signature is $($signature.Status)." }

    Set-Content -LiteralPath "$module`:Zone.Identifier" -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ascii
    $script = Join-Path $root 'Start-MoneyMachineSyncWizard.ps1'
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','RemoteSigned','-File',$script,
        '-NoBrowser','-Port','8879','-SkipTaskRegistration'
    ) -PassThru -WindowStyle Hidden

    $ready = $false
    for($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8879/' -TimeoutSec 1
            if($response.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
    }
    if(-not $ready) { throw 'RemoteSigned browser host did not return HTTP 200.' }
    Write-Output "REMOTE_SIGNED_BROWSER_SMOKE_PASS HTTP=$($response.StatusCode) SIGNER=$($signature.SignerCertificate.Thumbprint)"
}
finally {
    if($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if(-not $hadPublisher) { Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$publisherThumb" -Force -ErrorAction SilentlyContinue }
    if(-not $hadRoot) { Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$rootThumb" -Force -ErrorAction SilentlyContinue }
}
