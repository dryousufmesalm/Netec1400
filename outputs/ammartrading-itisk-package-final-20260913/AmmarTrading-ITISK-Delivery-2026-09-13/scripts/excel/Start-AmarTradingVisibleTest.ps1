$ErrorActionPreference = 'Stop'
$work = 'C:\CodexWorker\amartrading-excel-20260904'
$copy = Join-Path $work 'TEST_ONLY_AmarTrading_Excel.xlsx'
if(Test-Path -LiteralPath $copy) { throw 'Visible test copy already exists; inspect it before rerunning.' }
Copy-Item -LiteralPath (Join-Path $work 'AmarTrading_Excel_Master_2026-09-04.xlsx') -Destination $copy
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -File "{0}\Test-AmarTradingWorkbook.ps1" -WorkbookPath "{1}" -FixtureCsv "{0}\fixture.csv" -WorkDir "{0}\visible-test" -ShowExcel' -f $work,$copy)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$task = 'Codex-AmarTrading-Excel-VisibleTest-20260904'
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { throw 'Visible test task already exists.' }
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $task
