# Money Machine Sync Wizard Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a double-click, localhost-only Windows wizard that discovers MT4/OneDrive paths, validates and saves an account, performs the first CSV publication, and installs the existing scheduled sync tasks.

**Architecture:** A testable PowerShell setup module owns discovery, validation, atomic configuration, publication, and task registration. A Windows PowerShell `HttpListener` serves the compiled React UI and exposes a cookie-protected loopback JSON API; a CMD launcher starts it without requiring Node.js on the VPS.

**Tech Stack:** Windows PowerShell 5.1, `HttpListener`, React 19, Vite 6, Node test runner, Playwright Core with installed Microsoft Edge for acceptance.

**Spec:** `docs/superpowers/specs/2026-08-23-money-machine-sync-wizard-integration-design.md`

## Global Constraints

- The wizard runs locally on each VPS and never accepts Microsoft, RDP, or trading passwords.
- The API binds only to `127.0.0.1` and requires a strict session cookie plus Host/Origin validation.
- The dedicated uploader OneDrive identity must already be signed in.
- Existing sync schema validation, atomic publication, mutex, task definitions, and destination layout remain authoritative.
- No production scheduled tasks are registered during automated acceptance.
- Every production behavior is implemented through a failing test first.

---

### Task 1: Setup discovery and request validation

**Files:**
- Create: `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1`
- Create: `tests/Test-MoneyMachineSyncSetup.ps1`

**Interfaces:**
- Produces: `Get-MoneyMachineSetupDiscovery -OneDriveCandidates <string[]> -TerminalDataRoot <string>`.
- Produces: `Test-MoneyMachineSetupRequest -VpsName <string> -ExpectedMT4Login <string> -SourceCsv <string> -OneDriveRoot <string>` returning normalized absolute values or throwing a field-specific error.

- [ ] **Step 1: Write a failing discovery test** that creates fake OneDrive and `MetaQuotes\Terminal\<hash>\MQL4\Files\AGOLD___Baskets.csv` directories, calls discovery with the injected roots, and asserts exactly one resolved candidate of each type.
- [ ] **Step 2: Run** `powershell.exe -NoProfile -File tests\Test-MoneyMachineSyncSetup.ps1` **and verify it fails because the module/functions do not exist.**
- [ ] **Step 3: Implement minimal discovery** using literal paths, `Resolve-Path`, bounded filename search below the injected terminal root, and current-user OneDrive environment candidates when no override is supplied.
- [ ] **Step 4: Add failing validation assertions** for blank VPS name, non-digit login, missing CSV, non-CSV source, missing OneDrive root, and schema/account mismatch using `Read-MoneyMachineBasketsCsv`.
- [ ] **Step 5: Run the test and verify the new assertions fail for missing validation.**
- [ ] **Step 6: Implement `Test-MoneyMachineSetupRequest`** with trimmed values, absolute resolved paths, digit-only account numbers, and schema-v3 account validation.
- [ ] **Step 7: Run the setup test and existing sync tests; require both to pass.**

### Task 2: Atomic account upsert and setup orchestration

**Files:**
- Modify: `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1`
- Modify: `tests/Test-MoneyMachineSyncSetup.ps1`
- Modify: `automation/MoneyMachineCsvSync/accounts.csv`

**Interfaces:**
- Produces: `Save-MoneyMachineAccountConfig -ConfigPath <string> -Account <pscustomobject>` returning `ConfigPath`, `BackupPath`, and `Changed`.
- Produces: `Invoke-MoneyMachineSetup -Request <pscustomobject> -ConfigPath <string> -RuntimeRoot <string> -SkipTaskRegistration` returning stage objects and final destination.

- [ ] **Step 1: Add a failing config test** that starts with one account, upserts a second, asserts the exact five-column header/order, then replaces the second by login while preserving the first.
- [ ] **Step 2: Run the test and verify it fails because config persistence is absent.**
- [ ] **Step 3: Implement atomic CSV serialization** through a same-directory temporary file, UTF-8 without BOM, timestamped backup when a prior file exists, and replacement by account login.
- [ ] **Step 4: Add a failing orchestration test** using the schema-v3 fixture and a temporary OneDrive root; call `Invoke-MoneyMachineSetup -SkipTaskRegistration`, then assert config, `Baskets.csv`, `SyncStatus.json`, and stage `LocalPublished` exist.
- [ ] **Step 5: Run the test and verify it fails because orchestration is absent.**
- [ ] **Step 6: Implement setup orchestration** by validating first, saving config, calling `Invoke-MoneyMachineCsvSync` with zero stable delay only when explicitly injected by tests, restoring the old config on publication failure, and calling `Install-BasketsSyncTask.ps1` only outside staging mode.
- [ ] **Step 7: Add a failing rollback test** with a malformed source and assert the original config bytes remain unchanged and task registration is never attempted.
- [ ] **Step 8: Implement rollback, rerun all PowerShell tests, and require zero failures.**

### Task 3: Loopback-only Windows API host

**Files:**
- Create: `automation/MoneyMachineCsvSync/Start-MoneyMachineSyncWizard.ps1`
- Create: `tests/Test-MoneyMachineSyncWizardHost.ps1`

**Interfaces:**
- Produces: `Start-MoneyMachineSyncWizard -Port <int=8765> -NoBrowser -SkipTaskRegistration -ConfigPath <string> -RuntimeRoot <string>`.
- API: `GET /api/discovery`, `GET /api/accounts`, `POST /api/setup`.

