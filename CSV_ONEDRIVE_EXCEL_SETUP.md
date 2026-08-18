# MT4 CSV → OneDrive → Excel setup

This package is reporting-only. It changes no entry, grid, basket-management, trailing, exit, or risk decision. The target source is `AmmarTradingGoldEA - ref reset every bar - V3.mq4`; V2 and MQ5 remain untouched.

## 1. Deploy the MQ4 reporting update

1. Compile the latest V3 MQ4 source in MetaEditor and install the generated EX4 in the same MT4 terminal that writes `AGOLD___Baskets.csv`.
2. When the account is flat, back up the existing schema-v2 `AGOLD___Baskets.csv`, then delete/reset that working CSV once.
3. Start the EA. It creates a schema-v3 header and stores the current account balance/server time as the run-start snapshot.
4. Do not reset the CSV while a basket is open. If it is deleted then, the EA deliberately defers the new run until the basket is flat and skips the old basket's row rather than mixing runs.

The CSV stays in that terminal's `MQL4\Files` sandbox. It is appended only at basket close and closed immediately, which is why the sync script can copy it safely.

## 2. Configure one VPS/account

Copy the complete `automation\MoneyMachineCsvSync` folder to a durable local directory on the VPS. Edit `accounts.csv`:

```csv
Enabled,ExpectedMT4Login,SourceCsv,OneDriveRoot
true,892522910,C:\\Path\\To\\MT4\\MQL4\\Files\\AGOLD___Baskets.csv,C:\\Users\\YourWindowsUser\\OneDrive
```

- `ExpectedMT4Login` must equal the `AccountNumber` inside the CSV. The script treats the CSV value as authoritative and refuses a mismatch.
- `OneDriveRoot` is the local folder already synchronized by the Windows user running the task.
- The destination is `OneDriveRoot\MoneyMachine\Account_<MT4Login>\Baskets.csv`.

Run a manual first copy:

```powershell
.\Sync-BasketsToOneDrive.ps1 -ConfigPath .\accounts.csv
```

The script verifies a stable source, validates the header and login, copies to a temporary file, validates it again, and finally overwrites only the latest destination. It creates no daily archives. Logs contain only status/error information in `logs\sync.log`.

## 3. Install the daily tasks

Run PowerShell as the same Windows user that owns the OneDrive sync:

```powershell
.\Install-BasketsSyncTask.ps1 -ConfigPath .\accounts.csv -DailyTime '23:59'
```

This idempotently creates two tasks: a daily copy at 23:59 VPS local time and a logon/startup catch-up task. The catch-up copies only accounts that did not complete successfully that day.

## 4. Add future VPSs/accounts

No development is needed. Install OneDrive and this same folder on the new VPS, point one new `accounts.csv` row to that terminal's `MQL4\Files\AGOLD___Baskets.csv`, test the manual copy, then run the installer. Reusing the same central OneDrive root is safe because every login gets its own `Account_<MT4Login>` folder.

## 5. Use the Excel workbook

Open `MoneyMachine_Account_Analysis.xlsx`. It includes the supplied sample CSV as a working baseline and remains fully editable: no macros, locked cells, hidden calculations, or proprietary component.

1. On **Power Query Setup**, change `OneDrive root` and copy the displayed M code (also saved as `PowerQuery\MoneyMachine_Baskets.m`).
2. In Excel, use **Data → Get Data → From Other Sources → Blank Query → Advanced Editor**, paste the code, change `OneDriveRoot`, and load the result into **Basket Data**.
3. Refresh All whenever you want current data. The query normalizes v2/v3 columns, checks folder/account mismatches, and preserves all schema-v3 settings.
4. Use **Manual Fields** for Name, Account Type, Server/VPS, MT4 label, and Notes. Those values are intentionally editable and separate from MT4 data.
5. For an additional account/run, add its Account # and Run ID to the next row of **Account Analysis** and copy row 5 across/down. All KPI formulas use the CSV cumulatively for that run.

For a legacy v2 input only, the workbook labels the run `Legacy-v2`. Schema-v3 rows provide the automatic `RunStartBalance` liquidity value and distinguish each reset by `RunID`.
