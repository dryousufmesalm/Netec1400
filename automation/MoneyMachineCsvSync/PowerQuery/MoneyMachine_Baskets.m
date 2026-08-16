let
    // Edit this path once to the local OneDrive folder that contains MoneyMachine.
    OneDriveRoot = "C:\\CHANGE_ME\\OneDrive",
    ExpectedColumns = {
        "AccountNumber","BrokerName","BasketID","Symbol","SymbolNormalized","Timeframe","StartTime","EndTime","DurationSeconds","Direction","OrdersCount","TotalLots","FixedLots","MaxOrdersConcurrent","MaxTotalLots","MaxFloatingDrawdownAbs","MaxFloatingProfit","ClosePL","CloseReason","OutcomeClass","SpreadAtEntry","EquityAtEntry","HeadroomAtEntry","MinHeadroom","TimesNearKill","ExposureBlocks","PipsStep","TakeProfit","KillEquityLevel","MaxOrdersInBasket","MaxTotalLotsInBasket","EquityAtExit","BalanceAfter","TradeDate","RunID","RunStartTime","RunStartBalance","EAName","EAVersion","Magic","PointsPerPip","Tral","TralStart","MaxSpread","TimeStart","TimeEnd","OpenTime","NewBasketDelaySeconds","SpeedEA","UseBasketTrailingTP","TrailingStart","TrailingStep","KillSwitchEnable","KillCooldownMinutes","RegimeEnable","RegimeAction","RegimeADXPeriod","RegimeADXLevel","RegimeADXBars","RegimeRangeBars","RegimeRecoveryBars","EnableTradingDaysFilter","TradeMonday","TradeTuesday","TradeWednesday","TradeThursday","TradeFriday","EnableRecoveryStepUp","RecoveryWaitMinutes","RecoveryMaxTotalLotsInBasket","CsvSchemaVersion"
    },
    Files = Folder.Files(OneDriveRoot & "\\MoneyMachine"),
    BasketFiles = Table.SelectRows(Files, each [Name] = "Baskets.csv" and Text.Contains([Folder Path], "\\Account_")),
    WithFolderLogin = Table.AddColumn(BasketFiles, "FolderAccountNumber", each List.Last(Text.Split(Text.TrimEnd([Folder Path], "\\"), "Account_")), type text),
    WithCsv = Table.AddColumn(WithFolderLogin, "Data", each Table.SelectColumns(Table.PromoteHeaders(Csv.Document([Content], [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv]), [PromoteAllScalars=true]), ExpectedColumns, MissingField.UseNull)),
    Keep = Table.SelectColumns(WithCsv, {"FolderAccountNumber","Data"}),
    Expanded = Table.ExpandTableColumn(Keep, "Data", ExpectedColumns, ExpectedColumns),
    Normalized = Table.SelectColumns(Expanded, List.Combine({{"FolderAccountNumber"}, ExpectedColumns}), MissingField.UseNull),
    Typed = Table.TransformColumnTypes(Normalized, {
        {"FolderAccountNumber", type text},{"AccountNumber", type text},{"BasketID", Int64.Type},{"StartTime", type datetime},{"EndTime", type datetime},{"ClosePL", type number},{"MaxFloatingDrawdownAbs", type number},{"TimesNearKill", Int64.Type},{"RunStartTime", type datetime},{"RunStartBalance", type number},{"MaxOrdersConcurrent", Int64.Type},{"MaxTotalLots", type number},{"MaxTotalLotsInBasket", type number},{"CsvSchemaVersion", Int64.Type}
    }),
    WithLegacyRunID = Table.ReplaceValue(Typed, null, "Legacy-v2", Replacer.ReplaceValue, {"RunID"}),
    WithRunKey = Table.AddColumn(WithLegacyRunID, "RunKey", each [AccountNumber] & "|" & [RunID], type text),
    WithMismatch = Table.AddColumn(WithRunKey, "FolderAccountMismatch", each [FolderAccountNumber] <> [AccountNumber], type logical),
    WithConfigFingerprint = Table.AddColumn(WithMismatch, "ConfigFingerprint", each Text.Combine(List.Transform({[Magic],[PointsPerPip],[PipsStep],[TakeProfit],[Tral],[TralStart],[MaxSpread],[TimeStart],[TimeEnd],[OpenTime],[NewBasketDelaySeconds],[SpeedEA],[UseBasketTrailingTP],[TrailingStart],[TrailingStep],[KillSwitchEnable],[KillEquityLevel],[KillCooldownMinutes],[MaxOrdersInBasket],[MaxTotalLotsInBasket],[RegimeEnable],[RegimeAction],[EnableRecoveryStepUp],[RecoveryWaitMinutes],[RecoveryMaxTotalLotsInBasket]}, each if _ = null then "" else Text.From(_)), "|"), type text)
in
    WithConfigFingerprint
