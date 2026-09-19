# AmarTrading Excel / Power Query handoff

The VPS sync is live and writing to:

`C:\Users\Administrator\OneDrive\amartrading`

The package contains the existing Master Analytics workbook and the current Power Query M sources. The queries prefer `amartrading` and keep `AmmarTrading` as a legacy fallback.

## On the reporting PC

1. Copy the workbook to a local folder.
2. Open it in desktop Excel.
3. Set the `OneDriveRoot` named value on **Power Query Setup** to the local OneDrive root.
4. Refresh All.

Excel desktop is not installed on the VPS, so a real Excel refresh cannot be performed there. The VPS-side sync was validated separately: four account folders exist, all four `SyncStatus.json` files report `Success`, scheduled tasks are `Ready`, and `AmmarTrading.Sync` is running.
