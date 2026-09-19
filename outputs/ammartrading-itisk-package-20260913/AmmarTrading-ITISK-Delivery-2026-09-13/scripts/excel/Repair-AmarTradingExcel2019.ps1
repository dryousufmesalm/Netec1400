[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkbookPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$VerificationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Excel 2019 has structured references, SUMIFS/COUNTIFS, LOOKUP, AGGREGATE,
# and SUMPRODUCT, but it does not have MAP, LAMBDA, FILTER, UNIQUE, XLOOKUP, or
# dynamic spill references. This script changes only Account Analysis formulas.
$excel = $null
$book = $null
$result = [ordered]@{
    Passed = $false
    WorkbookPath = $OutputPath
    ExcelVersion = $null
    ExcelBuild = $null
    QueriesBefore = @()
    QueriesAfter = @()
    ConnectionsBefore = 0
    ConnectionsAfter = 0
    ImportRowsBefore = 0
    AnalysisGroups = 0
    FormulaErrors = @()
    Error = $null
}

function Set-Formula {
    param([object]$Cell, [string]$Formula)
    $Cell.Formula = $Formula
}

function Set-ArrayFormula {
    param([object]$Cell, [string]$Formula)
    $Cell.FormulaArray = $Formula
}

function Latest-Formula {
    param([string]$Field, [int]$Row)
    $acct = "`$A$Row"
    $run = "`$B$Row"
    "=IFERROR(LOOKUP(2,1/((BasketDataTable[AccountNumber]=$acct)*(BasketDataTable[RunID]=$run)),BasketDataTable[$Field]),`"`")"
}

function First-Formula {
    param([string]$Field, [int]$Row)
    $acct = "`$A$Row"
    $run = "`$B$Row"
    "=IFERROR(INDEX(BasketDataTable[$Field],AGGREGATE(15,6,(ROW(BasketDataTable[$Field])-ROW(BasketDataTable[#Headers]))/((BasketDataTable[AccountNumber]=$acct)*(BasketDataTable[RunID]=$run)),1)),`"`")"
}

function Manual-Formula {
    param([int]$Column, [int]$Row)
    "=IFERROR(VLOOKUP(`$A$Row&`"|`"&`$B$Row,ManualFieldsTable,$Column,FALSE),`"`")"
}

try {
    $source = (Resolve-Path -LiteralPath $WorkbookPath).Path
    $target = [IO.Path]::GetFullPath($OutputPath)
    $verify = [IO.Path]::GetFullPath($VerificationPath)
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)),([IO.Path]::GetDirectoryName($verify)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force

    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.AskToUpdateLinks = $false
    $result.ExcelVersion = [string]$excel.Version
    $result.ExcelBuild = [string]$excel.Build
    $book = $excel.Workbooks.Open($target, 0, $false)

    foreach($q in @($book.Queries)) { $result.QueriesBefore += [string]$q.Name }
    $result.ConnectionsBefore = $book.Connections.Count
    $data = $book.Worksheets.Item('Basket Data').ListObjects.Item('BasketDataTable')
    $analysis = $book.Worksheets.Item('Account Analysis')
    $result.ImportRowsBefore = $data.ListRows.Count
    if($result.ImportRowsBefore -lt 1) { throw 'BasketDataTable has no imported rows.' }

    # Preserve the imported group keys currently loaded by Power Query. These
    # are values, so Excel 2019 does not need dynamic-array enumeration.
    $groups = [ordered]@{}
    for($i = 1; $i -le $data.ListRows.Count; $i++) {
        $acct = [string]$data.ListColumns.Item('AccountNumber').DataBodyRange.Cells.Item($i,1).Value2
        $run = [string]$data.ListColumns.Item('RunID').DataBodyRange.Cells.Item($i,1).Value2
        if($acct -ne '') { $groups["$acct|$run"] = @($acct,$run) }
    }
    if($groups.Count -eq 0) { throw 'No account/run groups were found in BasketDataTable.' }
    $result.AnalysisGroups = $groups.Count

    $analysis.Range('A4:BY104').ClearContents()
    $analysis.Range('A4').Value2 = 'Account/run analysis (Excel 2019 compatible). Refresh All updates imported data; current account/run groups are listed below.'
    $analysis.Range('A4:BO4').Merge()
    $row = 5
    foreach($pair in $groups.Values) {
        $analysis.Cells.Item($row,1).NumberFormat = '@'
        $analysis.Cells.Item($row,2).NumberFormat = '@'
        $analysis.Cells.Item($row,1).Value2 = $pair[0]
        $analysis.Cells.Item($row,2).Value2 = $pair[1]

        Set-Formula $analysis.Cells.Item($row,3)  (Manual-Formula 4 $row)
        Set-Formula $analysis.Cells.Item($row,4) "=IFERROR(INDEX(BasketDataTable[StartTime],MATCH(`$A$row&`"|`"&`$B$row,BasketDataTable[RunKey],0)),`"`")"
        Set-Formula $analysis.Cells.Item($row,5)  (Manual-Formula 5 $row)
        Set-Formula $analysis.Cells.Item($row,6)  (Latest-Formula 'RunStartBalance' $row)
        Set-Formula $analysis.Cells.Item($row,7)  (Manual-Formula 6 $row)
        Set-Formula $analysis.Cells.Item($row,8)  (Manual-Formula 7 $row)

        $latestFields = @('FixedLots','PipsStep','TakeProfit','Tral','TralStart','MaxSpread','TimeStart','TimeEnd','OpenTime','SpeedEA','NewBasketDelaySeconds','UseBasketTrailingTP','TrailingStart','TrailingStep','KillSwitchEnable','KillEquityLevel','KillCooldownMinutes','MaxOrdersInBasket','MaxTotalLotsInBasket','RegimeEnable','RegimeAction','EnableRecoveryStepUp','RecoveryWaitMinutes','RecoveryMaxTotalLotsInBasket')
        for($j = 0; $j -lt $latestFields.Count; $j++) { Set-Formula $analysis.Cells.Item($row,9+$j) (Latest-Formula $latestFields[$j] $row) }
        Set-Formula $analysis.Cells.Item($row,33) (Manual-Formula 8 $row)

        $acct = "`$A$row"; $run = "`$B$row"
        $criteria = "((BasketDataTable[AccountNumber]=$acct)*(BasketDataTable[RunID]=$run))"
        Set-Formula $analysis.Cells.Item($row,34) "=IFERROR(SUMIFS(BasketDataTable[ClosePL],BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run),0)"
        Set-Formula $analysis.Cells.Item($row,35) "=IFERROR(SUMPRODUCT(($criteria)*(BasketDataTable[TradeDate]<>`"`")/COUNTIFS(BasketDataTable[AccountNumber],BasketDataTable[AccountNumber],BasketDataTable[RunID],BasketDataTable[RunID],BasketDataTable[TradeDate],BasketDataTable[TradeDate])),0)"
        Set-Formula $analysis.Cells.Item($row,36) "=IFERROR(AH$row/AI$row,0)"
        $helperCols = @('BP','BQ','BR','BS','BT','BU','BV','BW','BX','BY')
        $rankFormula = { param([int]$k) "=IF(`$AO$row>=$k,IFERROR(AGGREGATE(14,6,BasketDataTable[MaxFloatingDrawdownAbs]/((BasketDataTable[AccountNumber]=`$A$row)*(BasketDataTable[RunID]=`$B$row)),$k),`"`") ,`"`")" }
        for($k = 1; $k -le 10; $k++) { Set-Formula $analysis.Cells.Item($row,67+$k) (&$rankFormula $k) }
        Set-Formula $analysis.Cells.Item($row,37) "=BP$row"
        Set-Formula $analysis.Cells.Item($row,38) "=BQ$row"
        Set-Formula $analysis.Cells.Item($row,39) "=BR$row"
        Set-Formula $analysis.Cells.Item($row,40) "=IFERROR(AVERAGE(BP${row}:BY${row}),0)"
        Set-Formula $analysis.Cells.Item($row,41) "=COUNTIFS(BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run)"
        Set-Formula $analysis.Cells.Item($row,42) "=COUNTIFS(BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run,BasketDataTable[ClosePL],`">0`")"
        Set-Formula $analysis.Cells.Item($row,43) "=SUMIFS(BasketDataTable[ClosePL],BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run,BasketDataTable[ClosePL],`">0`")"
        Set-Formula $analysis.Cells.Item($row,44) "=COUNTIFS(BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run,BasketDataTable[ClosePL],`"<0`")"
        Set-Formula $analysis.Cells.Item($row,45) "=-SUMIFS(BasketDataTable[ClosePL],BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run,BasketDataTable[ClosePL],`"<0`")"
        Set-Formula $analysis.Cells.Item($row,46) "=IFERROR(AH$row/AO$row,0)"
        Set-Formula $analysis.Cells.Item($row,47) "=SUMIFS(BasketDataTable[TimesNearKill],BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run)"
        Set-Formula $analysis.Cells.Item($row,48) "=COUNTIFS(BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run,BasketDataTable[CloseReason],`"KILL`")"
        for($j = 1; $j -le 10; $j++) { Set-Formula $analysis.Cells.Item($row,48+$j) "=COUNTIFS(BasketDataTable[AccountNumber],$acct,BasketDataTable[RunID],$run,BasketDataTable[MaxOrdersConcurrent],`">=$j`")" }
        Set-Formula $analysis.Cells.Item($row,59) "=SUMPRODUCT($criteria*(BasketDataTable[MaxTotalLotsInBasket]>0)*(BasketDataTable[MaxTotalLots]>=BasketDataTable[MaxTotalLotsInBasket]))"
        Set-Formula $analysis.Cells.Item($row,60) "=IFERROR(AH$row/AN$row,0)"
        Set-Formula $analysis.Cells.Item($row,61) "=IFERROR(AQ$row/AP$row,0)"
        Set-Formula $analysis.Cells.Item($row,62) "=IFERROR(AS$row/AR$row,0)"
        Set-Formula $analysis.Cells.Item($row,63) "=IFERROR(AP$row/AO$row,0)"
        Set-Formula $analysis.Cells.Item($row,64) "=IFERROR(AR$row/AO$row,0)"
        Set-Formula $analysis.Cells.Item($row,65) "=(BI$row*BK$row)-(BJ$row*BL$row)"
        Set-Formula $analysis.Cells.Item($row,66) "=IFERROR(AJ$row/AN$row,0)"
        Set-Formula $analysis.Cells.Item($row,67) "=IF(AO$row=0,`"No basket data`",IF(SUMPRODUCT($criteria*(BasketDataTable[ConfigFingerprint]<>`"`")/COUNTIFS(BasketDataTable[AccountNumber],BasketDataTable[AccountNumber],BasketDataTable[RunID],BasketDataTable[RunID],BasketDataTable[ConfigFingerprint],BasketDataTable[ConfigFingerprint]))>1,`"Configuration changed during run`",`"OK`"))"
        $analysis.Range('BP:BY').EntireColumn.Hidden = $true
        $row++
    }

    $quality = $book.Worksheets.Item('Data Quality')
    $quality.Range('B4').Formula = '=COUNTIF(''Account Analysis''!$A$5:$A$104,"<>")'
    $quality.Range('C4').Value2 = 'Count of populated Account Analysis rows; no dynamic spill reference.'
    $quality.Range('A10:C12').ClearContents()
    $quality.Range('A10').Value2 = 'Analysis group coverage'
    $quality.Range('B10').Formula = '=IF(SUMPRODUCT((BasketDataTable[AccountNumber]<>"")*(COUNTIFS(''Account Analysis''!$A$5:$A$104,BasketDataTable[AccountNumber],''Account Analysis''!$B$5:$B$104,BasketDataTable[RunID])=0))>0,"INCOMPLETE ANALYSIS - add account/run","OK")'
    $quality.Range('C10').Value2 = 'Every imported account/run pair must have a matching Account Analysis row.'
    $quality.Range('A11').Value2 = 'Duplicate analysis keys'
    $quality.Range('B11').Formula = '=IF(SUMPRODUCT((''Account Analysis''!$A$5:$A$104<>"")*(COUNTIFS(''Account Analysis''!$A$5:$A$104,''Account Analysis''!$A$5:$A$104,''Account Analysis''!$B$5:$B$104,''Account Analysis''!$B$5:$B$104)>1))>0,"DUPLICATE ACCOUNT/RUN","OK")'
    $quality.Range('C11').Value2 = 'Account and Run ID together must be unique.'
    $quality.Range('A12').Value2 = 'Excel compatibility'
    $quality.Range('B12').Value2 = 'Excel 2019 formulas'
    $quality.Range('C12').Value2 = 'Analysis rows are prefilled for current groups; copy a complete row through hidden drawdown helpers for a new group.'

    # Do not force a full workbook calculation here. Excel 2019 recalculates
    # these formulas when the client opens the saved workbook; forcing the
    # source workbook's old dynamic formulas during COM automation can block.

    foreach($q in @($book.Queries)) { $result.QueriesAfter += [string]$q.Name }
    $result.ConnectionsAfter = $book.Connections.Count
    if((($result.QueriesBefore | Sort-Object) -join '|') -cne (($result.QueriesAfter | Sort-Object) -join '|')) { throw 'Workbook query names changed.' }
    if($result.ConnectionsBefore -ne $result.ConnectionsAfter) { throw 'Workbook connection count changed.' }
    $book.Save()
    $result.Passed = $true
} catch {
    $result.Error = $_.Exception.Message
} finally {
    if($book) { $book.Close($false) }
    if($excel) { $excel.Quit() }
    if($book) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    if($excel) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $VerificationPath -Encoding UTF8
}
if(-not $result.Passed) { exit 1 }
