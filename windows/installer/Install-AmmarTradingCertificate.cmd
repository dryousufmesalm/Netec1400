@echo off
setlocal
title AmmarTrading Sync - Trust the publisher certificate

set "AMMAR_CERT=%~dp0AmmarTrading-CodeSigning.cer"
set "AMMAR_THUMBPRINT_FILE=%~dp0AmmarTrading-CodeSigning.thumbprint.txt"

if not exist "%AMMAR_CERT%" goto :missing
if not exist "%AMMAR_THUMBPRINT_FILE%" goto :missing

net session >nul 2>&1
if errorlevel 1 (
  echo Administrator approval is required to trust a publisher certificate.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList '%AMMAR_CERT%';" ^
  "$expected=((Get-Content -LiteralPath '%AMMAR_THUMBPRINT_FILE%' -Raw).Trim()).ToUpperInvariant();" ^
  "if($cert.HasPrivateKey){throw 'This certificate file carries a private key and must not be trusted.'};" ^
  "if($cert.Thumbprint.ToUpperInvariant() -cne $expected){throw 'The certificate does not match the published thumbprint. Re-download the package.'};" ^
  "Write-Host ('Publisher: ' + $cert.Subject);" ^
  "Write-Host ('Thumbprint: ' + $cert.Thumbprint);" ^
  "Write-Host ('Expires: ' + $cert.NotAfter);" ^
  "Write-Host '';" ^
  "Write-Host 'Confirm this thumbprint matches the one AmmarTrading sent you separately.';" ^
  "Write-Host 'Trusting it means this machine will accept anything signed by that key.';" ^
  "Write-Host '';" ^
  "$answer=Read-Host 'Type YES to trust this publisher';" ^
  "if($answer -cne 'YES'){Write-Host 'Nothing was changed.'; exit 2};" ^
  "Import-Certificate -FilePath '%AMMAR_CERT%' -CertStoreLocation Cert:\LocalMachine\Root | Out-Null;" ^
  "Import-Certificate -FilePath '%AMMAR_CERT%' -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null;" ^
  "Write-Host 'Certificate trusted.'"

if errorlevel 1 (
  echo.
  echo The certificate was not installed.
  pause
  exit /b 1
)

echo.
echo You can now run "AmmarTrading Sync Setup.exe" without an unknown-publisher warning.
pause
exit /b 0

:missing
echo AmmarTrading-CodeSigning.cer and AmmarTrading-CodeSigning.thumbprint.txt must sit next to this file.
echo Extract the complete package and try again.
pause
exit /b 2
