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
    # RunKey + text coercion — same class of bug as ranked DD (array "=" does not coerce).
    $acct = "`$A$Row"
    $run = "`$B$Row"
    "=IFERROR(LOOKUP(2,1/((BasketDataTable[RunKey]&`"`")=($acct&`"|`"&$run)),BasketDataTable[$Field]),`"`")"
}

function First-Formula {
    param([string]$Field, [int]$Row)
    $acct = "`$A$Row"
    $run = "`$B$Row"
    "=IFERROR(INDEX(BasketDataTable[$Field],AGGREGATE(15,6,(ROW(BasketDataTable[$Field])-ROW(BasketDataTable[#Headers]))/((BasketDataTable[RunKey]&`"`")=($acct&`"|`"&$run)),1)),`"`")"
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

    # Account/run keys come from AccountRunsTable (PQ → hidden "Account Runs" sheet).
    # Metric formulas live only on Account Analysis and are never inside a query table,
    # so Refresh All cannot clear them. Prefill fixed formula rows; empty keys stay blank.
    $runs = $null
    try { $runs = $book.Worksheets.Item('Account Runs').ListObjects.Item('AccountRunsTable') } catch { }
    if(-not $runs) { throw 'AccountRunsTable is missing. Install AmarTrading_AccountRuns before repairing analysis formulas.' }
    $result.AnalysisGroups = [int]$runs.ListRows.Count
    if($result.AnalysisGroups -lt 1) { throw 'AccountRunsTable has no rows after refresh.' }

    function Wrap-IfAccount([int]$Row, [string]$Formula) {
        $body = $Formula.TrimStart('=')
        "=IF(`$A$Row=`"`",`"`",$body)"
    }

    $analysis.Range('A4:BY104').ClearContents()
    $analysis.Range('A4').Value2 = 'Account/run keys follow Refresh All via Account Runs (Power Query). DD and other metrics are formulas outside any PQ load range and are not cleared by Refresh All.'
    $analysis.Range('A4:BO4').Merge()
    $maxRows = 100
    for($offset = 0; $offset -lt $maxRows; $offset++) {
        $row = 5 + $offset
        # Do not use Text (@) format on formula key cells — Excel stores the formula as literal text.
        $analysis.Cells.Item($row,1).NumberFormat = 'General'
        $analysis.Cells.Item($row,2).NumberFormat = 'General'
        # Keys pulled from AccountRunsTable — not static values written once at repair time.
        Set-Formula $analysis.Cells.Item($row,1) "=IF(ROWS(`$A`$5:A$row)>ROWS(AccountRunsTable),`"`",INDEX(AccountRunsTable[AccountNumber],ROWS(`$A`$5:A$row)))"
        Set-Formula $analysis.Cells.Item($row,2) "=IF(ROWS(`$A`$5:A$row)>ROWS(AccountRunsTable),`"`",INDEX(AccountRunsTable[RunID],ROWS(`$A`$5:A$row)))"

        Set-Formula $analysis.Cells.Item($row,3)  (Wrap-IfAccount $row (Manual-Formula 4 $row))
        Set-Formula $analysis.Cells.Item($row,4) (Wrap-IfAccount $row "=IFERROR(INDEX(BasketDataTable[StartTime],MATCH(`$A$row&`"|`"&`$B$row,BasketDataTable[RunKey],0)),`"`")")
        Set-Formula $analysis.Cells.Item($row,5)  (Wrap-IfAccount $row (Manual-Formula 5 $row))
        Set-Formula $analysis.Cells.Item($row,6)  (Wrap-IfAccount $row (Latest-Formula 'RunStartBalance' $row))
        Set-Formula $analysis.Cells.Item($row,7)  (Wrap-IfAccount $row (Manual-Formula 6 $row))
        Set-Formula $analysis.Cells.Item($row,8)  (Wrap-IfAccount $row (Manual-Formula 7 $row))

        $latestFields = @('FixedLots','PipsStep','TakeProfit','Tral','TralStart','MaxSpread','TimeStart','TimeEnd','OpenTime','SpeedEA','NewBasketDelaySeconds','UseBasketTrailingTP','TrailingStart','TrailingStep','KillSwitchEnable','KillEquityLevel','KillCooldownMinutes','MaxOrdersInBasket','MaxTotalLotsInBasket','RegimeEnable','RegimeAction','EnableRecoveryStepUp','RecoveryWaitMinutes','RecoveryMaxTotalLotsInBasket')
        for($j = 0; $j -lt $latestFields.Count; $j++) { Set-Formula $analysis.Cells.Item($row,9+$j) (Wrap-IfAccount $row (Latest-Formula $latestFields[$j] $row)) }
        Set-Formula $analysis.Cells.Item($row,33) (Wrap-IfAccount $row (Manual-Formula 8 $row))

        $acct = "`$A$row"; $run = "`$B$row"
        $runKey = "($acct&`"|`"&$run)"
        $runKeyMatch = "(BasketDataTable[RunKey]&`"`"=$runKey)"
        $acctMatch = "((BasketDataTable[AccountNumber]&`"`")=($acct&`"`"))"
        $runMatch = "((BasketDataTable[RunID]&`"`")=($run&`"`"))"
        $criteria = "($runKeyMatch)"
        $criteriaLegacy = "($acctMatch*$runMatch)"
        Set-Formula $analysis.Cells.Item($row,34) (Wrap-IfAccount $row "=IFERROR(SUMIF(BasketDataTable[RunKey],$runKey,BasketDataTable[ClosePL]),0)")
        Set-Formula $analysis.Cells.Item($row,35) (Wrap-IfAccount $row "=IFERROR(ROUND(SUMPRODUCT(($criteria)*(BasketDataTable[TradeDate]<>`"`")/COUNTIFS(BasketDataTable[AccountNumber],BasketDataTable[AccountNumber],BasketDataTable[RunID],BasketDataTable[RunID],BasketDataTable[TradeDate],BasketDataTable[TradeDate])),0),0)")
        Set-Formula $analysis.Cells.Item($row,36) (Wrap-IfAccount $row "=IFERROR(AH$row/AI$row,0)")
        $rankFormula = { param([int]$k) "=IF(`$A$row=`"`",`"`",IF(`$AO$row>=$k,IFERROR(AGGREGATE(14,6,BasketDataTable[MaxFloatingDrawdownAbs]/($runKeyMatch),$k),IFERROR(AGGREGATE(14,6,BasketDataTable[MaxFloatingDrawdownAbs]/($criteriaLegacy),$k),`"`")),`"`"))" }
        for($k = 1; $k -le 10; $k++) { Set-Formula $analysis.Cells.Item($row,67+$k) (&$rankFormula $k) }
        Set-Formula $analysis.Cells.Item($row,37) (Wrap-IfAccount $row "=BP$row")
        Set-Formula $analysis.Cells.Item($row,38) (Wrap-IfAccount $row "=BQ$row")
        Set-Formula $analysis.Cells.Item($row,39) (Wrap-IfAccount $row "=BR$row")
        Set-Formula $analysis.Cells.Item($row,40) (Wrap-IfAccount $row "=IFERROR(SUM(BP${row}:BY${row})/MAX(1,COUNT(BP${row}:BY${row})),0)")
        Set-Formula $analysis.Cells.Item($row,41) (Wrap-IfAccount $row "=IFERROR(COUNTIF(BasketDataTable[RunKey],$runKey),0)")
        Set-Formula $analysis.Cells.Item($row,42) (Wrap-IfAccount $row "=COUNTIFS(BasketDataTable[RunKey],$runKey,BasketDataTable[ClosePL],`">0`")")
        Set-Formula $analysis.Cells.Item($row,43) (Wrap-IfAccount $row "=SUMIFS(BasketDataTable[ClosePL],BasketDataTable[RunKey],$runKey,BasketDataTable[ClosePL],`">0`")")
        Set-Formula $analysis.Cells.Item($row,44) (Wrap-IfAccount $row "=COUNTIFS(BasketDataTable[RunKey],$runKey,BasketDataTable[ClosePL],`"<0`")")
        Set-Formula $analysis.Cells.Item($row,45) (Wrap-IfAccount $row "=-SUMIFS(BasketDataTable[ClosePL],BasketDataTable[RunKey],$runKey,BasketDataTable[ClosePL],`"<0`")")
        Set-Formula $analysis.Cells.Item($row,46) (Wrap-IfAccount $row "=IFERROR(AH$row/AO$row,0)")
        Set-Formula $analysis.Cells.Item($row,47) (Wrap-IfAccount $row "=SUMIF(BasketDataTable[RunKey],$runKey,BasketDataTable[TimesNearKill])")
        Set-Formula $analysis.Cells.Item($row,48) (Wrap-IfAccount $row "=COUNTIFS(BasketDataTable[RunKey],$runKey,BasketDataTable[CloseReason],`"KILL`")")
        for($j = 1; $j -le 10; $j++) { Set-Formula $analysis.Cells.Item($row,48+$j) (Wrap-IfAccount $row "=COUNTIFS(BasketDataTable[RunKey],$runKey,BasketDataTable[MaxOrdersConcurrent],`">=$j`")") }
        Set-Formula $analysis.Cells.Item($row,59) (Wrap-IfAccount $row "=SUMPRODUCT($criteria*(BasketDataTable[MaxTotalLotsInBasket]>0)*(BasketDataTable[MaxTotalLots]>=BasketDataTable[MaxTotalLotsInBasket]))")
        Set-Formula $analysis.Cells.Item($row,60) (Wrap-IfAccount $row "=IFERROR(AH$row/AN$row,0)")
        Set-Formula $analysis.Cells.Item($row,61) (Wrap-IfAccount $row "=IFERROR(AQ$row/AP$row,0)")
        Set-Formula $analysis.Cells.Item($row,62) (Wrap-IfAccount $row "=IFERROR(AS$row/AR$row,0)")
        Set-Formula $analysis.Cells.Item($row,63) (Wrap-IfAccount $row "=IFERROR(AP$row/AO$row,0)")
        Set-Formula $analysis.Cells.Item($row,64) (Wrap-IfAccount $row "=IFERROR(AR$row/AO$row,0)")
        Set-Formula $analysis.Cells.Item($row,65) (Wrap-IfAccount $row "=(BI$row*BK$row)-(BJ$row*BL$row)")
        Set-Formula $analysis.Cells.Item($row,66) (Wrap-IfAccount $row "=IFERROR(AJ$row/AN$row,0)")
        Set-Formula $analysis.Cells.Item($row,67) (Wrap-IfAccount $row "=IF(AO$row=0,`"No basket data`",IF(SUMPRODUCT($criteria*(BasketDataTable[ConfigFingerprint]<>`"`")/COUNTIFS(BasketDataTable[AccountNumber],BasketDataTable[AccountNumber],BasketDataTable[RunID],BasketDataTable[RunID],BasketDataTable[ConfigFingerprint],BasketDataTable[ConfigFingerprint]))>1,`"Configuration changed during run`",`"OK`"))")
    }
    $analysis.Range('BP:BY').EntireColumn.Hidden = $true

    $quality = $book.Worksheets.Item('Data Quality')
    $quality.Range('B4').Formula = '=COUNTIF(''Account Analysis''!$A$5:$A$104,"<>")'
    $quality.Range('C4').Value2 = 'Count of populated Account Analysis rows; no dynamic spill reference.'
    $quality.Range('A10:C12').ClearContents()
    $quality.Range('A10').Value2 = 'Analysis group coverage'
    $quality.Range('B10').Formula = '=IF(SUMPRODUCT((BasketDataTable[AccountNumber]<>"")*(COUNTIFS(''Account Analysis''!$A$5:$A$104,BasketDataTable[AccountNumber],''Account Analysis''!$B$5:$B$104,BasketDataTable[RunID])=0))>0,"INCOMPLETE ANALYSIS - add account/run","OK")'
    $quality.Range('C10').Value2 = 'Account Analysis A:B pull from AccountRunsTable after Refresh All.'
    $quality.Range('A11').Value2 = 'Duplicate analysis keys'
    $quality.Range('B11').Formula = '=IF(SUMPRODUCT((''Account Analysis''!$A$5:$A$104<>"")*(COUNTIFS(''Account Analysis''!$A$5:$A$104,''Account Analysis''!$A$5:$A$104,''Account Analysis''!$B$5:$B$104,''Account Analysis''!$B$5:$B$104)>1))>0,"DUPLICATE ACCOUNT/RUN","OK")'
    $quality.Range('C11').Value2 = 'Account and Run ID together must be unique.'
    $quality.Range('A12').Value2 = 'Excel compatibility'
    $quality.Range('B12').Value2 = 'Excel 2019 formulas'
    $quality.Range('C12').Value2 = 'DD/metric formulas are outside PQ tables; Account Runs query supplies keys. Refresh All must not clear formula cells.'

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
