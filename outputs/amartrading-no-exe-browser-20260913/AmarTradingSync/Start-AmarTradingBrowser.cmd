@echo off
setlocal
title AmarTrading Sync Browser Setup
powershell.exe -NoProfile -File "%~dp0Start-MoneyMachineSyncWizard.ps1"
if errorlevel 1 (
  echo.
  echo AmarTrading Sync could not start. Please keep this window open and contact support.
  pause
)
endlocal
