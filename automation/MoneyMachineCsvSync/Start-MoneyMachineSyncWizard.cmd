@echo off
setlocal
title AmarTrading Sync Setup
powershell.exe -NoProfile -File "%~dp0Start-MoneyMachineSyncWizard.ps1"
if errorlevel 1 (
  echo.
  echo AmarTrading Sync setup could not start. Please keep this window open and contact support.
  pause
)
endlocal
