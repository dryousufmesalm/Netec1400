# MT4 CSV → OneDrive → Excel setup

This package is reporting-only. It changes no entry, grid, basket-management, trailing, exit, or risk decision. The target source is `AmmarTradingGoldEA - ref reset every bar - V3.mq4`; V2 and MQ5 remain untouched.

## 1. Deploy the MQ4 reporting update

1. Compile the latest V3 MQ4 source in MetaEditor and install the generated EX4 in the same MT4 terminal that writes `AGOLD___Baskets.csv`.
2. When the account is flat, back up the existing schema-v2 `AGOLD___Baskets.csv`, then delete/reset that working CSV once.
3. Start the EA. It creates a schema-v3 header and stores the current account balance/server time as the run-start snapshot.
4. Do not reset the CSV while a basket is open. If it is deleted then, the EA deliberately defers the new run until the basket is flat and skips the old basket's row rather than mixing runs.

The CSV stays in that terminal's `MQL4\Files` sandbox. It is appended only at basket close and closed immediately, which is why the sync script can copy it safely.

## 2. Configure one VPS/account

### Recommended: use the Arabic setup wizard

For a non-technical operator, use this five-step flow on the VPS being added:

1. Sign in to the Windows OneDrive app with the dedicated Money Machine uploader identity. Share/access only the central `MoneyMachine` reporting folder; do not use a personal OneDrive identity on VPS machines.
2. Copy the complete `automation\MoneyMachineCsvSync` folder to a durable local directory on that VPS.
3. Double-click `Start-MoneyMachineSyncWizard.cmd`. The wizard runs only on `127.0.0.1`, opens in the default browser, and does not require Node.js.
4. Enter a friendly VPS name and MT4 account number. Choose the detected `AGOLD___Baskets.csv` and OneDrive root, then click **إعداد المزامنة الآن**.
5. Keep the final destination shown by the wizard. On the reporting device, wait for OneDrive and run the receiver check in section 6 before treating cloud delivery as confirmed.

The wizard validates the schema/account before changing configuration, creates a timestamped backup of an existing `accounts.csv`, performs the first local publication, and only then installs the daily and logon catch-up tasks. It never asks for or stores Microsoft, RDP, broker, or MT4 passwords. If the first publication fails, it restores the prior configuration. If task registration fails after publication, it reports partial setup rather than claiming automation is active.

The local wizard API accepts only its three setup routes, binds to IPv4 loopback, requires a strict session cookie, validates Host/Origin, and caps JSON bodies at 64 KiB. Close the wizard window after setup; no external firewall or router port is required.

### Manual fallback

Copy the complete `automation\MoneyMachineCsvSync` folder to a durable local directory on the VPS. Edit `accounts.csv`:

```csv
Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot
true,VPS London 01,892522910,C:\\Path\\To\\MT4\\MQL4\\Files\\AGOLD___Baskets.csv,C:\\Users\\YourWindowsUser\\OneDrive
```

- `ExpectedMT4Login` must equal the `AccountNumber` inside the CSV. The script treats the CSV value as authoritative and refuses a mismatch.
- `OneDriveRoot` is the local folder already synchronized by the Windows user running the task.
- The destination is `OneDriveRoot\AmarTrading\Account_<MT4Login>\Baskets.csv`.

Run a manual first copy:

```powershell
.\Sync-BasketsToOneDrive.ps1 -ConfigPath .\accounts.csv
```

The script verifies a stable source, validates every schema-v3 field and basket key, copies to a temporary file, validates it again, and atomically replaces only the latest destination. It creates no daily archives. Logs contain only status/error information in `logs\sync.log`; each log is capped at 5 MiB with five retained rotations. Per-account `SyncStatus.json` and local `state\last-run.json` provide machine-readable status without claiming cloud delivery.

## 3. Install the daily tasks

Run PowerShell as the same Windows user that owns the OneDrive sync:

```powershell
.\Install-BasketsSyncTask.ps1 -ConfigPath .\accounts.csv -DailyTime '23:59'
```

This idempotently creates two tasks: a daily copy at 23:59 VPS local time and a logon/startup catch-up task. The catch-up copies only accounts that did not complete successfully that day.

## 4. Add future VPSs/accounts

No development is needed. On each new VPS, sign in to the dedicated uploader identity, copy this same folder, and double-click `Start-MoneyMachineSyncWizard.cmd`. Reusing the same central OneDrive root is safe because every login gets its own `Account_<MT4Login>` folder. For the manual fallback, add one `accounts.csv` row, test the manual copy, then run the installer.

## 5. Use the Excel workbook

Open `MoneyMachine_Account_Analysis.xlsx`. It is prewired with `MoneyMachine_Baskets` and `MoneyMachine_SyncStatus` Power Query connections and remains fully editable: no macros, locked cells, hidden calculations, or proprietary component.

1. On **Power Query Setup**, change cell `B4` (`OneDrive root`) to the reporting machine's local OneDrive folder.
2. Use **Data → Refresh All**. Both queries refresh synchronously; background refresh is disabled so formulas do not calculate against half-refreshed data.
3. **Basket Data** contains the 71 CSV columns followed by folder account, run key, mismatch flag, and the culture-invariant 37-field configuration fingerprint.
4. **Sync Status** displays every received heartbeat, its age, and `IsFresh`. The freshness SLO is 26 hours.
5. Use **Manual Fields** for Name, Account Type, Server/VPS, MT4 label, and Notes. Those values are intentionally editable and separate from MT4 data.
6. For an additional account/run, add its Account # and Run ID to the next row of **Account Analysis** and copy row 5 across/down. All KPI formulas use the CSV cumulatively for that run.

