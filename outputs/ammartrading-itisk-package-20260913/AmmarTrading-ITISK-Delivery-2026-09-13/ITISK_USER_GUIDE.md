# AmmarTrading ITISK User Guide

## 1. What you received

The delivery has two operating parts:

1. **MT4 Gold EA** — manages a single-direction XAUUSD basket with controlled grid/recovery, basket take profit, drawdown controls, margin protection, spread and volatility filters.
2. **AmmarTrading Sync and Excel workflow** — publishes basket CSV files, synchronizes them through the configured OneDrive folder, and imports them into the Excel analytics workbook.

## 2. First use of the MT4 EA

1. Install MetaTrader 4 and open **File → Open Data Folder**.
2. Copy `Netec1400_XAUUSD_Grid.mq4` into `MQL4/Experts/`.
3. Open MetaEditor, open the MQ4 file, and press **F7**.
4. Confirm that compilation creates the `.ex4` file without errors.
5. Open an XAUUSD chart, preferably on a demo account, and attach the EA.
6. Start with `EntryMode=0` (manual adopt mode). Place the first test order yourself; the EA should adopt and manage it.
7. Confirm the symbol, MagicNumber, lot size, grid distance, maximum levels, spread limit, margin limit, and emergency drawdown settings.
8. Keep live trading disabled until Strategy Tester and demo checks pass.

The EA manages one direction per basket. Do not mix BUY and SELL orders under the same basket. `EntryMode=1` is semi-auto mode and still requires the configured basket direction; indicator suggestions do not independently authorize a live trade in Phase 1.

## 3. Daily monitoring

Check the MT4 Experts and Journal tabs for initialization, filter blocks, order retries, basket changes, and emergency actions. Review open levels, basket profit/loss, free margin, spread, and drawdown. Stop the EA and investigate if the symbol is wrong, orders are duplicated, the platform reports repeated trade errors, or margin approaches the configured protection threshold.

## 4. Sync and Excel workflow

1. Confirm the configured OneDrive root and account folder mapping.
2. Run the AmmarTrading Sync wizard or the documented PowerShell setup from `CSV_ONEDRIVE_EXCEL_SETUP.md`.
3. Verify that each expected account writes `Baskets.csv` and `SyncStatus.json`.
4. Wait for OneDrive to finish syncing and verify the file on the reporting PC.
5. Open the supplied Excel workbook.
6. Use **Data → Refresh All** only after the reporting PC has received the fresh files.
7. Review the imported row count, account/run groups, totals, and refresh timestamp.

The workbook refresh is a separate acceptance step. A local VPS file or a successful sync task does not prove that the reporting PC received the file.

## 5. Testing sequence

Use this order:

1. Compile/source checks.
2. MT4 Strategy Tester scenarios from `TESTING_GUIDE.md`.
3. At least one to two weeks of demo observation.
4. VPS-local sync acceptance.
5. Reporting-PC physical receipt and hash acceptance.
6. Excel Refresh All and saved-workbook review.
7. Production approval and code signing.

Do not skip directly to live trading. A healthy MT4 connection, a successful script run, or a workbook opening is not execution or cross-device delivery proof.

## 6. Troubleshooting

**EA does not trade:** check AutoTrading, chart symbol, trading hours, spread, volatility, drawdown, margin, and EntryMode. In manual adopt mode, the first order must match the symbol, direction, and MagicNumber rules.

**Grid does not add a level:** check grid distance, maximum levels, drawdown pause, exposure pause, impulse/volatility filters, free margin, and broker restrictions.

**Excel shows old data:** check `SyncStatus.json`, OneDrive sync state, the exact reporting-PC folder, file timestamps and hashes, then run Refresh All. Do not repeatedly republish before confirming the path mapping.

**Workbook formulas show errors:** use the Excel 2019 compatible workbook in `outputs/ammar-excel2019-repair-20260909/`, review `final-verification.json`, and follow `CSV_ONEDRIVE_EXCEL_SETUP.md`. Copy an existing analysis row if a future refresh introduces a new account/run pair.

## 7. Main references

- EA setup: `INSTALLATION_GUIDE.md`
- EA parameters: `PARAMETER_GUIDE.md`
- Testing: `TESTING_GUIDE.md`
- Sync and Excel: `CSV_ONEDRIVE_EXCEL_SETUP.md`
- Common questions: `FAQ.md`
- Full file index: `INDEX.md`

