let
    OneDriveRoot = Text.Trim(Text.From(Excel.CurrentWorkbook(){[Name="OneDriveRoot"]}[Content]{0}[Column1])),
    FreshnessHours = 26,
    GetFolderFiles = (FolderPath as text, Priority as number) as table =>
        let
            Loaded = try Folder.Files(FolderPath) otherwise #table(type table [Content = binary, Name = text, #"Folder Path" = text], {}),
            WithPriority = Table.AddColumn(Loaded, "FolderPriority", each Priority, Int64.Type)
        in
            WithPriority,
    CanonicalFiles = GetFolderFiles(OneDriveRoot & "\AmarTrading", 0),
    LegacyFiles = GetFolderFiles(OneDriveRoot & "\AmmarTrading", 1),
    Files = Table.Combine({CanonicalFiles, LegacyFiles}),
    StatusFiles = Table.SelectRows(Files, each [Name] = "SyncStatus.json" and Text.StartsWith(List.Last(Text.Split(Text.TrimEnd([Folder Path], "\"), "\")), "Account_")),
    WithFolderLogin = Table.AddColumn(StatusFiles, "FolderAccountNumber", each Text.AfterDelimiter(List.Last(Text.Split(Text.TrimEnd([Folder Path], "\"), "\")), "Account_"), type text),
    CanonicalAccounts = List.Buffer(Table.SelectRows(WithFolderLogin, each [FolderPriority] = 0)[FolderAccountNumber]),
    PreferredFiles = Table.SelectRows(WithFolderLogin, each [FolderPriority] = 0 or not List.Contains(CanonicalAccounts, [FolderAccountNumber])),
    WithJson = Table.AddColumn(PreferredFiles, "StatusRecord", each Json.Document([Content])),
    Keep = Table.SelectColumns(WithJson, {"FolderAccountNumber","StatusRecord"}),
    Expanded = Table.ExpandRecordColumn(Keep, "StatusRecord", {"AccountNumber","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","CloudDeliveryVerified"}, {"AccountNumber","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","CloudDeliveryVerified"}),
    Typed = Table.TransformColumnTypes(Expanded, {{"FolderAccountNumber", type text},{"AccountNumber", type text},{"Status", type text},{"RowCount", Int64.Type},{"SourceHash", type text},{"DestinationHash", type text},{"SourceLastWriteUtc", type datetimezone},{"PublishedUtc", type datetimezone},{"CloudDeliveryVerified", type logical}}, "en-US"),
    WithMismatch = Table.AddColumn(Typed, "FolderAccountMismatch", each [FolderAccountNumber] <> [AccountNumber], type logical),
    WithAge = Table.AddColumn(WithMismatch, "HeartbeatAgeHours", each if [PublishedUtc] = null then null else Duration.TotalHours(DateTimeZone.UtcNow() - [PublishedUtc]), type number),
    WithFreshness = Table.AddColumn(WithAge, "IsFresh", each [Status] = "Success" and [HeartbeatAgeHours] <> null and [HeartbeatAgeHours] >= -0.0833 and [HeartbeatAgeHours] <= FreshnessHours, type logical),
    Final = Table.ReorderColumns(WithFreshness, {"AccountNumber","FolderAccountNumber","FolderAccountMismatch","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","HeartbeatAgeHours","IsFresh","CloudDeliveryVerified"})
in
    Final