For a legacy v2 input only, the workbook labels the run `Legacy-v2`. Schema-v3 rows provide the automatic `RunStartBalance` liquidity value and distinguish each reset by `RunID`.

If either connection must be recreated, run `Install-MoneyMachineWorkbookQueries.ps1` against a backup copy of the workbook, or create Blank Queries from `PowerQuery\MoneyMachine_Baskets.m` and `PowerQuery\MoneyMachine_SyncStatus.m`. Load them to `BasketDataTable` on **Basket Data** and `SyncStatusTable` on **Sync Status**, with refresh-on-open enabled and background refresh disabled.

## 6. Verify delivery from the reporting machine

Local publication on the VPS is not cloud proof. On the receiving Windows machine, run:

```powershell
.\Test-MoneyMachineSyncStatus.ps1 -OneDriveRoot $env:OneDrive -ExpectedAccount 36097370 -FreshnessHours 26
```

Exit code `0` means the heartbeat reached that receiver and is fresh. A missing, malformed, unsuccessful, future-dated, or stale heartbeat returns nonzero. Confirm the same account reports `IsFresh=true` after refreshing the workbook.

## 7. Run production acceptance before declaring readiness

Use a task-specific staging directory and require the installed Windows products that are part of the release:

```powershell
.\tests\Run-WindowsProductionAcceptance.ps1 `
  -StagingRoot 'C:\CodexWorker\MoneyMachine-Acceptance' `
  -MetaEditorPath 'C:\Program Files (x86)\MetaTrader 4\metaeditor.exe' `
  -WorkbookPath '.\outputs\019fe209-a32e-7040-84de-fe9e289219a5\MoneyMachine_Account_Analysis.xlsx' `
  -RequireMetaEditor `
  -RequireExcel
```

The runner returns `0` only when every required check passes, `1` for a failed check, and `3` when a caller-required optional product is unavailable. It writes an atomic, redacted `audit\windows-production-acceptance.json` under the staging root. Review `OverallStatus`, every named check, and every artifact hash; do not treat the staging publication as production or cloud-delivery evidence.

## 8. Deploy side-by-side and preserve rollback

Before changing either scheduled task:

1. Export both existing task XML definitions.
2. Back up the current automation directory, `accounts.csv`, `state`, logs, destination `Baskets.csv`, `SyncStatus.json`, and any existing workbook.
3. Create a SHA-256 manifest for the rollback bundle.
4. Copy the reviewed automation into a versioned side-by-side directory; never overwrite the old automation in place.
5. Copy the production `accounts.csv` without logging its contents, then verify the deployed scripts and queries against their reviewed hashes.
6. Run the installer from the Windows user that owns OneDrive. Inspect the final principal, absolute executable/script/config paths, working directory, triggers, `IgnoreNew`, three retries, five-minute retry interval, and 15-minute execution limit.

For rollback, disable the remediated tasks, restore the saved XML definitions and prior workbook, and verify that the last known-good destination CSV is unchanged. After the rollback check, reapply the remediated definitions. If no prior workbook existed, keep the new workbook but record that workbook restoration was not applicable.

## 9. Interpret alerts and recover the workbook

- `SyncStatus.json` missing: no successful local publication has reached that folder yet.
- `Status` other than `Success`: the publisher rejected or could not copy the source.
- `IsFresh=false` or receiver checker nonzero: treat reporting as stale; inspect the task result, `state\last-run.json`, and `logs\sync.log` before using the workbook.
- `CloudDeliveryVerified=true` in a publisher heartbeat: treat it as invalid. Only a receiver-side check can establish delivery.
- Source and destination hashes differ: preserve the current destination and investigate; do not replace it manually.
- Workbook query/table missing or damaged: restore the rollback workbook or run `Install-MoneyMachineWorkbookQueries.ps1` against a backup copy, then refresh and recheck the account, run ID, fingerprint, heartbeat age, and freshness.

Logs and state deliberately omit credentials. Do not paste `accounts.csv`, personal OneDrive paths, or task XML into shared acceptance reports.

## 10. Production-ready decision rule

Call the integration **production-ready** only when all of the following are true:

1. The Windows acceptance JSON is `Pass`, including required MetaEditor and Excel checks.
2. Both remediated tasks point to the reviewed side-by-side directory and a triggered positive run returns `0`.
3. An isolated missing-source Scheduled Task returns nonzero, and rollback/reapply has preserved the known-good destination.
4. Local source, destination, heartbeat, state, row count, account, and timestamps agree. Label this only `LocalPublished`.
5. A separate receiver or OneDrive web observation confirms the same fresh heartbeat and hashes within 30 minutes.
6. The receiver workbook refresh shows the expected account/run, 37-field fingerprint, matching row count, and `IsFresh=true`.
7. The reporting-only V3 MQ4/EX4 has been installed in the live MT4 terminal and its future CSV rows use schema v3 with escaped text fields.
8. The next scheduled 23:59 cycle returns `0`, remains receiver-fresh, and refreshes successfully in Excel.

Until every item passes, report the rollout as **conditionally deployed**, retain the rollback bundle and previous automation, and do not remove rollback eligibility.
