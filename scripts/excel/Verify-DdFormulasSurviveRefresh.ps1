[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceWorkbook,
    [Parameter(Mandatory)][string]$FixtureOneDriveRoot,
    [Parameter(Mandatory)][string]$OutputWorkbook,
    [Parameter(Mandatory)][string]$VerificationPath,
    [string]$InstallQueriesScript = '',
    [string]$RepairScript = '',
    [string]$ExpectedAccount = '18335349',
    [double]$ExpectedMaxDd = 486.79,
    [double]$ExpectedSecondDd = 93.94,
    [double]$ExpectedThirdDd = 56.71,
    [double]$ExpectedAvgTop10 = 78.294
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $InstallQueriesScript) {
    $InstallQueriesScript = Join-Path $PSScriptRoot '..\..\automation\MoneyMachineCsvSync\Install-MoneyMachineWorkbookQueries.ps1'
}
if (-not $RepairScript) { $RepairScript = Join-Path $PSScriptRoot 'Repair-AmarTradingExcel2019.ps1' }

$outDir = Split-Path -Parent $OutputWorkbook
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stage = Join-Path $outDir 'survive-stage.xlsx'
Copy-Item -LiteralPath $SourceWorkbook -Destination $stage -Force

& $InstallQueriesScript -WorkbookPath $stage -OneDriveRoot $FixtureOneDriveRoot
$repairVerify = Join-Path $outDir 'survive-repair.json'
& $RepairScript -WorkbookPath $stage -OutputPath $OutputWorkbook -VerificationPath $repairVerify

$result = [ordered]@{ Passed = $false; Steps = @(); Error = $null }

function Get-DdSnapshot($Analysis, [string]$Account) {
    for ($r = 5; $r -le 104; $r++) {
        if ([string]$Analysis.Cells.Item($r, 1).Value2 -eq $Account) {
            return [ordered]@{
                Row = $r
                Account = [string]$Analysis.Cells.Item($r, 1).Value2
                RunId = [string]$Analysis.Cells.Item($r, 2).Value2
                AccountFormula = [string]$Analysis.Cells.Item($r, 1).Formula
                HelperFormula = [string]$Analysis.Cells.Item($r, 68).Formula
                MaxDd = $Analysis.Cells.Item($r, 37).Value2
                SecondDd = $Analysis.Cells.Item($r, 38).Value2
                ThirdDd = $Analysis.Cells.Item($r, 39).Value2
                AvgTop10 = $Analysis.Cells.Item($r, 40).Value2
                TotalBaskets = $Analysis.Cells.Item($r, 41).Value2
                NetProfit = $Analysis.Cells.Item($r, 34).Value2
            }
        }
    }
    return $null
}

$excel = $null; $book = $null
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $book = $excel.Workbooks.Open((Resolve-Path $OutputWorkbook).Path, 0, $false)
    $excel.CalculateFullRebuild()
    $analysis = $book.Worksheets.Item('Account Analysis')

    $before = Get-DdSnapshot $analysis $ExpectedAccount
    if (-not $before) { throw "Account $ExpectedAccount missing before refresh" }
    if ($before.HelperFormula -notmatch 'AGGREGATE') { throw 'DD helper formula missing before refresh' }
    if ($before.AccountFormula -notmatch 'AccountRunsTable') { throw 'Account key is not driven by AccountRunsTable' }
    $result.Before = $before
    $result.Steps += 'before_ok'

    # Refresh All twice — formulas and values must survive
    foreach ($pass in 1..2) {
        $book.RefreshAll()
        try { $excel.CalculateUntilAsyncQueriesDone() } catch { Start-Sleep -Seconds 8 }
        Start-Sleep -Seconds 2
        $excel.CalculateFullRebuild()
        $after = Get-DdSnapshot $analysis $ExpectedAccount
        if (-not $after) { throw "Account $ExpectedAccount missing after refresh pass $pass" }
        if ([string]::IsNullOrEmpty([string]$after.HelperFormula)) { throw "DD helper formula cleared on refresh pass $pass" }
        if ($after.HelperFormula -notmatch 'AGGREGATE') { throw "DD helper formula lost AGGREGATE on pass $pass" }
        if ($after.AccountFormula -notmatch 'AccountRunsTable') { throw "Account key formula cleared on pass $pass" }
        foreach ($pair in @(
            @{ N = 'MaxDd'; E = $ExpectedMaxDd; A = [double]$after.MaxDd },
            @{ N = 'SecondDd'; E = $ExpectedSecondDd; A = [double]$after.SecondDd },
            @{ N = 'ThirdDd'; E = $ExpectedThirdDd; A = [double]$after.ThirdDd },
            @{ N = 'AvgTop10'; E = $ExpectedAvgTop10; A = [double]$after.AvgTop10 }
        )) {
            if ([math]::Abs($pair.A - $pair.E) -gt 0.05) {
                throw "Pass $pass $($pair.N): expected $($pair.E) got $($pair.A)"
            }
        }
        $result["AfterPass$pass"] = $after
        $result.Steps += "refresh_pass_${pass}_ok"
    }

    # Confirm Account Analysis is not a query table
    if ($analysis.ListObjects.Count -ne 0) {
        throw "Account Analysis must not host ListObjects/query tables; found $($analysis.ListObjects.Count)"
    }
    $runs = $book.Worksheets.Item('Account Runs').ListObjects.Item('AccountRunsTable')
    $result.AccountRunsRows = [int]$runs.ListRows.Count
    $result.QueryNames = @($book.Queries | ForEach-Object { $_.Name })
    $result.Passed = $true
    $book.Save()
} catch {
    $result.Error = $_.Exception.Message
    $result.Passed = $false
} finally {
    if ($book) { $book.Close($false) }
    if ($excel) { $excel.Quit() }
    if ($book) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    if ($excel) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $VerificationPath -Encoding UTF8
}
if (-not $result.Passed) { exit 1 }
