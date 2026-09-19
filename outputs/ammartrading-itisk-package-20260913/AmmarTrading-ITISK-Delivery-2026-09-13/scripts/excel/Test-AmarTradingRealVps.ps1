param([string]$WorkDir='C:\CodexWorker\amartrading-real-vps-20260904')
$ErrorActionPreference='Stop'
$report=[ordered]@{Passed=$false;Error=$null;Snapshots=@();Accounts=@()}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AmarRealWindow {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 public struct RECT {public int Left,Top,Right,Bottom;}
}
'@
Add-Type -AssemblyName System.Drawing
function Capture-Excel([string]$Name) {
 try {
  [void][AmarRealWindow]::SetForegroundWindow([IntPtr]$excel.Hwnd)
  Start-Sleep -Seconds 2
  $r=New-Object AmarRealWindow+RECT
  [void][AmarRealWindow]::GetWindowRect([IntPtr]$excel.Hwnd,[ref]$r)
  $b=New-Object Drawing.Bitmap ($r.Right-$r.Left),($r.Bottom-$r.Top)
  $g=[Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen($r.Left,$r.Top,0,0,$b.Size)
  $b.Save((Join-Path $WorkDir $Name))
  $g.Dispose();$b.Dispose()
  $report.Snapshots+=$Name
 } catch { $report.ScreenshotError=$_.Exception.Message }
}
try {
 $import=Get-Content -LiteralPath (Join-Path $WorkDir 'import-verification.json') -Raw | ConvertFrom-Json
 $manifest=Get-Content -LiteralPath (Join-Path $WorkDir 'vps-snapshot\snapshot-manifest.json') -Raw | ConvertFrom-Json
 $path=Join-Path $WorkDir 'AmarTrading_REAL_VPS.xlsx'
 try {$excel=[Runtime.InteropServices.Marshal]::GetActiveObject('Excel.Application')}catch{$excel=New-Object -ComObject Excel.Application}
 $excel.Visible=$true
 $excel.DisplayAlerts=$false
 $excel.AskToUpdateLinks=$false
 $book=$null
 for($i=1;$i -le $excel.Workbooks.Count;$i++) {if($excel.Workbooks.Item($i).FullName -eq $path){$book=$excel.Workbooks.Item($i);break}}
 if(-not $book){$book=$excel.Workbooks.Open($path,0,$false)}
 for($n=0;-not $book -and $n -lt 40;$n++) {
  Start-Sleep -Milliseconds 250
  for($i=1;$i -le $excel.Workbooks.Count;$i++) {if($excel.Workbooks.Item($i).FullName -eq $path){$book=$excel.Workbooks.Item($i);break}}
 }
 if(-not $book){throw 'Excel could not open the real VPS test workbook.'}
 $book.Activate()
 $excel.WindowState=-4143
 $excel.Left=0;$excel.Top=0;$excel.Width=1100;$excel.Height=750
 $excel.WindowState=-4137
 $book.Names.Item('OneDriveRoot').RefersToRange.Value2=$import.Root
 $book.Worksheets.Item('Power Query Setup').Activate()
 $excel.ActiveWindow.Zoom=85
 $excel.StatusBar='REAL VPS TEST: OneDrive root configured. Refresh All starts next.'
 Capture-Excel '01-root-setup.png'
 Start-Sleep -Seconds 3
 $baskets=$book.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
 $status=$book.Worksheets.Item('Sync Status').ListObjects.Item('SyncStatusTable')
 $baskets.QueryTable.BackgroundQuery=$false
 $status.QueryTable.BackgroundQuery=$false
 $book.Worksheets.Item('Basket Data').Activate()
 $excel.StatusBar='Refreshing REAL VPS CSV files from local OneDrive...'
 $book.RefreshAll()
 $excel.CalculateUntilAsyncQueriesDone()
 $report.ExcelVersion=$excel.Version
 $report.ExcelBuild=$excel.Build
 $report.SourceHost=$manifest.Host
 $report.SourceSnapshotUtc=$manifest.SnapshotUtc
 $report.Root=$import.Root
 $report.Workbook=$path
 $report.BasketRows=$baskets.ListRows.Count
 $report.StatusRows=$status.ListRows.Count
 if($baskets.ListRows.Count -ne ($manifest.Accounts|Measure-Object Rows -Sum).Sum){throw 'Refresh All row count differs from VPS snapshot.'}
 if($status.ListRows.Count -ne 4 -or $baskets.ListColumns.Count -ne 75){throw 'Unexpected status rows or basket schema.'}
 $values=$baskets.DataBodyRange.Value2
 $accountColumn=$baskets.ListColumns.Item('AccountNumber').Index
 $plColumn=$baskets.ListColumns.Item('ClosePL').Index
 foreach($expected in $manifest.Accounts) {
  $count=0;$sum=0.0
  for($row=1;$row -le $baskets.ListRows.Count;$row++) {
   if([string]$values[$row,$accountColumn] -eq $expected.Login){$count++;$sum += [double]$values[$row,$plColumn]}
  }
  if($count -ne $expected.Rows -or [math]::Abs($sum-$expected.ClosePLSum) -gt 0.005){throw "Excel data mismatch for $($expected.Login)"}
  $report.Accounts+=@{Login=$expected.Login;CsvRows=$expected.Rows;ExcelRows=$count;CsvClosePL=[math]::Round($expected.ClosePLSum,2);ExcelClosePL=[math]::Round($sum,2);Match=$true}
 }
 foreach($file in $import.Files){if((Get-FileHash -LiteralPath $file.Path).Hash -ne $file.SHA256){throw 'A snapshot file changed during Excel verification.'}}
 $report.FilesVerified=8
 Capture-Excel '02-real-baskets.png'
 $book.Worksheets.Item('Sync Status').Activate()
 Capture-Excel '03-real-sync-status.png'
 try{$summary=$book.Worksheets.Item('VPS Verification')}catch{$summary=$book.Worksheets.Add();$summary.Name='VPS Verification'}
 $summary.Cells.ClearContents()
 $summary.Range('A1').Value2='AmarTrading - REAL VPS verification'
 $summary.Range('A2').Value2='Source VPS: '+$manifest.Host
 $summary.Range('A3').Value2='Snapshot UTC: '+$manifest.SnapshotUtc
 $summary.Range('A4').Value2='Local OneDrive: '+$import.Root
 $summary.Range('A6').Value2='Account';$summary.Range('B6').Value2='CSV rows';$summary.Range('C6').Value2='Excel rows';$summary.Range('D6').Value2='CSV ClosePL';$summary.Range('E6').Value2='Excel ClosePL';$summary.Range('F6').Value2='Result'
 $line=7
 foreach($a in $report.Accounts) {
  $summary.Cells.Item($line,1).Value2=[string]$a.Login
  $summary.Cells.Item($line,2).Value2=[double]$a.CsvRows
  $summary.Cells.Item($line,3).Value2=[double]$a.ExcelRows
  $summary.Cells.Item($line,4).Value2=[double]$a.CsvClosePL
  $summary.Cells.Item($line,5).Value2=[double]$a.ExcelClosePL
  $summary.Cells.Item($line,6).Value2='PASS'
  $line++
 }
 $summary.Range('A12').Value2='PASS: Refresh All matches all 1,062 CSV rows across four real accounts.'
 $summary.Range('A13').Value2='PASS: 8 copied file hashes match the VPS snapshot.'
 $summary.Range('A14').Value2='Cloud sync on VPS needs OneDrive sign-in. This test uses a copied snapshot.'
 $summary.Range('A1:F1').Font.Bold=$true
 $summary.Range('A6:F6').Font.Bold=$true
 $summary.Range('A6:F10').Borders.LineStyle=1
 $summary.Range('D7:E10').NumberFormat='#,##0.00'
 $summary.Columns.Item('A').ColumnWidth=25
 $summary.Columns.Item('B:F').ColumnWidth=18
 $summary.Activate()
 $excel.ActiveWindow.Zoom=100
 $excel.StatusBar='PASS: REAL VPS data verified against CSV files; Excel ready.'
 $book.Save()
 $book.RefreshAll()
 $excel.CalculateUntilAsyncQueriesDone()
 if($baskets.ListRows.Count -ne $report.BasketRows){throw 'Second Refresh All changed snapshot row count.'}
 $report.RepeatedRefreshPassed=$true
 $book.Save()
 $report.Passed=$true
 Capture-Excel '04-verification-results.png'
 $excel.DisplayAlerts=$true
} catch {$report.Error=$_.Exception.Message;$report.Stack=$_.ScriptStackTrace;$report.Passed=$false}
$report.VerifiedUtc=[DateTime]::UtcNow.ToString('o')
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkDir 'real-excel-verification.json') -Encoding UTF8
if(-not $report.Passed){exit 1}
