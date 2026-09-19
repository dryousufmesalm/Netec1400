# OneDrive CSV Production Readiness Design

**Status:** Proposed for implementation after user review  
**Date:** 2026-08-20  
**Source audit:** `audit/onedrive-sync-production-findings.csv`

## Goal

Make the MT4 CSV → local OneDrive folder → Excel reporting flow safe for unattended production use, close all 11 audit findings, and produce evidence from a real Windows environment before declaring it production-ready.

## Scope and constraints

- Production changes are limited to the V3 reporting writer, the `MoneyMachineCsvSync` automation, its Power Query files, the supplied workbook, tests, and operating documentation.
- Trading entries, grid logic, basket management, exits, and risk decisions must not change.
- The schema-v3 header remains the current 71 columns in the current order.
- A valid header-only schema-v3 CSV represents a new run with zero closed baskets and must replace stale destination data.
- The scheduled runtime is Windows PowerShell 5.1. The installer may be started from Windows PowerShell 5.1 or PowerShell 7, but it must resolve and validate the Windows PowerShell executable used by Task Scheduler.
- A local copy into the OneDrive folder is called `LocalPublished`; it is not called cloud success.
- No Microsoft Graph credentials or other cloud secrets will be added to this repository.
- Existing schema-v2 files remain a workbook import compatibility concern only. The production sync path accepts schema v3.

## Selected approach

Use full production hardening across the existing components. The sync process will validate a complete immutable snapshot, publish it atomically, serialize concurrent runs with a named mutex, record machine-readable status, and fail the process when an enabled account is not safely published. The EA will escape CSV text correctly, while Power Query and the workbook will be updated to preserve all configuration distinctions and expose freshness.

Cloud delivery will be verified from the receiving side. Each account folder will contain a small `SyncStatus.json` heartbeat. A check run on the reporting Windows machine will confirm that the heartbeat arrived through OneDrive and is within the freshness SLO. This avoids falsely treating a local filesystem write as proof of upload.

## Components

### 1. Schema contract and complete validation

A focused PowerShell module will own the exact 71-column schema-v3 contract and CSV validation. It will use a standards-aware CSV parser so quoted commas, quotes, and embedded line breaks are handled correctly.

For every snapshot it will enforce:

- exact header names, case, count, and order;
- exactly 71 fields in every record;
- `AccountNumber` equals the configured login on every data row;
- `CsvSchemaVersion` equals `3` on every data row;
- required keys are present and `(AccountNumber, RunID, BasketID)` is unique;
- invariant parsing of integer, decimal, timestamp, and date fields;
- `Direction`, `CloseReason`, `OutcomeClass`, and boolean fields use their controlled values;
- `DurationSeconds` agrees with `StartTime` and `EndTime`;
- `TradeDate` agrees with the server date in `StartTime`.

A header-only file passes validation using the configured login as its destination identity and returns a row count of zero.

### 2. Correct CSV output from MT4

The V3 MQ4 telemetry writer will add one CSV escaping helper. Every text field will pass through it. Values containing a comma, quote, carriage return, or line feed will be quoted, and embedded quotes will be doubled. Numeric formatting and trading behavior remain unchanged.

The existing MQL contract test will cover plain text, commas, quotes, and line breaks, and the PowerShell fixture set will prove that the downstream parser accepts the resulting rows.

### 3. Consistent and atomic synchronization

One invocation will acquire a deterministic Windows named mutex before reading shared state, writing logs, or publishing account data. The daily and logon tasks therefore cannot race even though they remain separate scheduled tasks.

For each enabled account the process will:

1. Capture source length, last-write UTC, and SHA-256.
2. Copy into a unique temporary file in the destination directory.
3. Capture the source metadata and SHA-256 again.
4. Require the pre-copy and post-copy source identities to match and require the temporary copy hash to match the source hash.
5. Validate the complete temporary CSV.
6. Replace an existing destination with an atomic same-volume file replacement, or atomically move the first destination into place.
7. Atomically publish the per-account heartbeat and update success state only after publication succeeds.

Any consistency, validation, or publication failure leaves the previous good destination untouched and is retried according to the existing retry limit.

### 4. Failure semantics and observability

Only disabled accounts and a successful same-day startup catch-up are benign `Skipped` results. Missing source files, missing required configuration, account mismatches, invalid CSV, lock timeouts, and publication failures are `Error` results.

Direct script execution will return exit code `0` only when every enabled account is either `Success` or a benign catch-up skip. Any account error returns a nonzero process exit code so Task Scheduler and monitoring can react.

The automation will write:

- a human-readable rotating log, capped at 5 MiB per file with five retained files;
- an atomically replaced local `state/last-run.json` summary;
- an atomically replaced `SyncStatus.json` in each account's OneDrive folder.

The JSON records account number, local publication status, source and destination hashes, validated row count, source last-write UTC, publication UTC, and `CloudDeliveryVerified: false`. Full credentials and sensitive path details are excluded.

