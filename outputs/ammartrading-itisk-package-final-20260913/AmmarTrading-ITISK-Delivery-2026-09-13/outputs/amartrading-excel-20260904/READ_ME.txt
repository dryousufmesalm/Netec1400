AmarTrading Excel Master - 2026-09-04

Open AmarTrading_Excel_Master_2026-09-04.xlsx in desktop Excel.
Enable editing and external data connections if Excel prompts you.
The OneDriveRoot value on Power Query Setup is already:
C:\Users\User\OneDrive

The live reporting folder is:
C:\Users\User\OneDrive\amartrading

Choose Data > Refresh All. No manual query creation or connection editing is required.

Embedded queries:
AmarTrading_Baskets -> Basket Data / BasketDataTable (75 columns)
AmarTrading_SyncStatus -> Sync Status / SyncStatusTable (12 columns)

Both connections use exactly these names. Retired query aliases and duplicate
connections have been removed. Refresh is manual so opening the file does not
start reading files before you can review your local OneDrive root.

The imported tables are intentionally blank in the delivered file. Test data
has been cleared; Refresh All loads your own locally synchronized CSV files.
The Manual Fields table and all 65 existing analytics formulas are preserved.

Validation: native Windows Excel 16.0, build 20326, successfully loaded four
synthetic account folders, then Refresh All loaded added rows (4 to 8 basket
rows; 4 status rows). The workbook package contains two embedded queries,
two matching connections and two correctly linked query tables.

This validates the workbook in the Windows test environment. Itsik's own
Excel installation and live account files still require receiver-side refresh.
