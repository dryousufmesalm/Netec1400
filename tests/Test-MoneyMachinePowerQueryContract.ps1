[CmdletBinding()]
param(
    [string]$BasketQueryPath,
    [string]$StatusQueryPath,
    [string]$WorkbookPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($BasketQueryPath)) { $BasketQueryPath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_Baskets.m' }
if([string]::IsNullOrWhiteSpace($StatusQueryPath)) { $StatusQueryPath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_SyncStatus.m' }

$basketSource = Get-Content -LiteralPath $BasketQueryPath -Raw
if(-not (Test-Path -LiteralPath $StatusQueryPath -PathType Leaf)) { throw "Sync-status query is missing: $StatusQueryPath" }
$statusSource = Get-Content -LiteralPath $StatusQueryPath -Raw

foreach($query in @(
    @{ Name='Basket'; Source=$basketSource },
    @{ Name='Sync-status'; Source=$statusSource }
)) {
    if($query.Source -notmatch [regex]::Escape('\amartrading')) { throw "$($query.Name) query must read the canonical amartrading folder." }
    if($query.Source -notmatch [regex]::Escape('\AmmarTrading')) { throw "$($query.Name) query must retain the legacy AmmarTrading folder as a migration source." }
    if($query.Source -notmatch 'FolderPriority') { throw "$($query.Name) query must mark canonical and legacy folders for precedence." }
    if($query.Source -notmatch 'CanonicalAccounts\s*=\s*List\.Buffer') { throw "$($query.Name) query must identify canonical account folders before selecting migration files." }
    if($query.Source -notmatch 'List\.Contains\(CanonicalAccounts') { throw "$($query.Name) query must exclude a legacy copy when a canonical account folder exists." }
    # Folder.Files can throw for an unavailable OneDrive folder. Buffer must
    # be inside the try expression so the fallback table is actually reached;
    # `try Folder.Files(...)` followed by Table.Buffer is a subtle regression.
    if($query.Source -notmatch 'try\s+Table\.Buffer\s*\(\s*Folder\.Files') { throw "$($query.Name) query must buffer Folder.Files inside its try/fallback guard." }
}

$expectedFingerprintFields = @(
    'FixedLots','Magic','PointsPerPip','PipsStep','TakeProfit','Tral','TralStart','MaxSpread',
    'TimeStart','TimeEnd','OpenTime','NewBasketDelaySeconds','SpeedEA','UseBasketTrailingTP',
    'TrailingStart','TrailingStep','KillSwitchEnable','KillEquityLevel','KillCooldownMinutes',
    'MaxOrdersInBasket','MaxTotalLotsInBasket','RegimeEnable','RegimeAction','RegimeADXPeriod',
    'RegimeADXLevel','RegimeADXBars','RegimeRangeBars','RegimeRecoveryBars','EnableTradingDaysFilter',
    'TradeMonday','TradeTuesday','TradeWednesday','TradeThursday','TradeFriday',
    'EnableRecoveryStepUp','RecoveryWaitMinutes','RecoveryMaxTotalLotsInBasket'
)
$fingerprintBlock = [regex]::Match($basketSource, 'FingerprintFields\s*=\s*\{(?<Fields>.*?)\}', [Text.RegularExpressions.RegexOptions]::Singleline)
if(-not $fingerprintBlock.Success) { throw 'Basket query does not declare FingerprintFields.' }
$actualFingerprintFields = @([regex]::Matches($fingerprintBlock.Groups['Fields'].Value, '"(?<Field>[A-Za-z0-9]+)"') | ForEach-Object { $_.Groups['Field'].Value })
if(($actualFingerprintFields -join '|') -cne ($expectedFingerprintFields -join '|')) { throw 'ConfigFingerprint fields are not the exact documented 37-field sequence.' }
if($basketSource -notmatch 'Text\.From\s*\(\s*value\s*,\s*"en-US"\s*\)') { throw 'ConfigFingerprint conversion must use the en-US invariant culture.' }
if($basketSource -notmatch 'FinalColumns\s*=\s*List\.Combine\s*\(\s*\{\s*ExpectedColumns\s*,\s*\{"VpsId","VpsName","FolderAccountNumber","AccountKey","RunKey","FolderAccountMismatch","ConfigFingerprint"\}\s*\}\s*\)') {
    throw 'Basket query final columns must include VPS identity and reporting keys after the source fields.'
}
foreach($token in @('SyncStatus.json','PublishedUtc','HeartbeatAgeHours','Duration.TotalHours','FreshnessHours = 26','IsFresh','CloudDeliveryVerified')) {
    if($statusSource -notmatch [regex]::Escape($token)) { throw "Sync-status query is missing contract token: $token" }
}

if(-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $package = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $WorkbookPath).Path)
    try {
        $workbookEntry = $package.GetEntry('xl/workbook.xml')
        $reader = New-Object IO.StreamReader($workbookEntry.Open())
        try { $workbookXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if($workbookXml -match 'x15ac:absPath') { throw 'Workbook package must not contain machine-specific absolute-path metadata.' }
    } finally { $package.Dispose() }

    if(-not ('MoneyMachineTestNativeWindow' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MoneyMachineTestNativeWindow {
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
    }
    $excel = New-Object -ComObject Excel.Application
    $workbook = $null
    $excelProcessId = [uint32]0
    try {
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        [void][MoneyMachineTestNativeWindow]::GetWindowThreadProcessId([IntPtr]$excel.Hwnd, [ref]$excelProcessId)
        $workbook = $excel.Workbooks.Open((Resolve-Path -LiteralPath $WorkbookPath).Path, 0, $true)
        foreach($queryName in @('AmarTrading_Baskets','AmarTrading_SyncStatus')) {
            try { $null = $workbook.Queries.Item($queryName) } catch { throw "Workbook query is missing: $queryName" }
        }
        $basketTable = $workbook.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
        $statusTable = $workbook.Worksheets.Item('Sync Status').ListObjects.Item('SyncStatusTable')
        if($basketTable.ListRows.Count -ne 1) { throw 'Staging workbook refresh must produce one basket row.' }
        if($statusTable.ListRows.Count -ne 1) { throw 'Staging workbook refresh must produce one sync-status row.' }
        $freshColumn = 0
        for($columnIndex = 1; $columnIndex -le $statusTable.ListColumns.Count; $columnIndex++) {
            if($statusTable.ListColumns.Item($columnIndex).Name -eq 'IsFresh') { $freshColumn = $columnIndex; break }
        }
        if($freshColumn -lt 1 -or -not [bool]$statusTable.DataBodyRange.Value2[1,$freshColumn]) { throw 'Staging sync-status row must report IsFresh=true.' }
        foreach($table in @($basketTable,$statusTable)) {
            if($table.QueryTable.BackgroundQuery) { throw "Workbook table '$($table.Name)' must disable background refresh." }
            if($table.QueryTable.RefreshOnFileOpen) { throw "Workbook table '$($table.Name)' must not refresh on open before the reporting-PC root is reviewed." }
        }
        $name = $workbook.Names.Item('OneDriveRoot')
        if(-not $name) { throw 'Workbook is missing the OneDriveRoot named cell.' }
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
}

Write-Host 'MoneyMachine Power Query contract passed.'
