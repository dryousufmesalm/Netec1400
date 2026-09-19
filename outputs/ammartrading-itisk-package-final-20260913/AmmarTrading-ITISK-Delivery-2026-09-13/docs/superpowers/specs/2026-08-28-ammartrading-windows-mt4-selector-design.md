# AmmarTrading Sync Windows App and MT4 Selector Design

## Goal

Replace the browser-launched setup wizard with an installable Windows desktop application named **AmmarTrading Sync**. The app must let a non-technical VPS operator discover and select one or more MT4 accounts, validate their schema-v3 basket CSV files, connect them to the signed-in OneDrive folder, run an end-to-end publication test, and keep the sync active after Windows restarts.

The app runs on every source VPS. The reporting PC remains a OneDrive consumer and Excel/Power Query reads the CSV files from its local OneDrive copy.

## Approved product decisions

- Delivery: a Windows installer, not a portable folder.
- Product name: `AmmarTrading Sync` (two `m` characters in `AmmarTrading`).
- Language: English, left-to-right.
- MT4 selection: multiple accounts can be selected in one setup run.
- Primary identity: show accounts by trading account number and broker rather than exposing filesystem paths.
- Target users: non-technical Windows/VPS operators.

## Recommended architecture

Use a self-contained .NET Windows desktop host with a WPF window and Microsoft Edge WebView2 for the existing React user interface.

- WPF owns application lifecycle, native dialogs, elevation boundaries, process execution, and Windows integration.
- WebView2 renders bundled local React assets inside the application window. It does not open Edge and does not start an HTTP listener.
- A narrow typed message bridge connects the React screens to native operations. The bridge permits a fixed set of commands and validates every request in the host.
- The current PowerShell sync and schema-validation modules remain the publication engine initially. The host invokes scripts with argument arrays, never command-string evaluation.
- Publish the .NET host self-contained for Windows x64 so no separate .NET installation is required.
- Build `AmmarTrading Sync Setup.exe` with an installer that creates Start Menu and optional desktop shortcuts, registers uninstall information, and checks for the WebView2 Evergreen Runtime. If missing, the installer runs Microsoft's Evergreen bootstrapper.

This approach reuses the approved UI and hardened sync logic while presenting a real Windows application. A complete native WPF rewrite would duplicate the React UI, and Electron would create a substantially larger package and a second browser runtime to service.

## User flow

### 1. System Check

The app checks:

- Windows and PowerShell compatibility.
- OneDrive is installed, signed in, and has a writable local root.
- MT4 terminal data roots are accessible.
- Scheduled Tasks are available.
- WebView2 and application files are healthy.

Each check has a plain-English result and a corrective action. Microsoft credentials are never requested, stored, or logged.

### 2. Select MT4 Accounts

Discovery scans the current Windows user's MT4 data roots below `%APPDATA%\MetaQuotes\Terminal` and identifies terminal instances using their terminal data directory and `origin.txt` installation metadata when available. It searches only expected MT4 file locations for `AGOLD___Baskets.csv` and does not recursively scan unrelated drives.

Each account card shows:

- Account number from the schema-v3 CSV.
- Broker name from the schema-v3 CSV.
- MT4 installation name or executable location when available.
- Terminal identifier as secondary diagnostic text.
- CSV schema version.
- Last CSV write time and freshness state.
- Ready, warning, or blocked status.
- A selection checkbox.

The account number and broker in a valid CSV row are authoritative. A header-only CSV can be shown as `Waiting for first basket`, but cannot be enabled until the app can prove its account identity. Schema-v2 or malformed CSV files remain visible with a clear blocked explanation and are never configured as schema-v3 sources.

The page includes `Refresh` and `Browse manually` actions. Manual browse is restricted to CSV files, runs the same validation, and cannot bypass account or schema checks.

Duplicate discoveries for the same account are not silently merged. The app marks them as a conflict and asks the operator to choose the terminal whose CSV is current.

### 3. OneDrive and Folder Setup

The app lists signed-in local OneDrive roots and recommends the personal/business root already active for the Windows user. The operator chooses a root only when more than one is available.

For every selected account, the destination is:

```text
<OneDriveRoot>\AmmarTrading\Account_<AccountNumber>\Baskets.csv
```

The screen previews all account-to-destination mappings without requiring path editing.

The app recognizes legacy `Money Machine` and `AmarTrading` reporting folders. When legacy data exists, it offers a safe one-time migration: copy historical files into `AmmarTrading`, verify the copy, switch configuration only after verification, and leave the legacy folder untouched. Deletion of legacy data is outside this workflow.

### 4. Test Synchronization

Before changing production configuration, the app validates every selected source. It then:

1. Backs up the existing configuration once.
2. Writes all selected mappings atomically.
3. Publishes each account's CSV locally into its OneDrive destination.
4. Verifies destination existence, schema, account identity, size, and content hash.
5. Registers or updates the recurring sync task and logon/startup catch-up.
6. Re-reads task state and last-run result.

The UI reports source validation, local OneDrive publication, and task activation separately. It must not claim remote cloud delivery merely because a file exists in the local OneDrive folder. OneDrive cloud state is displayed as `Pending OneDrive`, `OneDrive running`, or an equivalent locally observable state; physical arrival on the reporting PC remains a separate acceptance check.

