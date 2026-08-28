@echo off
setlocal
title AmmarTrading Sync Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MoneyMachineSyncWizard.ps1"
if errorlevel 1 (
  echo.
  echo AmmarTrading Sync setup could not start. Please keep this window open and contact support.
  pause
)
endlocal
