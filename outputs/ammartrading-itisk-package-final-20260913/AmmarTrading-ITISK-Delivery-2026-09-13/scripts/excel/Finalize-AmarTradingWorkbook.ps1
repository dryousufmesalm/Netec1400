[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkbookPath,
    [string]$ClientOneDriveRoot = 'C:\Users\User\OneDrive'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-WorkbookAbsolutePathMetadata {
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $archive.GetEntry('xl/workbook.xml')
        if(-not $entry) { throw 'Workbook package is missing xl/workbook.xml.' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $pattern = '<mc:AlternateContent[^>]*>\s*<mc:Choice[^>]*>\s*<x15ac:absPath[^>]*/>\s*</mc:Choice>\s*</mc:AlternateContent>'
        $cleanXml = [regex]::Replace($xml, $pattern, '', [Text.RegularExpressions.RegexOptions]::Singleline)
        if($cleanXml -eq $xml -and $xml -match 'x15ac:absPath') { throw 'Could not remove workbook absolute-path metadata.' }
        if($cleanXml -ne $xml) {
            $entry.Delete()
            $replacement = $archive.CreateEntry('xl/workbook.xml', [IO.Compression.CompressionLevel]::Optimal)
            $writer = New-Object IO.StreamWriter($replacement.Open(), (New-Object Text.UTF8Encoding($false)))
            try { $writer.Write($cleanXml) } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
}

$resolvedWorkbook = (Resolve-Path -LiteralPath $WorkbookPath).Path
$expectedQueries = @('AmarTrading_Baskets','AmarTrading_SyncStatus')
$expectedConnections = @('Query - AmarTrading_Baskets','Query - AmarTrading_SyncStatus')
$excel = New-Object -ComObject Excel.Application
$workbook = $null
try {
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.AskToUpdateLinks = $false
    $workbook = $excel.Workbooks.Open($resolvedWorkbook, 0, $false)

    $actualQueries = @($workbook.Queries | ForEach-Object { $_.Name } | Sort-Object)
    if(($actualQueries -join '|') -cne (($expectedQueries | Sort-Object) -join '|')) {
        throw "Expected only canonical workbook queries; found: $($actualQueries -join ', ')"
    }

    $formulaSnapshot = [System.Collections.Generic.List[object]]::new()
    foreach($sheet in @($workbook.Worksheets)) {
        try {
            foreach($cell in @($sheet.UsedRange.SpecialCells(-4123).Cells)) {
                $formulaSnapshot.Add([pscustomobject]@{ Sheet=$sheet.Name; Address=$cell.Address(); Formula=$cell.Formula2 })
            }
        } catch { }
    }

    $setup = $workbook.Worksheets.Item('Power Query Setup')
    $setup.Range('B4').Value2 = $ClientOneDriveRoot
    try { $workbook.Names.Item('OneDriveRoot').Delete() } catch { }
    [void]$workbook.Names.Add('OneDriveRoot', "='Power Query Setup'!`$B`$4")
    $setup.Range('A5').Value2 = 'Expected folder'
    $setup.Range('B5').Value2 = 'amartrading\Account_<MT4Login>\Baskets.csv and SyncStatus.json'
    $setup.Range('A6').Value2 = 'Embedded query names'
    $setup.Range('B6').Value2 = $expectedQueries -join '; '
    $setup.Range('A8').Value2 = 'The two AmarTrading queries are embedded in this workbook. Edit OneDrive root above, then choose Refresh All.'
    $setup.Range('A10:A1000').ClearContents()
    $line = 10
    foreach($queryName in $expectedQueries) {
        $setup.Cells.Item($line, 1).Value2 = "'shared $queryName ="
        $line++
        foreach($mLine in ([string]$workbook.Queries.Item($queryName).Formula -split "`r?`n")) {
            $setup.Cells.Item($line, 1).Value2 = "'$mLine"
            $line++
        }
        $line++
    }

    foreach($name in @('BasketDataTable','SyncStatusTable')) {
        $table = if($name -eq 'BasketDataTable') { $workbook.Worksheets.Item('Basket Data').ListObjects.Item($name) } else { $workbook.Worksheets.Item('Sync Status').ListObjects.Item($name) }
        if($null -eq $table.QueryTable) { throw "Table '$name' is no longer query-backed." }
        $table.QueryTable.BackgroundQuery = $false
        $table.QueryTable.RefreshOnFileOpen = $false
        if($table.DataBodyRange) { $table.DataBodyRange.ClearContents() }
    }

    foreach($connection in @($workbook.Connections)) {
        $location = ''
        try { $location = [string]$connection.OLEDBConnection.Connection } catch { }
        foreach($queryName in $expectedQueries) {
            if($location -match [regex]::Escape("Location=$queryName")) {
                $connection.Name = "Query - $queryName"
            }
        }
    }
    $connectionNames = @($workbook.Connections | ForEach-Object { $_.Name } | Sort-Object)
    if(($connectionNames -join '|') -cne (($expectedConnections | Sort-Object) -join '|')) {
        throw "Expected exactly two canonical query connections; found: $($connectionNames -join ', ')"
    }

    foreach($saved in $formulaSnapshot) { $workbook.Worksheets.Item($saved.Sheet).Range($saved.Address).Formula2 = $saved.Formula }
    $restoredFormulaCount = 0
    foreach($sheet in @($workbook.Worksheets)) {
        try { $restoredFormulaCount += $sheet.UsedRange.SpecialCells(-4123).Count } catch { }
    }
    if($restoredFormulaCount -ne $formulaSnapshot.Count) { throw "Formula count changed from $($formulaSnapshot.Count) to $restoredFormulaCount." }
    $workbook.Save()
} finally {
    if($workbook) { $workbook.Close($false) }
    $excel.Quit()
    if($workbook) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($workbook) }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel)
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

Remove-WorkbookAbsolutePathMetadata -Path $resolvedWorkbook
Write-Host "Finalized workbook: $resolvedWorkbook"