### 5. Finish and Monitoring

The finish screen summarizes each configured account, exact destination, last successful publication, and automation state. It provides:

- `Open AmmarTrading Folder`.
- `Run Sync Now`.
- `View Status`.
- `Add Another MT4 Account`.
- `Export Support Report` with secrets and unrelated personal paths excluded.

Opening the installed app after setup shows the monitoring view first. Re-running setup updates selected accounts without deleting other configured accounts.

## Native bridge contract

The React application can request only these host operations:

- `getSystemStatus`
- `discoverMt4Accounts`
- `browseForCsv`
- `getOneDriveRoots`
- `getConfiguredAccounts`
- `validateSelection`
- `applySetup`
- `runSyncNow`
- `openReportingFolder`
- `exportSupportReport`

Every request includes an ID and version. The host returns a stable result code, user-safe English message, and structured data. Unknown commands, unexpected fields, oversized payloads, invalid paths, and stale discovery tokens are rejected.

The host must canonicalize every selected path, require it to be a local file, reject network/UNC paths for MT4 sources, and confirm the selected file still matches the discovery result immediately before setup.

## Configuration model

The existing account mapping remains compatible during migration, but product-facing names change to AmmarTrading. Each enabled mapping contains:

```text
Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot
```

The account number remains the upsert key. A setup transaction validates all selected mappings before any write, preserves accounts that were not selected in the current run, writes through a temporary file followed by atomic replacement, and keeps a timestamped backup.

Runtime application state and logs live below `%LOCALAPPDATA%\AmmarTrading\Sync`. Installed binaries live below the installer-selected Program Files location. Logs must not contain Microsoft credentials, CSV row contents, or unrelated OneDrive filenames.

## Failure and recovery behavior

- No OneDrive sign-in: stop before configuration changes and instruct the operator to sign in, then retry.
- No eligible MT4 account: keep discovery open and provide refresh/manual browse.
- Old or malformed schema: block that account and state the required schema version.
- Duplicate account sources: require an explicit source choice.
- Any selected account fails preflight: do not modify configuration or tasks.
- Publication fails after configuration staging: restore the previous configuration; keep diagnostic logs and do not enable new tasks.
- Task registration fails after successful local publication: report partial failure, keep the valid mapping and publication, and offer retry.
- Application or VPS restart: existing scheduled sync continues independently of the UI.
- Uninstall: remove application binaries and shortcuts, but preserve account configuration, logs, scheduled sync, OneDrive CSV history, and backups unless a separate explicit cleanup action is chosen.

The workflow never deletes source CSV files, OneDrive history, configuration backups, or unrelated scheduled tasks.

## Installer and upgrade behavior

- Installer filename: `AmmarTrading Sync Setup.exe`.
- Display name: `AmmarTrading Sync`.
- Default per-machine installation with an elevation prompt.
- Start Menu shortcut and an opt-in desktop shortcut.
- Existing browser-wizard installations are detected and imported without requiring the operator to re-enter paths.
- Upgrades preserve configuration and task state.
- A failed upgrade rolls back application binaries and does not rewrite sync configuration.
- Code signing is supported by the release process, but an actual certificate is a release prerequisite rather than an assumption in the first internal test build.

## Security boundaries

- No inbound network listener and no remote-control capability.
- No OneDrive or Microsoft password collection.
- No arbitrary PowerShell supplied by the UI.
- No unrestricted filesystem browsing through the React bridge.
- The sync task runs with the least privilege compatible with the signed-in OneDrive user.
- The elevated installer is separate from the normally unelevated application.
- Support exports use an allowlist and redact usernames from displayed paths where practical.

## Testing and acceptance

Automated tests must cover:

- MT4 discovery with zero, one, multiple, duplicate, stale, schema-v2, malformed, and schema-v3 candidates.
- Account and broker extraction from quoted and unquoted schema-v3 CSV files.
- Manual browse validation and path canonicalization.
- Multiple account selection and atomic configuration upsert.
- Legacy configuration import and non-destructive reporting-folder migration.
- First publication, content/hash verification, rollback, and partial task failure.
- Native bridge command allowlisting and malformed-message rejection.
- English-only UI strings and product naming.
- Installer install, upgrade, rollback, and uninstall preservation rules.

Windows acceptance on a clean test machine/VPS must prove:

1. A non-technical operator can install from one setup EXE.
2. The app launches without opening a browser or console window.
3. It discovers and displays multiple MT4 accounts by number and broker.
4. Only selected valid schema-v3 accounts are configured.
5. `Baskets.csv` is created under each expected `AmmarTrading\Account_<Number>` folder.
6. Recurring and restart catch-up sync work with the app closed.
7. Existing configuration and historical OneDrive data survive upgrade and uninstall.
8. The reporting PC receives the files physically through OneDrive before Excel Master is connected.

## Out of scope

- Signing in to OneDrive on behalf of the operator.
- Installing or attaching the EA to MT4 charts.
- Remote administration of the VPS.
- Proving receipt on the reporting PC from the VPS app alone.
- Automatic software update service in the first version.
- Deleting legacy `Money Machine` or `AmarTrading` data.
