[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkbookPath,
    [Parameter(Mandatory)][string]$OneDriveRoot,
    [Parameter(Mandatory)][string]$OutputWorkbook,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$RepairScript = '',
    [string]$InstallQueriesScript = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepairScript) { $RepairScript = Join-Path $PSScriptRoot 'Repair-AmarTradingExcel2019.ps1' }
if (-not $InstallQueriesScript) {
    $InstallQueriesScript = Join-Path $PSScriptRoot '..\..\automation\MoneyMachineCsvSync\Install-MoneyMachineWorkbookQueries.ps1'
}

$outDir = Split-Path -Parent $OutputWorkbook
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stage = Join-Path $outDir 'audit-stage.xlsx'
Copy-Item -LiteralPath $WorkbookPath -Destination $stage -Force

& $InstallQueriesScript -WorkbookPath $stage -OneDriveRoot $OneDriveRoot

$excel = $null; $book = $null
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.AskToUpdateLinks = $false
    $book = $excel.Workbooks.Open((Resolve-Path $stage).Path, 0, $false)
    $book.Worksheets.Item('Power Query Setup').Range('B4').Value2 = $OneDriveRoot
    $book.RefreshAll()
    try { $excel.CalculateUntilAsyncQueriesDone() } catch { Start-Sleep -Seconds 8 }
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
& $RepairScript -WorkbookPath $stage -OutputPath $OutputWorkbook -VerificationPath $repairVerify

function Convert-ToDouble([object]$Value) {
    if ($null -eq $Value) { return 0.0 }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return 0.0 }
    $number = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    try { return [double]$text } catch { return 0.0 }
}

function Get-CsvMetrics([string]$CsvPath) {
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    if ($rows.Count -lt 1) { return @{} }
    $byRun = @{}
    foreach ($r in $rows) {
        $acct = [string]$r.AccountNumber
        $run = [string]$r.RunID
        $key = "$acct|$run"
        if (-not $byRun.ContainsKey($key)) {
            $byRun[$key] = [ordered]@{
                Account = $acct; RunId = $run; Rows = 0; NetProfit = 0.0
                WinCount = 0; LossCount = 0; WinSum = 0.0; LossSumAbs = 0.0
                KillCount = 0; TimesNearKill = 0.0; DDs = New-Object System.Collections.Generic.List[double]
                TradeDates = New-Object 'System.Collections.Generic.HashSet[string]'
                FixedLotsLatest = $null
            }
        }
        $g = $byRun[$key]
        $g.Rows++
        $pl = Convert-ToDouble $r.ClosePL
        $g.NetProfit += $pl
        if ($pl -gt 0) { $g.WinCount++; $g.WinSum += $pl }
        elseif ($pl -lt 0) { $g.LossCount++; $g.LossSumAbs += (-$pl) }
        $g.DDs.Add((Convert-ToDouble $r.MaxFloatingDrawdownAbs))
        if ([string]$r.CloseReason -eq 'KILL') { $g.KillCount++ }
        $g.TimesNearKill += (Convert-ToDouble $r.TimesNearKill)
        if ($r.TradeDate) { [void]$g.TradeDates.Add([string]$r.TradeDate) }
        $g.FixedLotsLatest = $r.FixedLots
    }
    foreach ($key in @($byRun.Keys)) {
        $g = $byRun[$key]
        $sorted = $g.DDs | Sort-Object -Descending
        $top = @($sorted | Select-Object -First 10)
        $g.MaxDd = if ($top.Count -ge 1) { [double]$top[0] } else { 0 }
        $g.SecondDd = if ($top.Count -ge 2) { [double]$top[1] } else { $null }
        $g.ThirdDd = if ($top.Count -ge 3) { [double]$top[2] } else { $null }
        $g.AvgTop10 = if ($top.Count -gt 0) { ($top | Measure-Object -Average).Average } else { 0 }
        $g.TradingDays = $g.TradeDates.Count
        $g.AvgBasket = if ($g.Rows -gt 0) { $g.NetProfit / $g.Rows } else { 0 }
        $g.WinRate = if ($g.Rows -gt 0) { $g.WinCount / $g.Rows } else { 0 }
        $byRun[$key] = $g
    }
    return $byRun
}

