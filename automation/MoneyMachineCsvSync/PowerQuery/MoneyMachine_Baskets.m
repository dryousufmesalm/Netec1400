let
    OneDriveRoot = Text.Trim(Text.From(Excel.CurrentWorkbook(){[Name="OneDriveRoot"]}[Content]{0}[Column1])),
    ExpectedColumns = {
        "AccountNumber","BrokerName","BasketID","Symbol","SymbolNormalized","Timeframe","StartTime","EndTime","DurationSeconds","Direction","OrdersCount","TotalLots","FixedLots","MaxOrdersConcurrent","MaxTotalLots","MaxFloatingDrawdownAbs","MaxFloatingProfit","ClosePL","CloseReason","OutcomeClass","SpreadAtEntry","EquityAtEntry","HeadroomAtEntry","MinHeadroom","TimesNearKill","ExposureBlocks","PipsStep","TakeProfit","KillEquityLevel","MaxOrdersInBasket","MaxTotalLotsInBasket","EquityAtExit","BalanceAfter","TradeDate","RunID","RunStartTime","RunStartBalance","EAName","EAVersion","Magic","PointsPerPip","Tral","TralStart","MaxSpread","TimeStart","TimeEnd","OpenTime","NewBasketDelaySeconds","SpeedEA","UseBasketTrailingTP","TrailingStart","TrailingStep","KillSwitchEnable","KillCooldownMinutes","RegimeEnable","RegimeAction","RegimeADXPeriod","RegimeADXLevel","RegimeADXBars","RegimeRangeBars","RegimeRecoveryBars","EnableTradingDaysFilter","TradeMonday","TradeTuesday","TradeWednesday","TradeThursday","TradeFriday","EnableRecoveryStepUp","RecoveryWaitMinutes","RecoveryMaxTotalLotsInBasket","CsvSchemaVersion"
    },
    FingerprintFields = {
        "FixedLots","Magic","PointsPerPip","PipsStep","TakeProfit","Tral","TralStart","MaxSpread",
        "TimeStart","TimeEnd","OpenTime","NewBasketDelaySeconds","SpeedEA","UseBasketTrailingTP",
        "TrailingStart","TrailingStep","KillSwitchEnable","KillEquityLevel","KillCooldownMinutes",
        "MaxOrdersInBasket","MaxTotalLotsInBasket","RegimeEnable","RegimeAction","RegimeADXPeriod",
        "RegimeADXLevel","RegimeADXBars","RegimeRangeBars","RegimeRecoveryBars","EnableTradingDaysFilter",
        "TradeMonday","TradeTuesday","TradeWednesday","TradeThursday","TradeFriday",
        "EnableRecoveryStepUp","RecoveryWaitMinutes","RecoveryMaxTotalLotsInBasket"
    },
    EmptyFolderFiles = #table(
        type table [Content = binary, Name = text, #"Folder Path" = text, #"Date modified" = datetime],
        {}
    ),
    GetFolderFiles = (FolderPath as text, Priority as number) as table =>
        let
            Loaded = try Table.Buffer(Folder.Files(FolderPath)) otherwise EmptyFolderFiles,
            WithPriority = Table.AddColumn(Loaded, "FolderPriority", each Priority, Int64.Type)
        in
            WithPriority,
    CanonicalFiles = GetFolderFiles(OneDriveRoot & "\amartrading", 0),
    LegacyFiles = GetFolderFiles(OneDriveRoot & "\AmmarTrading", 1),
    Files = Table.Combine({CanonicalFiles, LegacyFiles}),
    BasketFiles = Table.SelectRows(Files, each [Name] = "Baskets.csv"),
    WithFolderParts = Table.AddColumn(BasketFiles, "FolderParts", each Text.Split(Text.TrimEnd([Folder Path], "\"), "\")),
    WithFolderLogin = Table.AddColumn(WithFolderParts, "FolderAccountNumber", each let parts = [FolderParts], folder = List.Last(parts) in if Text.StartsWith(folder, "Account_") then Text.AfterDelimiter(folder, "Account_") else null, type text),
    WithFolderVps = Table.AddColumn(WithFolderLogin, "VpsId", each let parts = [FolderParts], parent = if List.Count(parts) >= 2 then parts{List.Count(parts)-2} else "" in if Text.StartsWith(parent, "VPS_") then Text.AfterDelimiter(parent, "VPS_") else "legacy-unassigned", type text),
    CanonicalAccounts = List.Buffer(Table.SelectRows(WithFolderLogin, each [FolderPriority] = 0)[FolderAccountNumber]),
    PreferredFiles = Table.SelectRows(WithFolderVps, each [FolderAccountNumber] <> null and ([VpsId] <> "legacy-unassigned" or [FolderPriority] = 0 or not List.Contains(CanonicalAccounts, [FolderAccountNumber]))),
    // OneDrive on Windows is case-insensitive, so amartrading and AmmarTrading can be the
    // same tree scanned twice. Keep the canonical (priority 0) path copy only.
    WithPathKey = Table.AddColumn(PreferredFiles, "PathKey", each Text.Lower(Text.TrimEnd([Folder Path], "\")) & "\" & Text.Lower([Name]), type text),
    PathDeduped = Table.Distinct(Table.Sort(WithPathKey, {{"FolderPriority", Order.Ascending}}), {"PathKey"}),
    // After Sync moves an account under VPS_*, the old flat Account_* folder often remains.
    // Refresh All must load only the newest Baskets.csv per MT4 login so Account Analysis
    // COUNTIFS/MATCH stop serving the stale flat snapshot.
    WithVpsRank = Table.AddColumn(PathDeduped, "VpsRank", each if [VpsId] = "legacy-unassigned" then 1 else 0, Int64.Type),
    WithDateModified = Table.AddColumn(WithVpsRank, "DateModified", each try [#"Date modified"] otherwise null),
    // Table.Distinct does not reliably preserve sort order on Excel 2019 / older mashup
    // engines, so group and take FirstN after an explicit per-account sort.
    GroupedByAccount = Table.Group(WithDateModified, {"FolderAccountNumber"}, {{"Candidates", each _, type table}}),
    LatestPerAccount = Table.Buffer(
        Table.RemoveColumns(
            Table.ExpandTableColumn(
                Table.AddColumn(
                    GroupedByAccount,
                    "Best",
                    each Table.FirstN(Table.Sort([Candidates], {{"DateModified", Order.Descending}, {"VpsRank", Order.Ascending}, {"FolderPriority", Order.Ascending}}), 1),
                    type table
                ),
                "Best",
                {"Content", "Name", "Folder Path", "Date modified", "FolderPriority", "FolderParts", "VpsId", "PathKey", "VpsRank", "DateModified"},
                {"Content", "Name", "Folder Path", "Date modified", "FolderPriority", "FolderParts", "VpsId", "PathKey", "VpsRank", "DateModified"}
            ),
            {"Candidates"}
        )
    ),
    ManifestFiles = Table.SelectRows(Files, each [Name] = "Vps.json"),
    ManifestRows = Table.AddColumn(ManifestFiles, "Manifest", each try Json.Document([Content]) otherwise [VpsName=""]),
    ManifestVps = Table.AddColumn(ManifestRows, "ManifestVpsId", each let parts = Text.Split(Text.TrimEnd([Folder Path], "\"), "\"), parent = if List.Count(parts) >= 1 then List.Last(parts) else "" in if Text.StartsWith(parent, "VPS_") then Text.AfterDelimiter(parent, "VPS_") else null, type text),
    ManifestNames = Table.Distinct(Table.SelectColumns(Table.AddColumn(ManifestVps, "ManifestVpsName", each Record.FieldOrDefault([Manifest], "VpsName", ""), type text), {"ManifestVpsId","ManifestVpsName"}), {"ManifestVpsId"}),
    WithManifest = Table.NestedJoin(LatestPerAccount, {"VpsId"}, ManifestNames, {"ManifestVpsId"}, "ManifestMatch", JoinKind.LeftOuter),
    WithVpsName = Table.ExpandTableColumn(WithManifest, "ManifestMatch", {"ManifestVpsName"}, {"VpsName"}),
    WithCsv = Table.AddColumn(WithVpsName, "Data", each
        try Table.SelectColumns(
            Table.PromoteHeaders(Csv.Document([Content], [Delimiter=",", Encoding=65001, QuoteStyle=QuoteStyle.Csv]), [PromoteAllScalars=true]),
            ExpectedColumns,
            MissingField.UseNull
        )
        otherwise #table(ExpectedColumns, {})
    ),
    NonEmptyCsv = Table.SelectRows(WithCsv, each Table.RowCount([Data]) > 0),
    Keep = Table.SelectColumns(NonEmptyCsv, {"FolderAccountNumber","VpsId","VpsName","Data"}),
    Expanded = Table.ExpandTableColumn(Keep, "Data", ExpectedColumns, ExpectedColumns),
    Typed = Table.TransformColumnTypes(Expanded, {
        {"FolderAccountNumber", type text},{"AccountNumber", type text},{"BasketID", Int64.Type},{"Timeframe", Int64.Type},
        {"StartTime", type datetime},{"EndTime", type datetime},{"DurationSeconds", Int64.Type},{"OrdersCount", Int64.Type},
        {"TotalLots", type number},{"FixedLots", type number},{"MaxOrdersConcurrent", Int64.Type},{"MaxTotalLots", type number},
        {"MaxFloatingDrawdownAbs", type number},{"MaxFloatingProfit", type number},{"ClosePL", type number},{"SpreadAtEntry", type number},
        {"EquityAtEntry", type number},{"HeadroomAtEntry", type number},{"MinHeadroom", type number},{"TimesNearKill", Int64.Type},
        {"ExposureBlocks", Int64.Type},{"PipsStep", Int64.Type},{"TakeProfit", type number},{"KillEquityLevel", type number},
        {"MaxOrdersInBasket", Int64.Type},{"MaxTotalLotsInBasket", type number},{"EquityAtExit", type number},{"BalanceAfter", type number},
        {"TradeDate", type date},{"RunID", type text},{"RunStartTime", type datetime},{"RunStartBalance", type number},{"Magic", Int64.Type},
        {"PointsPerPip", Int64.Type},{"Tral", Int64.Type},{"TralStart", Int64.Type},{"MaxSpread", Int64.Type},
        {"TimeStart", Int64.Type},{"TimeEnd", Int64.Type},{"OpenTime", Int64.Type},{"NewBasketDelaySeconds", Int64.Type},
        {"SpeedEA", Int64.Type},{"UseBasketTrailingTP", Int64.Type},{"TrailingStart", type number},{"TrailingStep", type number},
        {"KillSwitchEnable", Int64.Type},{"KillCooldownMinutes", Int64.Type},{"RegimeEnable", Int64.Type},{"RegimeAction", Int64.Type},
        {"RegimeADXPeriod", Int64.Type},{"RegimeADXLevel", type number},{"RegimeADXBars", Int64.Type},{"RegimeRangeBars", Int64.Type},
        {"RegimeRecoveryBars", Int64.Type},{"EnableTradingDaysFilter", Int64.Type},{"TradeMonday", Int64.Type},{"TradeTuesday", Int64.Type},
        {"TradeWednesday", Int64.Type},{"TradeThursday", Int64.Type},{"TradeFriday", Int64.Type},{"EnableRecoveryStepUp", Int64.Type},
        {"RecoveryWaitMinutes", Int64.Type},{"RecoveryMaxTotalLotsInBasket", type number},{"CsvSchemaVersion", Int64.Type}
    }, "en-US"),
    WithLegacyRunID = Table.ReplaceValue(Typed, null, "Legacy-v2", Replacer.ReplaceValue, {"RunID"}),
    // Account Analysis MATCH/XLOOKUP keys are AccountNumber|RunID (not VpsId).
    WithRunKey = Table.AddColumn(WithLegacyRunID, "RunKey", each [AccountNumber] & "|" & [RunID], type text),
    WithMismatch = Table.AddColumn(WithRunKey, "FolderAccountMismatch", each [FolderAccountNumber] <> [AccountNumber], type logical),
    WithConfigFingerprint = Table.AddColumn(WithMismatch, "ConfigFingerprint", (row) => Text.Combine(List.Transform(FingerprintFields, (field) => let value = Record.Field(row, field) in if value = null then "" else Text.From(value, "en-US")), "|"), type text),
    WithAccountKey = Table.AddColumn(WithConfigFingerprint, "AccountKey", each [VpsId] & "|" & [AccountNumber], type text),
    FinalColumns = List.Combine({ExpectedColumns, {"VpsId","VpsName","FolderAccountNumber","AccountKey","RunKey","FolderAccountMismatch","ConfigFingerprint"}}),
    Final = Table.ReorderColumns(WithAccountKey, FinalColumns, MissingField.UseNull)
in
    Final