- [ ] **Step 1: Write a failing host contract test** that imports the script as a library and asserts loopback prefix construction, allowed route/method pairs, Host/Origin checks, 64 KiB body limit, and strict session-cookie validation.
- [ ] **Step 2: Run the test and verify it fails because the host is absent.**
- [ ] **Step 3: Implement pure request-security helpers** and the `HttpListener` loop using `http://127.0.0.1:<port>/` only, random 256-bit session token, `HttpOnly; SameSite=Strict` cookie, JSON UTF-8 responses, and a static-file allowlist rooted under `WizardApp`.
- [ ] **Step 4: Add failing API integration assertions** by starting the host in staging mode, verifying unauthenticated API rejection, obtaining the app cookie, reading discovery, posting a valid setup, and rejecting bad origin/content type/body size.
- [ ] **Step 5: Implement route handlers** that call only exported setup-module functions and return stable `ok`, `stage`, `message`, `accounts`, `sources`, `oneDriveRoots`, and `destination` fields.
- [ ] **Step 6: Run host, setup, and existing sync tests on Windows; require all to pass.**

### Task 4: Connect the React flow to the real API

**Files:**
- Create: `prototypes/money-machine-sync-wizard/src/api.js`
- Create: `prototypes/money-machine-sync-wizard/tests/api.test.mjs`
- Modify: `prototypes/money-machine-sync-wizard/src/App.jsx`
- Modify: `prototypes/money-machine-sync-wizard/src/styles.css`
- Modify: `prototypes/money-machine-sync-wizard/package.json`

**Interfaces:**
- Produces: `wizardApi.getDiscovery()`, `wizardApi.getAccounts()`, and `wizardApi.runSetup(request)` using same-origin credentials.
- Consumes the API contract from Task 3.

- [ ] **Step 1: Write failing Node tests** for successful JSON parsing, non-2xx Arabic error propagation, credentials inclusion, and exact setup payload field names.
- [ ] **Step 2: Run `npm test` and verify failure because `src/api.js` is absent.**
- [ ] **Step 3: Implement the minimal fetch adapter** with `credentials: 'same-origin'`, JSON headers, and normalized errors.
- [ ] **Step 4: Add component-flow expectations to the browser acceptance script** for discovery loading, disabled submit while invalid, live setup stages, server error display, success destination, and refreshed account list.
- [ ] **Step 5: Replace mock timers/state** with discovery and setup API calls while preserving the approved Arabic RTL layout, loading states, validation copy, and an explicit `LocalPublished` versus cloud-delivery explanation.
- [ ] **Step 6: Run Node tests, build, and browser acceptance against the staging host; require no console errors.**

### Task 5: Self-contained Windows package and launcher

**Files:**
- Create: `prototypes/money-machine-sync-wizard/scripts/package-windows-wizard.mjs`
- Create: `prototypes/money-machine-sync-wizard/tests/package-windows-wizard.test.mjs`
- Create: `automation/MoneyMachineCsvSync/Start-MoneyMachineSyncWizard.cmd`
- Create/refresh: `automation/MoneyMachineCsvSync/WizardApp/**`
- Modify: `prototypes/money-machine-sync-wizard/package.json`
- Modify: `CSV_ONEDRIVE_EXCEL_SETUP.md`

**Interfaces:**
- Produces: `npm run package:windows` which builds the UI and replaces only the generated `WizardApp` directory.
- Produces: a double-click launcher requiring only Windows PowerShell 5.1 at runtime.

- [ ] **Step 1: Write a failing packaging test** in a temporary directory that asserts only `dist/client` files are copied, stale generated files are removed, and `index.html` plus hashed assets exist.
- [ ] **Step 2: Run the test and verify failure because the packager is absent.**
- [ ] **Step 3: Implement the deterministic packaging script** and npm command, then run the test and build.
- [ ] **Step 4: Add the CMD launcher** using `%~dp0`, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`, and `pause` only on nonzero exit.
- [ ] **Step 5: Update the setup guide** with a five-step non-technical VPS procedure, the prerequisite OneDrive sign-in, receiver verification, security boundaries, and rollback location.
- [ ] **Step 6: Package the app and verify the complete automation folder contains no Node runtime dependency.**

### Task 6: Windows staged end-to-end acceptance

**Files:**
- Modify: `tests/Run-WindowsProductionAcceptance.ps1`
- Create: `tests/Test-MoneyMachineSyncWizardAcceptance.ps1`
- Modify: `prototypes/money-machine-sync-wizard/design-qa.md`

**Interfaces:**
- Consumes the packaged automation folder and fixture CSV.
- Produces redacted staging evidence without registering production tasks.

- [ ] **Step 1: Add a failing acceptance check** requiring the packaged app, setup module, host, launcher, loopback listener, API security checks, successful staging publication, browser flow, and zero console errors.
- [ ] **Step 2: Run the staged acceptance on Windows and verify the new check fails before wiring it into the runner.**
- [ ] **Step 3: Implement the acceptance runner integration** with a task-specific `C:\CodexWorker\MoneyMachine-Wizard-Acceptance` root and `-SkipTaskRegistration`.
- [ ] **Step 4: Run all PowerShell tests, Node tests, production build, Sites worker tests, and Windows browser acceptance.**
- [ ] **Step 5: Confirm by read-only Windows checks** that the listener used `127.0.0.1`, no staging task names exist, output hashes match, and the receiver folder contains the expected account heartbeat.
- [ ] **Step 6: Refresh design QA evidence** for real discovery, progress, error, success, and responsive states; require `final result: passed`.