# Discover newest Baskets.csv per account under OneDriveRoot\amartrading (and AmmarTrading)
$roots = @()
foreach ($name in @('amartrading', 'AmmarTrading')) {
    $p = Join-Path $OneDriveRoot $name
    if (Test-Path -LiteralPath $p) { $roots += $p }
}
$candidates = @{}
foreach ($root in $roots) {
    Get-ChildItem -LiteralPath $root -Recurse -Filter 'Baskets.csv' -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = Split-Path $_.FullName -Parent
        $leaf = Split-Path $dir -Leaf
        if ($leaf -notlike 'Account_*') { return }
        $acct = $leaf.Substring('Account_'.Length)
        $parent = Split-Path $dir -Parent | Split-Path -Leaf
        $vpsRank = if ($parent -like 'VPS_*') { 0 } else { 1 }
        $item = [pscustomobject]@{ Path = $_.FullName; Account = $acct; VpsRank = $vpsRank; Modified = $_.LastWriteTimeUtc }
        if (-not $candidates.ContainsKey($acct)) { $candidates[$acct] = @() }
        $candidates[$acct] += $item
    }
}
$latestCsv = @{}
foreach ($acct in $candidates.Keys) {
        $best = $candidates[$acct] | Sort-Object `
            @{ Expression = 'Modified'; Descending = $true }, `
            @{ Expression = 'VpsRank'; Descending = $false } |
            Select-Object -First 1
        $latestCsv[$acct] = $best.Path
    }

$csvMetrics = @{}
foreach ($acct in $latestCsv.Keys) {
    $m = Get-CsvMetrics $latestCsv[$acct]
    foreach ($k in $m.Keys) { $csvMetrics[$k] = $m[$k] }
}

