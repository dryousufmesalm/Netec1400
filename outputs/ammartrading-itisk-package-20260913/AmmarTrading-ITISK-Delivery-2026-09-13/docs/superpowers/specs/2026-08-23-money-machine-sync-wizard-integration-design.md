# Money Machine Sync Wizard Integration Design

## Goal

Turn the approved Arabic RTL prototype into a real, double-click Windows setup wizard that a non-technical operator runs locally on each new VPS. After setup, the existing hardened sync publishes that VPS's schema-v3 `AGOLD___Baskets.csv` into the dedicated uploader's local OneDrive folder so the central reporting device receives every account folder through OneDrive.

## Deployment model

- The wizard runs on the VPS being added; it does not remotely administer a VPS from the reporting PC.
- The dedicated uploader OneDrive identity must already be signed in on that VPS. The wizard never accepts, stores, or logs Microsoft credentials.
- The operator copies one self-contained `MoneyMachineCsvSync` folder to the VPS and double-clicks `Start-MoneyMachineSyncWizard.cmd`.
- Windows PowerShell 5.1 hosts the built React files and a JSON API on `127.0.0.1` only. Node.js is required only while building the package, not on the VPS.
- The existing `Sync-BasketsToOneDrive.ps1` and scheduled-task installer remain the publication engine.

## User flow

1. The launcher opens the Arabic wizard in the default Windows browser.
2. Discovery lists signed-in OneDrive roots and MT4 schema-v3 CSV candidates found below the current user's MetaQuotes terminal data folder.
3. The operator enters a friendly VPS name and MT4 account number and chooses the detected CSV and OneDrive root.
4. Preflight verifies the source file, schema/account match, OneDrive folder, PowerShell runtime, and ScheduledTasks commands.
5. Setup atomically upserts `accounts.csv`, preserving a timestamped backup, performs a real first publication, then registers the daily and logon catch-up tasks.
6. Success displays the exact destination folder and the local publication result. It labels cloud delivery separately because only the receiving device can prove OneDrive delivery.

## API and security

- Listen only on `http://127.0.0.1:<available-port>/`; never bind `0.0.0.0`.
- Permit only `GET /`, built static assets, `GET /api/discovery`, `GET /api/accounts`, and `POST /api/setup`.
- Set a random `SameSite=Strict; HttpOnly` session cookie on the app response and require it on every API call.
- Reject API requests whose `Host` is not the active loopback endpoint or whose `Origin`, when present, is not that endpoint.
- Cap request bodies at 64 KiB, require JSON, and never invoke PowerShell through string-evaluated commands.
- Return stable stage codes and Arabic-safe UTF-8 JSON. Do not return credentials, task XML, or unrelated filesystem content.

## Configuration contract

`accounts.csv` gains an optional `VpsName` column while keeping the existing required fields:

```csv
Enabled,VpsName,ExpectedMT4Login,SourceCsv,OneDriveRoot
true,VPS London 01,892522910,C:\Users\operator\AppData\Roaming\MetaQuotes\Terminal\...\MQL4\Files\AGOLD___Baskets.csv,C:\Users\operator\OneDrive - Money Machine
```

The account number is the upsert key. A duplicate account replaces its name/source/root only after successful validation. Existing rows for other accounts are preserved.

## Failure behavior

- Missing OneDrive: stop before changing configuration and tell the operator to sign in to the dedicated uploader account.
- Missing/invalid CSV or account mismatch: stop before changing configuration and identify the field to correct.
- First publication failure: restore the prior `accounts.csv`; do not install tasks.
- Scheduled-task registration failure after a successful first publication: keep the validated configuration and publication, report a partial setup failure, and give the task error without pretending automation is active.
- The wizard never deletes CSV data, OneDrive output, prior configuration backups, or existing unrelated scheduled tasks.

## Acceptance

- PowerShell unit/integration tests prove discovery, validation, atomic upsert, rollback on failed publication, and successful staged publication.
- Browser tests exercise discovery, form submission, progress, error display, success, and refreshed account list against the real localhost PowerShell host.
- Windows verification confirms the listener is loopback-only, the browser console is clean, and no production scheduled task is created during staging acceptance.
- Production task registration happens only when the wizard runs normally on the intended VPS.
