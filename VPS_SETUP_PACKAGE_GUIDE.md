# amarTrading New VPS Setup Package

This package contains only operational files for configuring a new Windows VPS. It does not contain MT4/MQL source code, C# source, JavaScript source, tests, Git files, or development dependencies.

## Included files

- `MT4/AmmarTradingGoldEA - ref reset every bar - V3.ex4` — compiled MT4 Expert Advisor.
- `Sync/amarTrading.Sync.exe` — self-contained Windows sync application.
- `Sync/` — operational PowerShell modules, sync tasks, wizard launcher, built wizard assets, Power Query modules, and the blank `accounts.csv` template.
- `Excel/AmarTrading_Excel2019_Compatible.xlsx` — verified Excel 2019 compatible workbook.
- `Excel/CSV_ONEDRIVE_EXCEL_SETUP.md` — detailed sync and workbook instructions.
- `Excel/CLIENT_CSV_SCHEMA.md` — CSV format reference.

## New VPS setup

1. Install MetaTrader 4 and sign in to the intended trading account.
2. Copy the compiled EX4 into the terminal's `MQL4\Experts` folder. Use **File → Open Data Folder** in MT4 to find the correct terminal.
3. Restart MT4 or refresh Navigator, attach the EA to the XAUUSD chart, and confirm the required inputs. Test on demo first.
4. Sign in to the approved OneDrive desktop account on the VPS. Do not enable Desktop/Documents/Pictures backup for this server.
5. The GUI stores the VPS name, expected MT4 login, source CSV path, local OneDrive root, and selected reporting folder in `Sync\accounts.csv`. The default reporting folder is `OneDrive\amartrading`.
6. Run PowerShell as the same Windows user that owns OneDrive:

```powershell
Set-Location 'C:\AmmarTradingVpsSetup\Sync'
.\Install-BasketsSyncTask.ps1 -ConfigPath .\accounts.csv -DailyTime '23:59'
.\Sync-BasketsToOneDrive.ps1 -ConfigPath .\accounts.csv
```

7. Check that the selected reporting folder contains the VPS/account path ending in `Account_<MT4Login>\Baskets.csv` and `SyncStatus.json`.
8. On the reporting PC, copy `Excel\AmarTrading_Excel2019_Compatible.xlsx`, set its OneDrive root in the workbook setup area, then use **Data → Refresh All** after the reporting PC receives the VPS files.

## Start the sync app

Double-click `Sync\amarTrading.Sync.exe`. On first launch, complete the system check, select the Ready MT4 account, choose the signed-in OneDrive root, keep `amartrading` or click **Choose folder**, validate the selection, and apply setup. The app stores logs, configuration, and WebView2 data under `%LOCALAPPDATA%\amarTrading\Sync`.

Microsoft Edge WebView2 Runtime must be installed on the VPS. If the app reports that WebView2 is unavailable, install the Microsoft Evergreen WebView2 Runtime, then start the app again.

## Optional script wizard

Run `Sync\Start-MoneyMachineSyncWizard.cmd` from the package's `Sync` folder. The wizard discovers eligible schema-v3 MT4 CSV files, validates the selected account, previews the OneDrive destination, and applies the mapping. It does not request broker, MT4, Microsoft, or RDP passwords.

## Important checks

- The EA is for MT4/XAUUSD and must be tested on demo before live use.
- `CloudDeliveryVerified=false` proves VPS-local publication only. Verify OneDrive receipt separately on the reporting PC.
- Do not manually edit a generated `Baskets.csv` to bypass validation.
- Keep `accounts.csv`, logs, task definitions, and OneDrive data backed up before changing an existing VPS.
- The Excel workbook is reporting-only and does not change trading decisions.
