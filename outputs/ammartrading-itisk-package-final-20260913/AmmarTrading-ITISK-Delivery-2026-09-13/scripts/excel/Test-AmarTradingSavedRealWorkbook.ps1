$ErrorActionPreference='Stop'
$dir='C:\CodexWorker\amartrading-real-vps-20260904'
$excel=$null;$book=$null
$report=@{Passed=$false;Error=$null}
try {
 $excel=New-Object -ComObject Excel.Application
 $excel.Visible=$false;$excel.DisplayAlerts=$false
 $book=$excel.Workbooks.Open((Join-Path $dir 'AmarTrading_REAL_VPS.xlsx'),0,$true)
 $book.RefreshAll();$excel.CalculateUntilAsyncQueriesDone();$excel.CalculateFullRebuild()
 $data=$book.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
 $a=$book.Worksheets.Item('Account Analysis')
 if($data.ListRows.Count -ne 1062 -or $a.Range('A5#').Rows.Count -ne 4){throw 'Saved workbook refresh did not restore the real records/analysis groups.'}
 $manifest=Get-Content (Join-Path $dir 'vps-snapshot\snapshot-manifest.json') -Raw | ConvertFrom-Json
 foreach($row in 5..8) {
  $e=$manifest.Accounts | Where-Object Login -eq ([string]$a.Cells.Item($row,1).Value2)
  if(-not $e -or [double]$a.Cells.Item($row,41).Value2 -ne $e.Rows -or [math]::Abs([double]$a.Cells.Item($row,34).Value2-$e.ClosePLSum) -gt 0.005){throw 'Saved analysis values differ from source.'}
 }
 if($book.Queries.Count -ne 2 -or $book.Connections.Count -ne 2){throw 'Unexpected query or connection count after reopening.'}
 $report.Passed=$true;$report.Rows=$data.ListRows.Count;$report.AnalysisGroups=4;$report.Connections=2;$report.Queries=2
} catch {$report.Error=$_.Exception.Message}
finally {
 if($book){$book.Close($false)}
 if($excel){$excel.Quit()}
 if($book){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book)}
 if($excel){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel)}
}
$report | ConvertTo-Json | Set-Content (Join-Path $dir 'saved-workbook-verification.json') -Encoding UTF8
$report | ConvertTo-Json
if(-not $report.Passed){exit 1}
