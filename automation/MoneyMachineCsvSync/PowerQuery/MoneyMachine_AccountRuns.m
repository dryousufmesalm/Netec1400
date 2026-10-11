let
    // Distinct account/run keys from the live Baskets query so Account Analysis
    // rows track Refresh All without hosting any Power Query overwrite range.
    Source = AmarTrading_Baskets,
    Keep = Table.SelectColumns(Source, {"AccountNumber", "RunID", "RunKey"}, MissingField.UseNull),
    NonBlank = Table.SelectRows(Keep, each [AccountNumber] <> null and [AccountNumber] <> "" and [RunID] <> null and [RunID] <> ""),
    Distinct = Table.Distinct(NonBlank),
    Sorted = Table.Sort(Distinct, {{"AccountNumber", Order.Ascending}, {"RunID", Order.Ascending}})
in
    Sorted
