param([string]$WorkbookName='AmarTrading_REAL_VPS.xlsx',[string]$WorkDir='C:\CodexWorker\amartrading-real-vps-20260904')
$ErrorActionPreference='Stop'
$result=@{Passed=$false;Error=$null}
try {
 $excel=[Runtime.InteropServices.Marshal]::GetActiveObject('Excel.Application')
 $book=$excel.Workbooks.Item($WorkbookName)
 $sheet=$book.Worksheets.Item('Account Analysis')
 $table=$book.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
 $original=@{}
 for($col=3;$col -le 67;$col++){$original[$col]=[string]$sheet.Cells.Item(5,$col).Formula2}
 # Derive field names from the actual loaded schema, removing the old 3,058-row ceiling.
 $fields=@{}
 for($col=1;$col -le $table.ListColumns.Count;$col++) {
  $address=[string]$table.HeaderRowRange.Cells.Item(1,$col).Address()
  $letter=($address -replace '[^A-Z]','')
  $fields[$letter]=$table.ListColumns.Item($col).Name
 }
 $rangePattern="'Basket Data'!\`$([A-Z]+)\`$2:\`$\1\`$[0-9]+"
 $sheet.Range('A4:BO4').ClearContents()
 $sheet.Range('A4').Value2='Accounts and runs expand automatically after Refresh All. Requires Excel with MAP support (Microsoft 365 / Excel 2024).'
 $sheet.Range('A5:B5').ClearContents()
 $sheet.Range('A5').Formula2='=IFERROR(SORT(UNIQUE(FILTER(CHOOSE({1,2},BasketDataTable[AccountNumber],BasketDataTable[RunID]),BasketDataTable[AccountNumber]<>""))),{"",""})'
 for($col=3;$col -le 67;$col++) {
  $formula=$original[$col].TrimStart('=')
  $formula=$formula.Replace('_xlfn._xlws.','').Replace('_xlfn.','')
  $formula=[regex]::Replace($formula,$rangePattern,[Text.RegularExpressions.MatchEvaluator]{param($m) 'BasketDataTable['+$fields[$m.Groups[1].Value]+']'})
  $formula=$formula.Replace("'Manual Fields'!`$A`$2:`$H`$101",'ManualFieldsTable')
  $keyed=$formula.Contains('$A5') -or $formula.Contains('$B5')
  if($keyed) {
   $formula=$formula.Replace('$A5','acct').Replace('$B5','run')
   if($formula.Contains('LOOKUP(2,')) {
    $returnColumn=[regex]::Matches($formula,'BasketDataTable\[[^\]]+\]') | Select-Object -Last 1
    $formula='XLOOKUP(acct&"|"&run,BasketDataTable[RunKey],'+$returnColumn.Value+',"",0,-1)'
   }
   if($col -eq 40) {
    $formula='IFERROR(AVERAGE(LARGE(FILTER(BasketDataTable[MaxFloatingDrawdownAbs],(BasketDataTable[AccountNumber]=acct)*(BasketDataTable[RunID]=run)),SEQUENCE(MIN(10,COUNTIFS(BasketDataTable[AccountNumber],acct,BasketDataTable[RunID],run))))),0)'
   }
   $formula=$formula.Replace('AO5','COUNTIFS(BasketDataTable[AccountNumber],acct,BasketDataTable[RunID],run)')
   $sheet.Cells.Item(5,$col).Formula2='=MAP(INDEX($A$5#,0,1),INDEX($A$5#,0,2),LAMBDA(acct,run,IF(acct="","",'+$formula+')))'
  } else {
   $formula=[regex]::Replace($formula,'(?<![A-Za-z0-9_])([A-Z]{1,2})5(?![0-9#])','${1}5#')
   $sheet.Cells.Item(5,$col).Formula2='=IF(INDEX($A$5#,0,1)="","",'+$formula+')'
  }
 }
 $quality=$book.Worksheets.Item('Data Quality')
 $quality.Range('A1:C9').ClearContents()
 $quality.Range('A1').Value2='Check';$quality.Range('B1').Value2='Current result';$quality.Range('C1').Value2='Meaning'
 $quality.Range('A2').Value2='Imported basket rows';$quality.Range('B2').Formula2='=COUNTA(BasketDataTable[AccountNumber])'
 $quality.Range('C2').Value2='Live table row count after Refresh All; no sample baseline.'
 $quality.Range('A3').Value2='CSV schema';$quality.Range('B3').Formula2='=IF(COUNT(BasketDataTable[CsvSchemaVersion])=0,"No data",IF(COUNTIF(BasketDataTable[CsvSchemaVersion],3)=COUNT(BasketDataTable[CsvSchemaVersion]),"Schema v3","Mixed or older schema"))'
 $quality.Range('C3').Value2='Derived from the imported CsvSchemaVersion column.'
 $quality.Range('A4').Value2='Account/run groups';$quality.Range('B4').Formula2='=IF(COUNTA(BasketDataTable[AccountNumber])=0,0,ROWS(''Account Analysis''!A5#))'
 $quality.Range('C4').Value2='Account Analysis expands to every imported account/run.'
 $quality.Range('A5').Value2='Folder/account mismatches';$quality.Range('B5').Formula2='=COUNTIF(BasketDataTable[FolderAccountMismatch],TRUE)'
 $quality.Range('C5').Value2='Zero means imported account identifiers agree with their folders.'
 $quality.Range('A6').Value2='Configuration changes';$quality.Range('B6').Value2='Formula monitored'
 $quality.Range('C6').Value2='Account Analysis compares configuration fingerprints within each run.'
 $quality.Range('A7').Value2='Status records';$quality.Range('B7').Formula2='=COUNTA(SyncStatusTable[AccountNumber])'
 $quality.Range('C7').Value2='Local heartbeat records; cloud delivery requires separate verification.'
 $quality.Range('A8').Value2='Fresh heartbeats';$quality.Range('B8').Formula2='=COUNTIF(SyncStatusTable[IsFresh],TRUE)'
 $quality.Range('C8').Value2='Derived from heartbeat timestamps and status.'
 $quality.Range('A9').Value2='Refresh setup';$quality.Range('B9').Value2='Queries embedded'
 $quality.Range('C9').Value2='Set OneDriveRoot on Power Query Setup, then Data > Refresh All. No M code pasting is needed.'
 $excel.CalculateFullRebuild()
 $expected=Get-Content -LiteralPath (Join-Path $WorkDir 'vps-snapshot\snapshot-manifest.json') -Raw | ConvertFrom-Json
 $rows=$sheet.Range('A5#').Rows.Count
 if($rows -ne $expected.Accounts.Count){throw "Expected four analysis groups; got $rows"}
 $result.Accounts=@()
 for($i=5;$i -lt 5+$rows;$i++) {
  $login=[string]$sheet.Cells.Item($i,1).Value2
  $e=$expected.Accounts | Where-Object Login -eq $login
  $count=[double]$sheet.Cells.Item($i,41).Value2
  $pl=[double]$sheet.Cells.Item($i,34).Value2
  if(-not $e -or $count -ne $e.Rows -or [math]::Abs($pl-$e.ClosePLSum) -gt 0.005){throw "Analysis totals mismatch: $login rows=$count net=$pl"}
  $result.Accounts+=@{Login=$login;Rows=$count;ClosePL=$pl;ConfigStatus=$sheet.Cells.Item($i,67).Text}
 }
 if([double]$quality.Range('B2').Value2 -ne 1062 -or $quality.Range('B3').Value2 -ne 'Schema v3'){throw 'Data Quality still disagrees with the loaded dataset.'}
 $result.Rows=$rows;$result.Passed=$true
 $book.Save()
 $sheet.Activate()
 $excel.ActiveWindow.Zoom=70
} catch {$result.Error=$_.Exception.Message;$result.Stack=$_.ScriptStackTrace}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $WorkDir 'analytics-verification.json') -Encoding UTF8
if(-not $result.Passed){exit 1}
