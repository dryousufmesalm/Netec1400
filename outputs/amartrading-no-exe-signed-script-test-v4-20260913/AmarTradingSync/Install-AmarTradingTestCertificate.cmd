@echo off
setlocal
title AmarTrading Sync Test Certificate Setup
set "AMARTRADING_ROOT_CERT=%~dp0AmarTrading-Test-Root.cer"
set "AMARTRADING_PUBLISHER_CERT=%~dp0AmarTrading-Test-Publisher.cer"

if not exist "%AMARTRADING_ROOT_CERT%" (
  echo AmarTrading-Test-Root.cer was not found. Extract the complete package and try again.
  pause
  exit /b 2
)

if not exist "%AMARTRADING_PUBLISHER_CERT%" (
  echo AmarTrading-Test-Publisher.cer was not found. Extract the complete package and try again.
  pause
  exit /b 2
)

echo This installs the AmarTrading test root and publisher certificates for this VPS only.
echo It allows this test package's signed PowerShell scripts to run under RemoteSigned.
echo It does not disable Smart App Control, Defender, AppLocker, or PowerShell execution policy.
echo.
choice /M "Install the test certificate"
if errorlevel 2 exit /b 0

net session >nul 2>&1
if errorlevel 1 (
  echo Administrator approval is required to install the test root certificate.
  powershell.exe -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b
)

certutil.exe -addstore Root "%AMARTRADING_ROOT_CERT%"
if errorlevel 1 (
  echo Could not add the test root certificate to the machine Trusted Root store.
  pause
  exit /b 1
)

certutil.exe -addstore TrustedPublisher "%AMARTRADING_PUBLISHER_CERT%"
if errorlevel 1 (
  echo Could not add the test publisher certificate to the machine Trusted Publishers store.
  pause
  exit /b 1
)

echo.
echo Test certificate installed. You can now run Start-AmarTradingBrowser.cmd.
pause
endlocal
