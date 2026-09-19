param(
    [Parameter(Mandatory)][string]$WorkbookPath,
    [Parameter(Mandatory)][string]$FixtureCsv,
    [Parameter(Mandatory)][string]$WorkDir,
    [switch]$InspectOnly,
    [switch]$ShowExcel
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$report = [ordered]@{ Passed=$false; Workbook=$WorkbookPath; Queries=@(); Tables=@(); Error=$null }
$excel = $null
$book = $null
try {
    $root = Join-Path $WorkDir 'OneDrive'
    $source = @(Import-Csv -LiteralPath $FixtureCsv)[0]
    foreach($login in @('892525830','892525831','892525833','892525834')) {
        $dir = Join-Path $root "amartrading\Account_$login"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $source.AccountNumber = $login
        $source | Export-Csv -LiteralPath (Join-Path $dir 'Baskets.csv') -NoTypeInformation -Encoding UTF8
        @{AccountNumber=$login;Status='Success';RowCount=1;SourceHash='fixture';DestinationHash='fixture';SourceLastWriteUtc=[DateTime]::UtcNow.ToString('o');PublishedUtc=[DateTime]::UtcNow.ToString('o');CloudDeliveryVerified=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'SyncStatus.json') -Encoding UTF8
    }
    if($ShowExcel) {
        try { $excel = [Runtime.InteropServices.Marshal]::GetActiveObject('Excel.Application') } catch { }
    }
    if(-not $excel) { $excel = New-Object -ComObject Excel.Application }
    $excel.Visible = [bool]$ShowExcel
    $excel.DisplayAlerts = $false
    $excel.AskToUpdateLinks = $false
    $report.ExcelVersion = $excel.Version
    $report.ExcelBuild = $excel.Build
    $fullPath = [IO.Path]::GetFullPath($WorkbookPath)
    for($i=1; $i -le $excel.Workbooks.Count; $i++) {
        $candidate = $excel.Workbooks.Item($i)
        if($candidate.FullName -eq $fullPath) { $book = $candidate; break }
    }
    if(-not $book) { $book = $excel.Workbooks.Open($fullPath,0,$false) }
    for($attempt=0; -not $book -and $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        for($i=1; $i -le $excel.Workbooks.Count; $i++) {
            $candidate = $excel.Workbooks.Item($i)
            if($candidate.FullName -eq $fullPath) { $book = $candidate; break }
        }
    }
    if(-not $book) { throw 'Excel did not return or open the requested workbook.' }
    for($i=1; $i -le $book.Queries.Count; $i++) { $report.Queries += $book.Queries.Item($i).Name }
    $report.ConnectionCount = $book.Connections.Count
    $report.OneDriveRootAtOpen = [string]$book.Names.Item('OneDriveRoot').RefersToRange.Value2
    foreach($sheet in $book.Worksheets) {
        foreach($table in $sheet.ListObjects) {
            $item = [ordered]@{Sheet=$sheet.Name;Name=$table.Name;Columns=$table.ListColumns.Count;Rows=$table.ListRows.Count}
            $item.SourceType = $table.SourceType
            if($table.SourceType -eq 0 -or $table.SourceType -eq 3) {
                $item.Command = [string]$table.QueryTable.CommandText
                $item.Connection = [string]$table.QueryTable.Connection
            }
            $report.Tables += $item
        }
    }
    if(-not $InspectOnly) {
        if((($report.Queries | Sort-Object) -join ',') -cne 'AmarTrading_Baskets,AmarTrading_SyncStatus') { throw 'Required canonical queries are missing or unexpected queries remain.' }
        if($book.Connections.Count -ne 2) { throw 'Expected exactly two workbook connections.' }
        $book.Names.Item('OneDriveRoot').RefersToRange.Value2 = $root
        $basket = $book.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
        $status = $book.Worksheets.Item('Sync Status').ListObjects.Item('SyncStatusTable')
        foreach($table in @($basket,$status)) {
            $qt = $table.QueryTable
            $qt.BackgroundQuery = $false
            if(-not $qt.Refresh($false)) { throw "Refresh returned false: $($table.Name)" }
        }
        if($basket.ListRows.Count -ne 4 -or $status.ListRows.Count -ne 4) { throw "Unexpected rows: baskets=$($basket.ListRows.Count), status=$($status.ListRows.Count)" }
        if($basket.ListColumns.Count -ne 75 -or $status.ListColumns.Count -ne 12) { throw 'Unexpected query output column count.' }
        $logins = @()
        for($i=1; $i -le 4; $i++) { $logins += [string]$basket.ListColumns.Item('AccountNumber').DataBodyRange.Cells.Item($i,1).Value2 }
        $report.VerifiedAccountLogins = $logins
        if((($logins | Sort-Object) -join ',') -ne '892525830,892525831,892525833,892525834') { throw 'Query rows did not match all four fixture accounts.' }
        for($i=1; $i -le 4; $i++) {
            if([double]$basket.ListColumns.Item('ClosePL').DataBodyRange.Cells.Item($i,1).Value2 -ne 3.5) { throw 'ClosePL type/value mismatch.' }
            if(-not [bool]$status.ListColumns.Item('IsFresh').DataBodyRange.Cells.Item($i,1).Value2) { throw 'Fresh heartbeat fixture was not recognized.' }
        }
        $report.VerifiedAccountLogins = $logins
        $report.InitialRows = @{Baskets=$basket.ListRows.Count;Status=$status.ListRows.Count}
        foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'amartrading') -Recurse -Filter Baskets.csv) {
            $rows = @(Import-Csv -LiteralPath $file.FullName)
            $extra = $rows[0].PSObject.Copy()
            $extra.BasketID = '2'
            @($rows[0],$extra) | Export-Csv -LiteralPath $file.FullName -NoTypeInformation -Encoding UTF8
        }
        $book.RefreshAll()
        $excel.CalculateUntilAsyncQueriesDone()
        if($basket.ListRows.Count -ne 8 -or $status.ListRows.Count -ne 4) { throw "RefreshAll failed to load changed files: $($basket.ListRows.Count)" }
        $report.RefreshAllRows = @{Baskets=$basket.ListRows.Count;Status=$status.ListRows.Count}
        $report.Passed = $true
        if($ShowExcel) {
          try {
            $excel.WindowState = -4143
            $excel.Left = 0
            $excel.Top = 0
            $excel.Width = 1000
            $excel.Height = 700
            $excel.WindowState = -4137
            $book.Worksheets.Item('Sync Status').Activate()
            $excel.ActiveWindow.Zoom = 85
            Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AmarExcelWindow {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
            [void][AmarExcelWindow]::SetForegroundWindow([IntPtr]$excel.Hwnd)
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            Start-Sleep -Seconds 2
            $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
            $bitmap = New-Object Drawing.Bitmap $bounds.Width,$bounds.Height
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size)
            $bitmap.Save((Join-Path $WorkDir 'excel-visible.png'))
            $graphics.Dispose()
            $bitmap.Dispose()
          } catch {
            $report.ScreenshotError = $_.Exception.Message
          }
        }
    }
} catch {
    $report.Passed = $false
    $report.Error = $_.Exception.Message
} finally {
    if($book -and -not $ShowExcel) { $book.Close($false) }
    if($excel -and -not $ShowExcel) { $excel.Quit() }
    if($book) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    if($excel) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkDir 'excel-validation.json') -Encoding UTF8
    $report | ConvertTo-Json -Depth 8
}
if(-not $InspectOnly -and -not $report.Passed) { exit 1 }