The default freshness SLO is 26 hours, allowing for the daily schedule plus delivery delay. A receiver-side check accepts an explicit account list and returns nonzero if an expected heartbeat is missing, unsuccessful, or stale.

### 5. Scheduled-task installation

The installer will resolve the sync script and configuration with `Resolve-Path`, store only absolute paths, set an explicit working directory, verify the Windows PowerShell 5.1 executable, and verify every required ScheduledTasks command before registration.

Both tasks retain `IgnoreNew` within their own task definition, while the process mutex protects across the daily and startup tasks. Task settings will retry a failed run three times at five-minute intervals. A pure task-definition function will make paths, arguments, runtime selection, and settings testable without registering a real task.

### 6. Power Query and workbook

`ConfigFingerprint` will use all 37 configuration fields in a documented stable order with culture-invariant conversion. The final query column order will match the workbook table: the 71 source columns followed by `FolderAccountNumber`, `RunKey`, `FolderAccountMismatch`, and `ConfigFingerprint`.

A second query will read `SyncStatus.json` files into a `Sync Status` table so an account remains visible even when its current CSV has only a header. It will calculate heartbeat age and an `IsFresh` flag using the 26-hour SLO.

The supplied workbook will be saved with both queries and their connections already present. Basket data and sync status will refresh on open, with background refresh disabled so formulas do not calculate against half-refreshed data. Setup documentation will retain a recovery procedure for recreating the connections but will no longer require initial copy-and-paste as the normal installation path.

## Windows validation strategy

Linux is used only for checks that do not depend on Windows services: repository contracts, schema comparison, fixture generation, JSON/notebook validation, and static review. It is not accepted as evidence for Task Scheduler, OneDrive, Excel, or MetaTrader behavior.

### Automated Windows checks

The implementation will provide `tests/Run-WindowsProductionAcceptance.ps1`. It will run under Windows PowerShell 5.1 and create `audit/windows-production-acceptance.json` containing pass/fail results, runtime versions, timestamps, and redacted paths. It will cover:

- complete valid, header-only, quoted-field, and malformed CSV cases;
- preservation of the previous destination after validation failure;
- source-change detection and atomic publication helpers;
- mutex contention and atomic state updates;
- nonzero child-process exit codes for enabled-account failures;
- absolute scheduled-task action paths and runtime preflight;
- exact 37-field Power Query fingerprint contract;
- MetaEditor compilation of the V3 MQ4 source when its path is supplied;
- workbook query/connection checks through Excel COM when Excel is installed.

These checks can run on a temporary Windows VM, a Windows CI runner for the PowerShell-only subset, or the target VPS. A generic Windows CI runner cannot prove real OneDrive upload, Excel desktop refresh, MT4 compilation, or target-user Task Scheduler permissions unless those products and credentials exist on that machine.

### Real VPS and receiver acceptance

Before production cutover, the target VPS must run the acceptance script using a staging OneDrive root. Then:

1. Register the two scheduled tasks as the same Windows user that owns OneDrive.
2. Trigger both tasks close together and confirm mutex serialization and final result code `0`.
3. Publish a header-only file and confirm stale basket rows disappear on the receiver.
4. Publish a valid escaped-field row and confirm all 71 columns remain aligned.
5. Inject a malformed row and confirm the task is nonzero while the previous destination remains unchanged.
6. Confirm the receiver-side heartbeat appears within 30 minutes through OneDrive.
7. Open the production workbook on the receiving Windows machine, refresh both queries, and confirm the new row count, account, run, fingerprint, and freshness status.
8. Run the daily task once through Task Scheduler and require `LastTaskResult = 0`.

The final production-ready decision requires the Windows acceptance JSON plus screenshots or operator confirmation for the OneDrive web/receiver and Excel refresh checks. If no Windows machine is connected to this session, the user runs the one-command acceptance script and returns the JSON file for review; Linux-only evidence cannot close this gate.

## Deployment and rollback

- Deploy the hardened automation into a versioned side-by-side directory first.
- Back up the current task definitions, workbook, account configuration, state, and destination CSV before switching tasks.
- Run staging acceptance with a temporary OneDrive root.
- Switch scheduled tasks only after all automated Windows checks pass.
- Keep the previous automation directory and workbook until one full daily cycle and receiver refresh pass.
- Roll back by restoring the prior task actions and workbook; do not delete the last known-good destination CSV.

## Production acceptance criteria

Production readiness is granted only when all of the following are true:

- all 11 audit findings have a passing regression or an explicitly verified operating control;
- the V3 MQ4 source compiles with zero errors and its telemetry contract test passes;
- all PowerShell checks pass in Windows PowerShell 5.1;
- scheduled tasks use absolute paths and report failures with nonzero result codes;
- header-only, concurrent-run, malformed-row, and escaped-text scenarios pass on Windows;
- a heartbeat is observed on the receiver within 30 minutes;
- the prewired workbook refreshes both queries and reports fresh data;
- rollback artifacts are present and the operator has completed the cutover checklist.

