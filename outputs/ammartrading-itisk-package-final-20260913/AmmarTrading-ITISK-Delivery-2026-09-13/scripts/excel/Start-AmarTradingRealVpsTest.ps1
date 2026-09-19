$ErrorActionPreference='Stop'
$name='Codex-AmarTrading-RealVps-20260904'
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'Real VPS test task already exists. Inspect it before rerunning.'}
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -File C:\CodexWorker\amartrading-real-vps-20260904\test-real.ps1'
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $name
