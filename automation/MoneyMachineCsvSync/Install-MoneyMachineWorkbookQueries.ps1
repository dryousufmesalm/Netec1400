[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkbookPath,
    [string]$PowerQueryRoot,
    [Parameter(Mandatory)][string]$OneDriveRoot,
    [switch]$ResetRootToPlaceholder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $PSCommandPath
if([string]::IsNullOrWhiteSpace($PowerQueryRoot)) { $PowerQueryRoot = Join-Path $ScriptRoot 'PowerQuery' }

$resolvedWorkbook = (Resolve-Path -LiteralPath $WorkbookPath).Path
$resolvedQueryRoot = (Resolve-Path -LiteralPath $PowerQueryRoot).Path
if(-not (Test-Path -LiteralPath $OneDriveRoot -PathType Container)) { throw "OneDrive root not found: $OneDriveRoot" }

$queryFiles = [ordered]@{
    MoneyMachine_Baskets = Join-Path $resolvedQueryRoot 'MoneyMachine_Baskets.m'
    MoneyMachine_SyncStatus = Join-Path $resolvedQueryRoot 'MoneyMachine_SyncStatus.m'
}
foreach($path in $queryFiles.Values) {
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Power Query source not found: $path" }
}

if(-not ('MoneyMachineNativeWindow' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MoneyMachineNativeWindow {
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
}

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
            $newEntry = $archive.CreateEntry('xl/workbook.xml', [IO.Compression.CompressionLevel]::Optimal)
            $writer = New-Object IO.StreamWriter($newEntry.Open(), (New-Object Text.UTF8Encoding($false)))
            try { $writer.Write($cleanXml) } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
}

$excel = New-Object -ComObject Excel.Application
$workbook = $null
$excelProcessId = [uint32]0
$workbookSaved = $false
try {
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    [void][MoneyMachineNativeWindow]::GetWindowThreadProcessId([IntPtr]$excel.Hwnd, [ref]$excelProcessId)
    $workbook = $excel.Workbooks.Open($resolvedWorkbook)

    $formulaSnapshot = [System.Collections.Generic.List[object]]::new()
    foreach($sheet in @($workbook.Worksheets)) {
        try {
            $formulaCells = $sheet.UsedRange.SpecialCells(-4123)
            foreach($cell in @($formulaCells.Cells)) { $formulaSnapshot.Add([pscustomobject]@{ Sheet=$sheet.Name; Address=$cell.Address(); Formula=$cell.Formula }) }
        } catch { }
    }

    $setupSheet = $workbook.Worksheets.Item('Power Query Setup')
    $setupSheet.Range('B4').Value2 = $OneDriveRoot
    try { $workbook.Names.Item('OneDriveRoot').Delete() } catch { }
    [void]$workbook.Names.Add('OneDriveRoot', "='Power Query Setup'!`$B`$4")

    foreach($queryName in $queryFiles.Keys) {
        try { $workbook.Queries.Item($queryName).Delete() } catch { }
        [void]$workbook.Queries.Add($queryName, (Get-Content -LiteralPath $queryFiles[$queryName] -Raw))
    }

    try { $statusSheet = $workbook.Worksheets.Item('Sync Status') }
    catch {
        $statusSheet = $workbook.Worksheets.Add()
        $statusSheet.Name = 'Sync Status'
    }
    $targets = [ordered]@{
        MoneyMachine_Baskets = [pscustomobject]@{ Sheet=$workbook.Worksheets.Item('Basket Data'); Table='BasketDataTable' }
        MoneyMachine_SyncStatus = [pscustomobject]@{ Sheet=$statusSheet; Table='SyncStatusTable' }
    }
    $connectionTemplate = 'OLEDB;Provider=Microsoft.Mashup.OleDb.1;Data Source=$Workbook$;Location={0};Extended Properties=""'
    foreach($queryName in $targets.Keys) {
        $target = $targets[$queryName]
        try { $target.Sheet.ListObjects.Item($target.Table).Delete() } catch { }
        $target.Sheet.Cells.ClearContents()
        $listObject = $target.Sheet.ListObjects.Add(0, ($connectionTemplate -f $queryName), $null, 1, $target.Sheet.Range('A1'))
        $listObject.Name = $target.Table
        $listObject.QueryTable.CommandType = 2
        $listObject.QueryTable.CommandText = "SELECT * FROM [$queryName]"
        $listObject.QueryTable.BackgroundQuery = $false
        $listObject.QueryTable.RefreshOnFileOpen = $true
        if(-not $listObject.QueryTable.Refresh($false)) { throw "Excel refresh failed for query '$queryName'." }
    }

    foreach($saved in $formulaSnapshot) { $workbook.Worksheets.Item($saved.Sheet).Range($saved.Address).Formula = $saved.Formula }
    $restoredFormulaCount = 0
    foreach($sheet in @($workbook.Worksheets)) {
        try { $restoredFormulaCount += $sheet.UsedRange.SpecialCells(-4123).Count } catch { }
    }
    if($restoredFormulaCount -ne $formulaSnapshot.Count) { throw "Workbook formula count changed from $($formulaSnapshot.Count) to $restoredFormulaCount." }

    if($ResetRootToPlaceholder) { $setupSheet.Range('B4').Value2 = 'C:\CHANGE_ME\OneDrive' }
    $workbook.Save()
    $workbookSaved = $true
} finally {
    if($workbook) { $workbook.Close($false) }
    $excel.Quit()
    if($workbook) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($workbook) | Out-Null }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) | Out-Null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if($excelProcessId -gt 0) {
        $excelProcess = Get-Process -Id $excelProcessId -ErrorAction SilentlyContinue
        if($excelProcess) {
            $excelProcess.WaitForExit(2000) | Out-Null
            if(-not $excelProcess.HasExited) { Stop-Process -Id $excelProcessId -Force }
        }
    }
}

if($workbookSaved) { Remove-WorkbookAbsolutePathMetadata -Path $resolvedWorkbook }