$excel = $null; $book = $null
$report = [ordered]@{
    Passed = $false
    GeneratedAt = (Get-Date).ToString('o')
    OneDriveRoot = $OneDriveRoot
    LatestCsvPerAccount = $latestCsv
    GroupsChecked = 0
    Failures = @()
    Warnings = @()
    GroupResults = @()
    FormulaSamples = [ordered]@{}
    DataQuality = [ordered]@{}
    Findings = @()
}
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $book = $excel.Workbooks.Open((Resolve-Path $OutputWorkbook).Path, 0, $false)
    $excel.CalculateFullRebuild()
    $analysis = $book.Worksheets.Item('Account Analysis')
    $basket = $book.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
    $sync = $null
    try { $sync = $book.Worksheets.Item('Sync Status').ListObjects.Item('SyncStatusTable') } catch { }

    $report.FormulaSamples.MaxDdHelper = [string]$analysis.Cells.Item(5, 68).Formula
    $report.FormulaSamples.LatestFixedLots = [string]$analysis.Cells.Item(5, 9).Formula
    $report.FormulaSamples.NetProfit = [string]$analysis.Cells.Item(5, 34).Formula
    $report.FormulaSamples.WinCount = [string]$analysis.Cells.Item(5, 42).Formula

    # Flag residual unsafe patterns in row-5 formulas
    $unsafe = @()
    foreach ($col in (@(3..67) + @(68..77))) {
        $f = [string]$analysis.Cells.Item(5, $col).Formula
        if ($f -match 'BasketDataTable\[AccountNumber\]=\$A5' -or $f -match 'BasketDataTable\[RunID\]=\$B5') {
            $unsafe += "Col$col`: $f"
        }
    }
    if ($unsafe.Count -gt 0) {
        $report.Findings += "UNSAFE_MATCH_PATTERNS: $($unsafe -join ' | ')"
        $report.Failures += $unsafe
    } else {
        $report.Findings += 'All sampled Account Analysis formulas use RunKey or text-coerced matching (no bare AccountNumber=$A / RunID=$B array equals).'
    }

    function CloseEnough([double]$a, [double]$b, [double]$tol = 0.05) {
        return [math]::Abs($a - $b) -le $tol
    }

    for ($r = 5; $r -le 104; $r++) {
        $acct = [string]$analysis.Cells.Item($r, 1).Value2
        $run = [string]$analysis.Cells.Item($r, 2).Value2
        if ([string]::IsNullOrWhiteSpace($acct)) { continue }
        $key = "$acct|$run"
        $report.GroupsChecked++
        $actual = [ordered]@{
            Row = $r; Account = $acct; RunId = $run
            NetProfit = [double]$analysis.Cells.Item($r, 34).Value2
            TradingDays = [double]$analysis.Cells.Item($r, 35).Value2
            MaxDd = $analysis.Cells.Item($r, 37).Value2
            SecondDd = $analysis.Cells.Item($r, 38).Value2
            ThirdDd = $analysis.Cells.Item($r, 39).Value2
            AvgTop10 = [double]$analysis.Cells.Item($r, 40).Value2
            TotalBaskets = [double]$analysis.Cells.Item($r, 41).Value2
            WinCount = [double]$analysis.Cells.Item($r, 42).Value2
            LossCount = [double]$analysis.Cells.Item($r, 44).Value2
            AvgBasket = [double]$analysis.Cells.Item($r, 46).Value2
            KillCount = [double]$analysis.Cells.Item($r, 48).Value2
            TimesNearKill = [double]$analysis.Cells.Item($r, 47).Value2
            FixedLots = $analysis.Cells.Item($r, 9).Value2
            WinRate = [double]$analysis.Cells.Item($r, 63).Value2
            ConfigStatus = [string]$analysis.Cells.Item($r, 67).Value2
        }
        $rowResult = [ordered]@{ Key = $key; Actual = $actual; Ok = $true; Mismatches = @() }
        if (-not $csvMetrics.ContainsKey($key)) {
            $rowResult.Ok = $false
            $rowResult.Mismatches += "No CSV ground truth for $key (latest-file map may disagree)"
            $report.Failures += $rowResult.Mismatches[-1]
        } else {
            $exp = $csvMetrics[$key]
            $checks = @(
                @{ N = 'NetProfit'; A = [double]$actual.NetProfit; E = [double]$exp.NetProfit; T = 0.05 }
                @{ N = 'TotalBaskets'; A = [double]$actual.TotalBaskets; E = [double]$exp.Rows; T = 0 }
                @{ N = 'WinCount'; A = [double]$actual.WinCount; E = [double]$exp.WinCount; T = 0 }
                @{ N = 'LossCount'; A = [double]$actual.LossCount; E = [double]$exp.LossCount; T = 0 }
                @{ N = 'KillCount'; A = [double]$actual.KillCount; E = [double]$exp.KillCount; T = 0 }
                @{ N = 'TimesNearKill'; A = [double]$actual.TimesNearKill; E = [double]$exp.TimesNearKill; T = 0.05 }
                @{ N = 'MaxDd'; A = [double]$actual.MaxDd; E = [double]$exp.MaxDd; T = 0.05 }
                @{ N = 'AvgTop10'; A = [double]$actual.AvgTop10; E = [double]$exp.AvgTop10; T = 0.05 }
                @{ N = 'TradingDays'; A = [math]::Round([double]$actual.TradingDays); E = [double]$exp.TradingDays; T = 0 }
                @{ N = 'AvgBasket'; A = [double]$actual.AvgBasket; E = [double]$exp.AvgBasket; T = 0.05 }
                @{ N = 'WinRate'; A = [double]$actual.WinRate; E = [double]$exp.WinRate; T = 0.001 }
            )
            if ($null -ne $exp.SecondDd -and $actual.SecondDd -ne $null -and "$($actual.SecondDd)" -ne '') {
                $checks += @{ N = 'SecondDd'; A = [double]$actual.SecondDd; E = [double]$exp.SecondDd; T = 0.05 }
            }
            if ($null -ne $exp.ThirdDd -and $actual.ThirdDd -ne $null -and "$($actual.ThirdDd)" -ne '') {
                $checks += @{ N = 'ThirdDd'; A = [double]$actual.ThirdDd; E = [double]$exp.ThirdDd; T = 0.05 }
            }
            foreach ($c in $checks) {
                if (-not (CloseEnough $c.A $c.E $c.T)) {
                    $msg = "$key $($c.N): expected $($c.E) got $($c.A)"
                    $rowResult.Ok = $false
                    $rowResult.Mismatches += $msg
                    $report.Failures += $msg
                }
            }
            $rowResult.Expected = [ordered]@{
                NetProfit = $exp.NetProfit; Rows = $exp.Rows; MaxDd = $exp.MaxDd
                SecondDd = $exp.SecondDd; ThirdDd = $exp.ThirdDd; AvgTop10 = $exp.AvgTop10
                WinCount = $exp.WinCount; LossCount = $exp.LossCount; WinRate = $exp.WinRate
            }
        }
        # Blank/error scan on key metric cells
        foreach ($col in @(34, 37, 40, 41, 42, 46, 63)) {
            $txt = [string]$analysis.Cells.Item($r, $col).Text
            if ($txt -match '^(#N/A|#DIV/0!|#VALUE!|#REF!|#NAME\?)$') {
                $msg = "$key col$col error display: $txt"
                $rowResult.Ok = $false
                $rowResult.Mismatches += $msg
                $report.Failures += $msg
            }
        }
        $report.GroupResults += $rowResult
    }

    $quality = $book.Worksheets.Item('Data Quality')
    $report.DataQuality.ImportedRows = [string]$quality.Range('B2').Text
    $report.DataQuality.AnalysisCoverage = [string]$quality.Range('B10').Text
    $report.DataQuality.DuplicateKeys = [string]$quality.Range('B11').Text
    if ($report.DataQuality.AnalysisCoverage -ne 'OK') {
        $report.Warnings += "Data Quality analysis coverage: $($report.DataQuality.AnalysisCoverage)"
    }

    # Basket Data row count vs sum of latest CSV rows
    $basketRows = $basket.ListRows.Count
    $csvRowSum = 0
    foreach ($m in $csvMetrics.Values) { $csvRowSum += [int]$m.Rows }
    $report.BasketRows = $basketRows
    $report.CsvRowSumLatest = $csvRowSum
    if ($basketRows -ne $csvRowSum) {
        $report.Warnings += "Basket Data rows ($basketRows) != sum of latest CSV rows ($csvRowSum); check latest-file-per-account or extra accounts in workbook"
    } else {
        $report.Findings += "Basket Data row count matches sum of latest Baskets.csv rows ($csvRowSum); latest-file-per-account OK (stale flat duplicates excluded)."
    }

    if ($sync) {
        $report.SyncStatusRows = $sync.ListRows.Count
        $report.Findings += "Sync Status rows: $($sync.ListRows.Count)"
    }

    $report.Findings += "Checked $($report.GroupsChecked) Account Analysis groups against latest Baskets.csv ground truth."
    $failedGroups = @($report.GroupResults | Where-Object { -not $_.Ok }).Count
    $report.FailedGroups = $failedGroups
    $report.Passed = ($report.Failures.Count -eq 0)
    $book.Save()
} catch {
    $report.Error = $_.Exception.Message
    $report.Passed = $false
} finally {
    if ($book) { $book.Close($false) }
    if ($excel) { $excel.Quit() }
    if ($book) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    if ($excel) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
}
if (-not $report.Passed) { exit 1 }
