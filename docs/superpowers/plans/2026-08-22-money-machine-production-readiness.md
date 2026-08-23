# MoneyMachine Production Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Harden, install, and verify the MT4 CSV → OneDrive sync on the real Windows worker without changing trading behavior.

**Architecture:** Keep the EA as the source of the schema-v3 CSV. Replace the fragile copy path with a library-style PowerShell sync that validates the complete snapshot, publishes atomically, serializes runs with a named mutex, records state and per-account heartbeat, and returns nonzero for enabled-account failures. Install the script and account configuration side-by-side on Windows, then validate the real MT4 CSV in staging and production OneDrive paths.

**Tech Stack:** MQL4, Windows PowerShell 5.1, Task Scheduler, OneDrive local sync, Bash test orchestration.

**Spec:** `docs/superpowers/specs/2026-08-20-onedrive-csv-production-readiness-design.md`

## Global Constraints

- Do not change entry, grid, basket-management, trailing, exit, or risk decisions in the EA.
- Preserve the exact schema-v3 header: 71 columns in the current order.
- A header-only schema-v3 CSV is a valid zero-row run and replaces stale destination data.
- Local publication is not cloud-delivery proof; write a heartbeat and report cloud verification separately.
- Store Windows deployment artifacts outside the repository and keep credentials/secrets out of source control.
- Preserve rollback by keeping the prior destination and prior task definitions until acceptance passes.

### Task 1: Add regression coverage for production sync behavior

**Files:**
- Modify: `tests/Test-MoneyMachineCsvSync.ps1`
- Test: `tests/Test-MoneyMachineCsvSync.ps1`

- [ ] Add failing cases for header-only input, malformed rows preserving the prior destination, enabled missing-source failure, and process-level nonzero failure semantics.
- [ ] Run the Windows test and confirm each new assertion fails against the current implementation.
- [ ] Keep the existing success, overwrite, and login-mismatch tests green.

### Task 2: Harden the sync implementation

**Files:**
- Modify: `automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1`
- Modify: `automation/MoneyMachineCsvSync/accounts.csv`

- [ ] Add the exact schema-v3 header contract and standards-aware CSV validation with 71 fields per row.
- [ ] Permit a header-only file when the configured account is the destination identity.
- [ ] Capture source metadata and SHA-256 before and after copying; reject a source that changes or a temporary copy whose hash differs.
- [ ] Acquire a deterministic named mutex before reading state or publishing.
- [ ] Atomically replace the destination and `state/last-run.json`; never destroy the previous good destination on validation failure.
- [ ] Write per-account `SyncStatus.json` with account, row count, hashes, publication time, and `CloudDeliveryVerified=false`.
- [ ] Return exit code 0 only when every enabled account is `Success` or benign startup catch-up; return nonzero for missing source, invalid CSV, mismatch, lock timeout, or publication failure.
- [ ] Run the regression suite until all cases pass.

### Task 3: Harden scheduled-task installation

**Files:**
- Modify: `automation/MoneyMachineCsvSync/Install-BasketsSyncTask.ps1`
- Test: `tests/Test-MoneyMachineCsvSync.ps1`

- [ ] Resolve absolute script/config paths, set an explicit working directory, and use Windows PowerShell 5.1 explicitly.
- [ ] Add retry settings (three attempts, five-minute intervals) and preserve `IgnoreNew` within each task.
- [ ] Add a pure task-definition inspection path so action executable, arguments, principal, and triggers can be tested without registration.
- [ ] Validate the installer syntax and task-definition contract on the Windows worker.

### Task 4: Validate the real MT4 deployment

**Files:**
- Verify only: `AmmarTradingGoldEA - ref reset every bar - V3.mq4`
- Verify only: `AmmarTradingGoldEA - ref reset every bar - V3.ex4`

- [ ] Run the V3 telemetry contract test against the repository source.
- [ ] Compile the source in an isolated `MQL4\Experts\CodexTest` directory with MetaEditor.
- [ ] Require the compile log to report zero errors; record warnings separately.
- [ ] Inspect the live MT4 data folder, running terminal, EA artifact, CSV header, account login, row count, and last-write time.
- [ ] Do not replace the live EA automatically; compare the compiled artifact and require an explicit cutover only if deployment is needed.

### Task 5: Stage, install, and verify OneDrive sync

**Files:**
- Verify deployment from: `automation/MoneyMachineCsvSync/**`
- Produce local evidence under: `audit/windows-production-acceptance.json`

- [ ] Copy the hardened automation to a versioned Windows deployment directory under `C:\ProgramData`.
- [ ] Back up existing MoneyMachine task definitions and destination before registration.
- [ ] Configure the real MT4 source path, login `36097370`, and `C:\Users\dryou\OneDrive` destination.
- [ ] Run a staging sync against the real CSV and verify row count, exact header, hash, atomic destination, and heartbeat.
- [ ] Register daily and startup catch-up tasks as the OneDrive user, trigger both close together, and verify mutex serialization and final result code.
- [ ] Run the production local publication and verify `Baskets.csv` and `SyncStatus.json` in the expected account folder.
- [ ] Verify OneDrive service state and file timestamps; do not claim cloud delivery until receiver-side evidence exists.

### Task 6: Final verification and handoff

- [ ] Run all repository contract tests and Windows acceptance tests freshly.
- [ ] Verify `git diff --check`, source-control status, deployment paths, task definitions, rollback artifacts, and no secrets in the repository.
- [ ] Report any remaining external gate explicitly, especially receiver-side OneDrive/Excel refresh if it cannot be observed from this worker.
- [ ] Declare production-ready only when every acceptance criterion has fresh evidence.
