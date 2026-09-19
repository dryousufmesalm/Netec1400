let
    OneDriveRoot = Text.Trim(Text.From(Excel.CurrentWorkbook(){[Name="OneDriveRoot"]}[Content]{0}[Column1])),
    FreshnessHours = 26,
    GetFolderFiles = (FolderPath as text, Priority as number) as table =>
        let
            Loaded = try Table.Buffer(Folder.Files(FolderPath)) otherwise #table(type table [Content = binary, Name = text, #"Folder Path" = text], {}),
            WithPriority = Table.AddColumn(Loaded, "FolderPriority", each Priority, Int64.Type)
        in
            WithPriority,
    CanonicalFiles = GetFolderFiles(OneDriveRoot & "\amartrading", 0),
    LegacyFiles = GetFolderFiles(OneDriveRoot & "\AmmarTrading", 1),
    Files = Table.Combine({CanonicalFiles, LegacyFiles}),
    StatusFiles = Table.SelectRows(Files, each [Name] = "SyncStatus.json"),
    WithFolderParts = Table.AddColumn(StatusFiles, "FolderParts", each Text.Split(Text.TrimEnd([Folder Path], "\"), "\")),
    WithFolderLogin = Table.AddColumn(WithFolderParts, "FolderAccountNumber", each let parts = [FolderParts], folder = List.Last(parts) in if Text.StartsWith(folder, "Account_") then Text.AfterDelimiter(folder, "Account_") else null, type text),
    WithFolderVps = Table.AddColumn(WithFolderLogin, "VpsId", each let parts = [FolderParts], parent = if List.Count(parts) >= 2 then parts{List.Count(parts)-2} else "" in if Text.StartsWith(parent, "VPS_") then Text.AfterDelimiter(parent, "VPS_") else "legacy-unassigned", type text),
    CanonicalAccounts = List.Buffer(Table.SelectRows(WithFolderLogin, each [FolderPriority] = 0)[FolderAccountNumber]),
    PreferredFiles = Table.SelectRows(WithFolderVps, each [FolderAccountNumber] <> null and ([VpsId] <> "legacy-unassigned" or [FolderPriority] = 0 or not List.Contains(CanonicalAccounts, [FolderAccountNumber]))),
    WithJson = Table.AddColumn(PreferredFiles, "StatusRecord", each Json.Document([Content])),
    WithHeartbeatName = Table.AddColumn(WithJson, "HeartbeatVpsName", each Record.FieldOrDefault([StatusRecord], "VpsName", ""), type text),
    Keep = Table.SelectColumns(WithHeartbeatName, {"FolderAccountNumber","VpsId","HeartbeatVpsName","StatusRecord"}),
    Expanded = Table.ExpandRecordColumn(Keep, "StatusRecord", {"AccountNumber","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","CloudDeliveryVerified"}, {"AccountNumber","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","CloudDeliveryVerified"}),
    Typed = Table.TransformColumnTypes(Expanded, {{"FolderAccountNumber", type text},{"AccountNumber", type text},{"Status", type text},{"RowCount", Int64.Type},{"SourceHash", type text},{"DestinationHash", type text},{"SourceLastWriteUtc", type datetimezone},{"PublishedUtc", type datetimezone},{"CloudDeliveryVerified", type logical},{"HeartbeatVpsName", type text}}, "en-US"),
    WithVpsName = Table.RenameColumns(Typed, {{"HeartbeatVpsName", "VpsName"}}),
    WithAccountKey = Table.AddColumn(WithVpsName, "AccountKey", each [VpsId] & "|" & [AccountNumber], type text),
    WithMismatch = Table.AddColumn(WithAccountKey, "FolderAccountMismatch", each [FolderAccountNumber] <> [AccountNumber], type logical),
    WithAge = Table.AddColumn(WithMismatch, "HeartbeatAgeHours", each if [PublishedUtc] = null then null else Duration.TotalHours(DateTimeZone.UtcNow() - [PublishedUtc]), type number),
    WithFreshness = Table.AddColumn(WithAge, "IsFresh", each [Status] = "Success" and [HeartbeatAgeHours] <> null and [HeartbeatAgeHours] >= -0.0833 and [HeartbeatAgeHours] <= FreshnessHours, type logical),
    Final = Table.ReorderColumns(WithFreshness, {"VpsId","VpsName","AccountKey","AccountNumber","FolderAccountNumber","FolderAccountMismatch","Status","RowCount","SourceHash","DestinationHash","SourceLastWriteUtc","PublishedUtc","HeartbeatAgeHours","IsFresh","CloudDeliveryVerified"})
in
    Final
