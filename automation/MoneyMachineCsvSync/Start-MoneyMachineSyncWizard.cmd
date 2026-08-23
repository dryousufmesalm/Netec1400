@echo off
setlocal
title Money Machine CSV Sync Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MoneyMachineSyncWizard.ps1"
if errorlevel 1 (
  echo.
  echo Money Machine setup could not start. Please keep this window open and contact support.
  pause
)
endlocal
