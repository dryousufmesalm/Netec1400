@echo off
setlocal
title AmarTrading Sync Browser Setup
set "AMARTRADING_SCRIPT=%~dp0Start-MoneyMachineSyncWizard.ps1"
set "AMARTRADING_LOG_DIR=%LOCALAPPDATA%\AmarTradingSync\Logs"
set "AMARTRADING_LOG_FILE=%AMARTRADING_LOG_DIR%\latest-start.log"

if not exist "%AMARTRADING_SCRIPT%" (
  echo AmarTrading Sync is incomplete: Start-MoneyMachineSyncWizard.ps1 was not found.
  pause
  exit /b 2
)

if not exist "%AMARTRADING_LOG_DIR%" mkdir "%AMARTRADING_LOG_DIR%" >nul 2>&1

powershell.exe -NoProfile -Command "$signature = Get-AuthenticodeSignature -LiteralPath $env:AMARTRADING_SCRIPT; if ($signature.Status -ne 'Valid') { exit 25 }"
if errorlevel 1 (
  echo.
  echo AmarTrading Sync needs its test publisher certificate before the signed scripts can run.
  echo Run Install-AmarTradingTestCertificate.cmd once from this folder, then start AmarTrading again.
  echo No Windows security setting has been changed.
  pause
  exit /b 25
)

powershell.exe -NoProfile -File "%AMARTRADING_SCRIPT%" > "%AMARTRADING_LOG_FILE%" 2>&1
if errorlevel 1 (
  echo.
  echo AmarTrading Sync could not start. The error was saved here:
  echo %AMARTRADING_LOG_FILE%
  type "%AMARTRADING_LOG_FILE%"
  pause
)
endlocal
