let
    OneDriveRoot = Text.Trim(Text.From(Excel.CurrentWorkbook(){[Name="OneDriveRoot"]}[Content]{0}[Column1])),
    FreshnessHours = 26,
    Files = Folder.Files(OneDriveRoot & "\MoneyMachine"),
    StatusFiles = Table.SelectRows(Files, each [Name] = "SyncStatus.json" and Text.StartsWith(List.Last(Text.Split(Text.TrimEnd([Folder Path], "\"), "\")), "Account_")),
    WithFolderLogin = Table.AddColumn(StatusFiles, "FolderAccountNumber", each Text.AfterDelimiter(List.Last(Text.Split(Text.TrimEnd([Folder Path], "\"), "\")), "Account_"), type text),
    WithJson = Table.AddColumn(WithFolderLogin, "StatusRecord", each Json.Document([Content])),
    Keep = Table.SelectColumns(WithJson, {"FolderAccountNumber","StatusRecord"}),
    Expanded = Table.ExpandRecordColumn(Keep, "StatusRecord", {"AccountNumber","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","CloudDeliveryVerified"}, {"AccountNumber","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","CloudDeliveryVerified"}),
    Typed = Table.TransformColumnTypes(Expanded, {{"FolderAccountNumber", type text},{"AccountNumber", type text},{"Status", type text},{"RowCount", Int64.Type},{"SourceHash", type text},{"DestinationHash", type text},{"SourceLastWriteUtc", type datetimezone},{"PublishedUtc", type datetimezone},{"CloudDeliveryVerified", type logical}}, "en-US"),
    WithMismatch = Table.AddColumn(Typed, "FolderAccountMismatch", each [FolderAccountNumber] <> [AccountNumber], type logical),
    WithAge = Table.AddColumn(WithMismatch, "HeartbeatAgeHours", each if [PublishedUtc] = null then null else Duration.TotalHours(DateTimeZone.UtcNow() - [PublishedUtc]), type number),
    WithFreshness = Table.AddColumn(WithAge, "IsFresh", each [Status] = "Success" and [HeartbeatAgeHours] <> null and [HeartbeatAgeHours] >= -0.0833 and [HeartbeatAgeHours] <= FreshnessHours, type logical),
    Final = Table.ReorderColumns(WithFreshness, {"AccountNumber","FolderAccountNumber","FolderAccountMismatch","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","HeartbeatAgeHours","IsFresh","CloudDeliveryVerified"})
in
    Final
