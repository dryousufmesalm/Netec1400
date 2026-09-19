@echo off
setlocal
title AmarTrading Sync Test Certificate Setup
set "AMARTRADING_CERT=%~dp0AmarTrading-Test-Publisher.cer"

if not exist "%AMARTRADING_CERT%" (
  echo AmarTrading-Test-Publisher.cer was not found. Extract the complete package and try again.
  pause
  exit /b 2
)

echo This installs the AmarTrading Test Publisher certificate for the current Windows user only.
echo It allows this test package's signed PowerShell scripts to run under RemoteSigned.
echo It does not disable Smart App Control, Defender, AppLocker, or PowerShell execution policy.
echo.
choice /M "Install the test certificate"
if errorlevel 2 exit /b 0

certutil.exe -user -addstore Root "%AMARTRADING_CERT%"
if errorlevel 1 (
  echo Could not add the test certificate to the current user's Trusted Root store.
  pause
  exit /b 1
)

certutil.exe -user -addstore TrustedPublisher "%AMARTRADING_CERT%"
if errorlevel 1 (
  echo Could not add the test certificate to the current user's Trusted Publishers store.
  pause
  exit /b 1
)

echo.
echo Test certificate installed. You can now run Start-AmarTradingBrowser.cmd.
pause
endlocal
