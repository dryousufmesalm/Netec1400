[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceWorkbook,
    [Parameter(Mandatory)][string]$FixtureOneDriveRoot,
    [Parameter(Mandatory)][string]$OutputWorkbook,
    [Parameter(Mandatory)][string]$VerificationPath,
    [string]$RepairScript = '',
    [string]$InstallQueriesScript = '',
    [string]$ExpectedAccount = '18335349',
    [double]$ExpectedMaxDd = 486.79,
    [double]$ExpectedSecondDd = 93.94,
    [double]$ExpectedThirdDd = 56.71,
    [double]$ExpectedNetProfit = 210.14,
    [double]$ExpectedAvgTop10 = 78.294
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepairScript) {
    $RepairScript = Join-Path $PSScriptRoot 'Repair-AmarTradingExcel2019.ps1'
}
if (-not $InstallQueriesScript) {
    $InstallQueriesScript = Join-Path $PSScriptRoot '..\..\automation\MoneyMachineCsvSync\Install-MoneyMachineWorkbookQueries.ps1'
}

$outDir = Split-Path -Parent $OutputWorkbook
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stageWorkbook = Join-Path $outDir 'stage-before-repair.xlsx'
Copy-Item -LiteralPath $SourceWorkbook -Destination $stageWorkbook -Force

# Embed latest PQ with fixture OneDrive root (sets B4 / named range).
& $InstallQueriesScript -WorkbookPath $stageWorkbook -OneDriveRoot $FixtureOneDriveRoot

$excel = $null
$book = $null
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.AskToUpdateLinks = $false
    $book = $excel.Workbooks.Open((Resolve-Path -LiteralPath $stageWorkbook).Path, 0, $false)
    $setup = $book.Worksheets.Item('Power Query Setup')
    $setup.Range('B4').Value2 = $FixtureOneDriveRoot
    $book.RefreshAll()
    # Allow async PQ refresh to finish
    try { $excel.CalculateUntilAsyncQueriesDone() } catch { Start-Sleep -Seconds 5 }
    Start-Sleep -Seconds 2
    $book.Save()
} finally {
    if ($book) { $book.Close($true) }
    if ($excel) { $excel.Quit() }
    if ($book) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    if ($excel) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}

$repairVerify = Join-Path $outDir 'repair-verification.json'
& $RepairScript -WorkbookPath $stageWorkbook -OutputPath $OutputWorkbook -VerificationPath $repairVerify

$excel = $null
$book = $null
$result = [ordered]@{
    Passed = $false
    Account = $ExpectedAccount
    Expected = [ordered]@{
        MaxDd = $ExpectedMaxDd
        SecondDd = $ExpectedSecondDd
        ThirdDd = $ExpectedThirdDd
        NetProfit = $ExpectedNetProfit
        AvgTop10 = $ExpectedAvgTop10
    }
    Actual = [ordered]@{}
    Error = $null
}
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $book = $excel.Workbooks.Open((Resolve-Path -LiteralPath $OutputWorkbook).Path, 0, $false)
    $excel.CalculateFullRebuild()
    $analysis = $book.Worksheets.Item('Account Analysis')
    $row = $null
    for ($r = 5; $r -le 104; $r++) {
        $acct = [string]$analysis.Cells.Item($r, 1).Value2
        if ($acct -eq $ExpectedAccount) { $row = $r; break }
    }
    if (-not $row) { throw "Account $ExpectedAccount not found on Account Analysis after repair." }
    $result.Actual.Row = $row
    $result.Actual.RunId = [string]$analysis.Cells.Item($row, 2).Value2
    $result.Actual.NetProfit = [double]$analysis.Cells.Item($row, 34).Value2
    $result.Actual.MaxDd = [double]$analysis.Cells.Item($row, 37).Value2
    $result.Actual.SecondDd = [double]$analysis.Cells.Item($row, 38).Value2
    $result.Actual.ThirdDd = [double]$analysis.Cells.Item($row, 39).Value2
    $result.Actual.AvgTop10 = [double]$analysis.Cells.Item($row, 40).Value2
    $result.Actual.TotalBaskets = [double]$analysis.Cells.Item($row, 41).Value2
    $result.Actual.MaxDdFormula = [string]$analysis.Cells.Item($row, 37).Formula
    $result.Actual.HelperBpFormula = [string]$analysis.Cells.Item($row, 68).Formula

    function Assert-Close([double]$actual, [double]$expected, [string]$name, [double]$tol = 0.02) {
        if ([math]::Abs($actual - $expected) -gt $tol) {
            throw "$name expected $expected got $actual"
        }
    }
    Assert-Close $result.Actual.NetProfit $ExpectedNetProfit 'NetProfit'
    Assert-Close $result.Actual.MaxDd $ExpectedMaxDd 'MaxDd'
    Assert-Close $result.Actual.SecondDd $ExpectedSecondDd 'SecondDd'
    Assert-Close $result.Actual.ThirdDd $ExpectedThirdDd 'ThirdDd'
    Assert-Close $result.Actual.AvgTop10 $ExpectedAvgTop10 'AvgTop10' 0.05
    $result.Passed = $true
    $book.Save()
} catch {
    $result.Error = $_.Exception.Message
} finally {
    if ($book) { $book.Close($false) }
    if ($excel) { $excel.Quit() }
    if ($book) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    if ($excel) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $VerificationPath -Encoding UTF8
}
if (-not $result.Passed) { exit 1 }
