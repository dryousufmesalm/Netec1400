[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkbookPath,
    [Parameter(Mandatory)][string]$VerificationPath,
    [switch]$Refresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$excel = $null; $book = $null
$r = [ordered]@{Passed=$false; Workbook=$WorkbookPath; Sha256=$null; ExcelProductReleaseIds=$null; ExcelVersion=$null; ExcelBuild=$null; Refreshed=[bool]$Refresh; Errors=@(); ModernFormulaHits=@(); Accounts=@(); ReopenAccounts=@(); Queries=@(); Connections=0; RowsBefore=0; RowsAfter=0; Error=$null}
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false; $excel.DisplayAlerts = $false; $excel.AskToUpdateLinks = $false
    $r.ExcelVersion = [string]$excel.Version; $r.ExcelBuild = [string]$excel.Build
    try { $r.ExcelProductReleaseIds = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction Stop).ProductReleaseIds } catch { }
    $book = $excel.Workbooks.Open((Resolve-Path -LiteralPath $WorkbookPath).Path,0,$false)
    $data = $book.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
    $a = $book.Worksheets.Item('Account Analysis')
    $quality = $book.Worksheets.Item('Data Quality')
    $r.RowsBefore = $data.ListRows.Count
    if($Refresh) {
        $book.RefreshAll(); $excel.CalculateUntilAsyncQueriesDone()
    }
    $r.RowsAfter = $data.ListRows.Count
    $excel.CalculateFull()
    foreach($sheet in @($book.Worksheets)) {
        try { $formulaCells = @($sheet.UsedRange.SpecialCells(-4123).Cells) } catch { $formulaCells = @() }
        foreach($cell in $formulaCells) {
            $txt = [string]$cell.Text
            if($txt -match '^#(NAME\?|VALUE!|REF!|DIV/0!|N/A|NUM!)$') { $r.Errors += "$($sheet.Name)!$($cell.Address())=$txt" }
            try {
                $f = [string]$cell.Formula2
                if($f -match '_xlfn|_xlws|ANCHORARRAY|MAP\(|LAMBDA\(|FILTER\(|UNIQUE\(|XLOOKUP\(|SEQUENCE\(|\$[A-Z]+\$?5#') { $r.ModernFormulaHits += "$($sheet.Name)!$($cell.Address())=$f" }
            } catch { }
        }
    }
    foreach($q in @($book.Queries)) { $r.Queries += [string]$q.Name }
    $r.Connections = $book.Connections.Count
    $expected = @(
      @{Row=5;Login='892525830';Rows=323;PL=-2127.49;Days=6},
      @{Row=6;Login='892525831';Rows=327;PL=794.31;Days=5},
      @{Row=7;Login='892525833';Rows=261;PL=-3328.87;Days=5},
      @{Row=8;Login='892525834';Rows=151;PL=223.81;Days=5}
    )
    foreach($e in $expected) {
        $login = [string]$a.Cells.Item($e.Row,1).Value2
        $keyType = $a.Cells.Item($e.Row,1).Value2.GetType().Name
        $rows = [double]$a.Cells.Item($e.Row,41).Value2
        $pl = [double]$a.Cells.Item($e.Row,34).Value2
        $days = [math]::Round([double]$a.Cells.Item($e.Row,35).Value2,0)
        $settings = [string]$a.Cells.Item($e.Row,6).Text
        $r.Accounts += @{Login=$login;KeyType=$keyType;Rows=$rows;ClosePL=$pl;TradingDays=$days;RunStartBalance=$settings;Status=[string]$a.Cells.Item($e.Row,67).Text}
        if($login -ne $e.Login -or $keyType -ne 'String' -or $rows -ne $e.Rows -or [math]::Abs($pl-$e.PL) -gt .005 -or $days -ne $e.Days) { throw "Expected values failed for row $($e.Row): login=$login type=$keyType rows=$rows pl=$pl days=$days" }
        if([string]$a.Cells.Item($e.Row,6).Text -eq '') { throw "Settings lookup is blank for row $($e.Row)." }
    }
    if([string]$quality.Range('B4').Text -ne '4') { throw "Data Quality B4 expected 4, got $($quality.Range('B4').Text)" }
    if([string]$quality.Range('B10').Text -ne 'OK' -or [string]$quality.Range('B11').Text -ne 'OK') { throw "Data Quality group checks failed: B10=$($quality.Range('B10').Text), B11=$($quality.Range('B11').Text)" }
    if($r.RowsAfter -ne 1062 -or $r.Queries.Count -ne 2 -or $r.Connections -ne 2) { throw 'Import/query/connection counts changed.' }
    if($r.Errors.Count -gt 0) { throw "Formula errors: $($r.Errors -join '; ')" }
    if($r.ModernFormulaHits.Count -gt 0) { throw "Modern/spill formula references remain: $($r.ModernFormulaHits[0])" }
    $book.Save()
    $book.Close($false); $book = $null
    $book = $excel.Workbooks.Open((Resolve-Path -LiteralPath $WorkbookPath).Path,0,$true)
    $excel.CalculateFull()
    $reopen = $book.Worksheets.Item('Account Analysis')
    foreach($e in $expected) {
        $login = [string]$reopen.Cells.Item($e.Row,1).Value2
        $rows = [double]$reopen.Cells.Item($e.Row,41).Value2
        $pl = [double]$reopen.Cells.Item($e.Row,34).Value2
        $days = [math]::Round([double]$reopen.Cells.Item($e.Row,35).Value2,0)
        $r.ReopenAccounts += @{Login=$login;Rows=$rows;ClosePL=$pl;TradingDays=$days;Status=[string]$reopen.Cells.Item($e.Row,67).Text}
        if($login -ne $e.Login -or $rows -ne $e.Rows -or [math]::Abs($pl-$e.PL) -gt .005 -or $days -ne $e.Days -or [string]$reopen.Cells.Item($e.Row,67).Text -ne 'OK') { throw "Save/reopen verification failed for row $($e.Row)." }
    }
    $r.Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $WorkbookPath).Hash
    $r.Passed = $true
} catch { $r.Error = $_.Exception.Message }
finally {
    if($book) { $book.Close($false) }; if($excel) { $excel.Quit() }
    if($book) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    if($excel) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    if(-not $r.Sha256 -and (Test-Path -LiteralPath $WorkbookPath)) { try { $r.Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $WorkbookPath).Hash } catch { } }
    $r | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $VerificationPath -Encoding UTF8
}
if(-not $r.Passed) { exit 1 }
