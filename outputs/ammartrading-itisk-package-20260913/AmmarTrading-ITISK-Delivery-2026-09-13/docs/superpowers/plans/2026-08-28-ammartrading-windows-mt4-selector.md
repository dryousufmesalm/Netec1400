# AmmarTrading Sync Windows App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an installable English Windows application named AmmarTrading Sync that discovers multiple MT4 schema-v3 accounts, lets a non-technical operator select them, and configures verified OneDrive publication and restart-safe automation.

**Architecture:** Preserve the tested PowerShell CSV validation/publication engine, add account-aware discovery and transactional multi-account setup, and place the React wizard inside a self-contained .NET 8 WPF/WebView2 host. The host exposes only a typed allowlisted message bridge; an Inno Setup package installs the application, imports legacy configuration, and preserves data on upgrade/uninstall.

**Tech Stack:** Windows PowerShell 5.1, React 19/Vite 6, Node test runner, .NET 8 WPF, Microsoft Edge WebView2, xUnit, Inno Setup 6, Windows Scheduled Tasks.

**Spec:** `docs/superpowers/specs/2026-08-28-ammartrading-windows-mt4-selector-design.md`

## Global Constraints

- Product-facing name is exactly `AmmarTrading Sync`; reporting folder is exactly `AmmarTrading`.
- UI is English and left-to-right only.
- One setup run can select multiple MT4 accounts.
- Account number and broker come from a validated schema-v3 `AGOLD___Baskets.csv` row.
- Header-only, schema-v2, malformed, and duplicate account sources cannot be enabled.
- The app never requests or stores Microsoft/OneDrive credentials.
- The desktop app has no inbound network listener and never opens a browser or console window.
- Source CSV paths must be local filesystem paths; UNC/network paths are rejected.
- Setup validates all selected accounts before changing configuration.
- Existing unselected account mappings, backups, source CSVs, and OneDrive history are preserved.
- Cloud delivery is not claimed until the reporting PC is checked separately.
- Runtime state lives under `%LOCALAPPDATA%\AmmarTrading\Sync` and survives uninstall.
- Implement each behavior test-first and make the focused test pass before running broader suites.

## File structure

### Existing files to modify

- `automation/MoneyMachineCsvSync/MoneyMachineCsvSchemaV3.psm1` — expose a bounded identity probe for discovery without weakening strict publication validation.
- `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1` — account-aware MT4 discovery, multi-account validation/setup, and legacy configuration import.
- `automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1` — canonical `AmmarTrading` destination and verified hashes.
- `automation/MoneyMachineCsvSync/Test-MoneyMachineSyncStatus.ps1` — per-account monitoring results consumed by the native host.
- `prototypes/money-machine-sync-wizard/src/api.js` — native WebView2 bridge client with explicit browser-test injection.
- `prototypes/money-machine-sync-wizard/src/App.jsx` — five-screen account-selection and monitoring flow.
- `prototypes/money-machine-sync-wizard/src/styles.css` — desktop states, account cards, progress, and accessible focus/error styling.
- `prototypes/money-machine-sync-wizard/scripts/package-windows-wizard.mjs` — package React assets into the Windows host rather than the legacy HTTP-host folder.
- `prototypes/money-machine-sync-wizard/package.json` — native bridge/UI tests and packaging commands.

### New files to create

- `windows/AmmarTrading.Sync.sln` — Windows application solution.
- `windows/src/AmmarTrading.Sync.Core/AmmarTrading.Sync.Core.csproj` — cross-platform bridge contracts and routing.
- `windows/src/AmmarTrading.Sync.Core/Bridge/BridgeContracts.cs` — versioned request/result records.
- `windows/src/AmmarTrading.Sync.Core/Bridge/BridgeCommandRouter.cs` — allowlist, size cap, validation, dispatch.
- `windows/src/AmmarTrading.Sync.Core/Services/IAmmarTradingOperations.cs` — host-operation boundary.
- `windows/src/AmmarTrading.Sync.App/AmmarTrading.Sync.App.csproj` — self-contained WPF/WebView2 app.
- `windows/src/AmmarTrading.Sync.App/App.xaml` and `App.xaml.cs` — desktop lifecycle and single-instance startup.
- `windows/src/AmmarTrading.Sync.App/MainWindow.xaml` and `MainWindow.xaml.cs` — WebView2 window and local asset boot.
- `windows/src/AmmarTrading.Sync.App/Bridge/WebViewBridge.cs` — WebView message adapter.
- `windows/src/AmmarTrading.Sync.App/Services/PowerShellOperations.cs` — fixed-script invocation and JSON conversion.
- `windows/src/AmmarTrading.Sync.App/Services/NativeDialogService.cs` — CSV picker and folder opening.
- `windows/src/AmmarTrading.Sync.App/Services/SupportReportService.cs` — allowlisted/redacted support export.
- `windows/tests/AmmarTrading.Sync.Core.Tests/AmmarTrading.Sync.Core.Tests.csproj` — xUnit test project.
- `windows/tests/AmmarTrading.Sync.Core.Tests/BridgeCommandRouterTests.cs` — command security and dispatch tests.
- `windows/tests/AmmarTrading.Sync.App.Tests/AmmarTrading.Sync.App.Tests.csproj` — Windows service integration tests.
- `windows/tests/AmmarTrading.Sync.App.Tests/PowerShellOperationsTests.cs` — argument safety and result mapping.
- `windows/installer/AmmarTradingSync.iss` — installer, shortcuts, WebView2 prerequisite, upgrade/uninstall rules.
- `windows/scripts/Build-AmmarTradingSync.ps1` — deterministic UI/.NET/installer build.
- `windows/scripts/Test-AmmarTradingSyncAcceptance.ps1` — clean-machine Windows acceptance.
- `tests/Test-AmmarTradingMt4Discovery.ps1` — discovery fixtures and account statuses.
- `tests/Test-AmmarTradingBatchSetup.ps1` — atomic multi-account configuration and rollback.
- `prototypes/money-machine-sync-wizard/tests/native-bridge.test.mjs` — JS request/response bridge tests.
- `prototypes/money-machine-sync-wizard/tests/multi-account-flow.test.mjs` — UI state-reducer tests.

---

### Task 1: Canonical AmmarTrading naming and compatibility contract

**Files:**
- Modify: `automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1`
- Modify: `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1`
- Modify: `automation/MoneyMachineCsvSync/Test-MoneyMachineSyncStatus.ps1`
- Modify: `prototypes/money-machine-sync-wizard/src/App.jsx`
- Modify: `prototypes/money-machine-sync-wizard/tests/english-localization.test.mjs`
- Test: `tests/Test-MoneyMachineCsvSync.ps1`
- Test: `tests/Test-MoneyMachineSyncSetup.ps1`

**Interfaces:**
- Consumes: existing account mapping CSV and schema-v3 publication engine.
- Produces: destination contract `<OneDriveRoot>\AmmarTrading\Account_<login>\Baskets.csv`; legacy folder names are read-only migration candidates.

- [ ] **Step 1: Write failing naming tests**

Add assertions that new results use the canonical folder and that UI source contains the exact product name:

```powershell
$result.Destination | Should -Be (Join-Path $oneDriveRoot 'AmmarTrading\Account_892522910\Baskets.csv')
(Test-Path -LiteralPath (Join-Path $oneDriveRoot 'AmmarTrading\Account_892522910\Baskets.csv')) | Should -BeTrue
```

```js
assert.match(appSource, /AmmarTrading Sync/);
assert.doesNotMatch(appSource, /Money Machine|OneDrive \/ AmarTrading/);
assert.match(appSource, /OneDrive \/ AmmarTrading/);
```

- [ ] **Step 2: Run focused tests and confirm the old name fails**

Run:

```powershell
pwsh -NoProfile -File tests/Test-MoneyMachineCsvSync.ps1
pwsh -NoProfile -File tests/Test-MoneyMachineSyncSetup.ps1
```

```bash
cd prototypes/money-machine-sync-wizard
node --test tests/english-localization.test.mjs
```

Expected: at least one failure showing `AmarTrading` or `Money Machine` where `AmmarTrading` is required.

- [ ] **Step 3: Centralize and apply the canonical destination**

Add one helper in each PowerShell module that needs the path, or export a shared helper if both modules already import the same module:

```powershell
function Get-AmmarTradingDestinationPath {
    param([Parameter(Mandatory)][string]$OneDriveRoot,[Parameter(Mandatory)][string]$AccountNumber)
    Join-Path $OneDriveRoot (Join-Path 'AmmarTrading' (Join-Path ("Account_{0}" -f $AccountNumber) 'Baskets.csv'))
}
```

Replace product-facing React strings with `AmmarTrading Sync` and destination previews with `OneDrive / AmmarTrading / Account_<number>`.

- [ ] **Step 4: Run naming and current regression tests**

Run the three focused commands from Step 2, then:

```bash
cd prototypes/money-machine-sync-wizard
npm test
```

Expected: all tests pass and no product-facing old name remains.

- [ ] **Step 5: Commit the naming contract**

```bash
git add automation/MoneyMachineCsvSync prototypes/money-machine-sync-wizard/src/App.jsx prototypes/money-machine-sync-wizard/tests/english-localization.test.mjs tests/Test-MoneyMachineCsvSync.ps1 tests/Test-MoneyMachineSyncSetup.ps1
git commit -m "refactor: adopt AmmarTrading Sync product naming"
```

### Task 2: Schema-v3 identity probe and account-aware MT4 discovery

**Files:**
- Modify: `automation/MoneyMachineCsvSync/MoneyMachineCsvSchemaV3.psm1`
- Modify: `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1`
- Create: `tests/Test-AmmarTradingMt4Discovery.ps1`

**Interfaces:**
- Consumes: `%APPDATA%\MetaQuotes\Terminal\<terminalId>\MQL4\Files\AGOLD___Baskets.csv` and optional `<terminalId>\origin.txt`.
- Produces: `Get-AmmarTradingMt4Accounts -TerminalDataRoot <string> -ManualCsv <string[]>` returning objects with `DiscoveryId`, `AccountNumber`, `BrokerName`, `TerminalId`, `TerminalName`, `SourceCsv`, `SchemaVersion`, `LastWriteUtc`, `Freshness`, `Eligibility`, and `ReasonCode`.

- [ ] **Step 1: Create discovery fixtures and failing tests**

The test creates terminal directories under `$TestDrive`, copies schema-v3 and schema-v2 fixtures, writes `origin.txt`, and asserts:

```powershell
$accounts = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $terminalRoot)
$ready = @($accounts | Where-Object Eligibility -eq 'Ready')
$ready.Count | Should -Be 2
$ready[0].AccountNumber | Should -Match '^\d+$'
$ready[0].BrokerName | Should -Not -BeNullOrEmpty
$ready[0].DiscoveryId | Should -Match '^[A-F0-9]{64}$'
@($accounts | Where-Object ReasonCode -eq 'SchemaV2').Count | Should -Be 1
```

Also test `HeaderOnly`, `MalformedCsv`, `DuplicateAccount`, and manual CSV outside an MT4 data root.

- [ ] **Step 2: Run discovery test and verify missing function failure**

```powershell
pwsh -NoProfile -File tests/Test-AmmarTradingMt4Discovery.ps1
```

Expected: failure because `Get-AmmarTradingMt4Accounts` is not exported.

- [ ] **Step 3: Add a bounded identity probe**

Add this public result contract without relaxing `Read-MoneyMachineBasketsCsv`:

```powershell
function Get-AmmarTradingCsvIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Parse the exact header and the first complete data row with TextFieldParser.
    # Return only identity/status metadata; strict full-file validation remains separate.
    [pscustomobject]@{
        AccountNumber = $accountNumber
        BrokerName = $brokerName
        SchemaVersion = $schemaVersion
        Status = $status
    }
}
```

Use stable statuses `Ready`, `HeaderOnly`, `SchemaV2`, and `MalformedCsv`. Compute `DiscoveryId` as SHA-256 over the canonical source path, account number, file length, and last-write UTC ticks:

```powershell
$fingerprint = '{0}|{1}|{2}|{3}' -f $resolvedPath,$identity.AccountNumber,$file.Length,$file.LastWriteTimeUtc.Ticks
$discoveryId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprint)))
```

For Windows PowerShell 5.1 compatibility, implement the same hash using `SHA256.Create()` and `BitConverter` rather than calling APIs unavailable there.

- [ ] **Step 4: Implement restricted MT4 enumeration and conflict classification**

Enumerate only direct terminal directories and `MQL4\Files\AGOLD___Baskets.csv`, resolve `origin.txt` when present, classify age as `Fresh` (at most 15 minutes), `Stale` (over 15 minutes), or `Unknown`, then mark all ready candidates sharing an account number as `Blocked` with `ReasonCode='DuplicateAccount'`.

- [ ] **Step 5: Run discovery plus strict-schema regression tests**

```powershell
pwsh -NoProfile -File tests/Test-AmmarTradingMt4Discovery.ps1
pwsh -NoProfile -File tests/Test-V3TelemetryReportingContract.ps1
```

Expected: all tests pass; malformed/header-only files never become eligible.

- [ ] **Step 6: Commit account-aware discovery**

```bash
git add automation/MoneyMachineCsvSync/MoneyMachineCsvSchemaV3.psm1 automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1 tests/Test-AmmarTradingMt4Discovery.ps1
git commit -m "feat: discover MT4 accounts from schema v3 CSV files"
```

### Task 3: Transactional multi-account setup and legacy import

**Files:**
- Modify: `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1`
- Modify: `automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1`
- Create: `tests/Test-AmmarTradingBatchSetup.ps1`

**Interfaces:**
- Consumes: `Invoke-AmmarTradingBatchSetup -Request <psobject> -ConfigPath <string> -RuntimeRoot <string> -SkipTaskRegistration` where `Request.Accounts` contains `DiscoveryId`, `ExpectedMT4Login`, and `SourceCsv`, plus `VpsName` and `OneDriveRoot`.
- Produces: `{ Status, Accounts[], Stages[], CloudDeliveryVerified=$false }`; each account result has `AccountNumber`, `BrokerName`, `Destination`, `LocalPublished`, and `TaskState`.

- [ ] **Step 1: Write failing batch transaction tests**

Cover two-account success, one-invalid-account no-write, preservation of an unselected row, stale discovery ID rejection, first-publication rollback, and legacy folder copy-without-delete:

```powershell
$result = Invoke-AmmarTradingBatchSetup -Request $request -ConfigPath $config -RuntimeRoot $runtime -SkipTaskRegistration
$result.Accounts.Count | Should -Be 2
@(Import-Csv $config).Count | Should -Be 3
$result.CloudDeliveryVerified | Should -BeFalse
(Test-Path $legacyFile) | Should -BeTrue
(Get-FileHash $legacyFile).Hash | Should -Be (Get-FileHash $migratedFile).Hash
```

- [ ] **Step 2: Run the batch test and verify failure**

```powershell
pwsh -NoProfile -File tests/Test-AmmarTradingBatchSetup.ps1
```

Expected: failure because the batch entry point does not exist.

- [ ] **Step 3: Add all-before-write validation and atomic batch upsert**

Validate every account with `Read-MoneyMachineBasketsCsv`, re-compute its discovery fingerprint immediately before setup, and reject duplicates in the request. Add:

```powershell
function Save-AmmarTradingAccountBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][object[]]$Accounts)
    # Merge by ExpectedMT4Login, preserve other rows, write UTF-8 temp file,
    # then File.Replace with a timestamped backup.
}
```

Call the existing sync only after the batch configuration is staged. On pre-publication failure, restore the backup exactly once.

- [ ] **Step 4: Add non-destructive legacy migration**

Implement `Copy-AmmarTradingLegacyData` for `Money Machine` and `AmarTrading`. Copy only files below account folders, reject reparse points, compare length and SHA-256, never overwrite a different destination file, and never delete source data. Return `Copied`, `AlreadyPresent`, and `Conflict` counts.

- [ ] **Step 5: Run batch and existing setup/sync tests**

```powershell
pwsh -NoProfile -File tests/Test-AmmarTradingBatchSetup.ps1
pwsh -NoProfile -File tests/Test-MoneyMachineSyncSetup.ps1
pwsh -NoProfile -File tests/Test-MoneyMachineCsvSync.ps1
```

Expected: all tests pass and single-account callers remain compatible through a wrapper.

- [ ] **Step 6: Commit transactional setup**

```bash
git add automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1 automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1 tests/Test-AmmarTradingBatchSetup.ps1
git commit -m "feat: configure multiple MT4 accounts atomically"
```

### Task 4: Native WebView2 JavaScript bridge

**Files:**
- Modify: `prototypes/money-machine-sync-wizard/src/api.js`
- Create: `prototypes/money-machine-sync-wizard/tests/native-bridge.test.mjs`
- Modify: `prototypes/money-machine-sync-wizard/tests/api.test.mjs`

**Interfaces:**
- Consumes: `window.chrome.webview.postMessage(request)` and `window.chrome.webview.addEventListener('message', handler)`.
- Produces: `createNativeWizardApi(webview, { timeoutMs=30000, idFactory })`; methods exactly match the spec bridge commands.

- [ ] **Step 1: Write failing request correlation tests**

Use a fake webview that records posted messages and emits replies:

```js
const api = createNativeWizardApi(fakeWebView, { idFactory: () => "req-1", timeoutMs: 50 });
const pending = api.discoverMt4Accounts();
assert.deepEqual(fakeWebView.sent[0], { version: 1, id: "req-1", command: "discoverMt4Accounts", payload: {} });
fakeWebView.reply({ version: 1, id: "req-1", ok: true, code: "Success", data: { accounts: [] } });
assert.deepEqual(await pending, { accounts: [] });
```

Test error mapping, unknown reply IDs, duplicate IDs, malformed replies, and timeout cleanup.

- [ ] **Step 2: Run bridge tests and confirm import failure**

```bash
cd prototypes/money-machine-sync-wizard
node --test tests/native-bridge.test.mjs
```

Expected: failure because `createNativeWizardApi` is not exported.

- [ ] **Step 3: Implement the versioned bridge client**

Implement one listener and a `Map` of pending requests. Expose:

```js
return {
  getSystemStatus: () => request("getSystemStatus", {}),
  discoverMt4Accounts: () => request("discoverMt4Accounts", {}),
  browseForCsv: () => request("browseForCsv", {}),
  getOneDriveRoots: () => request("getOneDriveRoots", {}),
  getConfiguredAccounts: () => request("getConfiguredAccounts", {}),
  validateSelection: (payload) => request("validateSelection", payload),
  applySetup: (payload) => request("applySetup", payload),
  runSyncNow: (payload) => request("runSyncNow", payload),
  openReportingFolder: (payload) => request("openReportingFolder", payload),
  exportSupportReport: () => request("exportSupportReport", {}),
};
```

Keep an injected HTTP adapter only for existing browser tests; production bootstrap must select the native bridge and display a fatal host error if WebView2 is absent.

- [ ] **Step 4: Run JS API tests**

```bash
cd prototypes/money-machine-sync-wizard
node --test tests/native-bridge.test.mjs tests/api.test.mjs
```

Expected: all tests pass with no leaked timers/listeners.

- [ ] **Step 5: Commit the JS bridge**

```bash
git add prototypes/money-machine-sync-wizard/src/api.js prototypes/money-machine-sync-wizard/tests/native-bridge.test.mjs prototypes/money-machine-sync-wizard/tests/api.test.mjs
git commit -m "feat: add typed WebView2 client bridge"
```

### Task 5: Five-screen multi-account React flow

**Files:**
- Modify: `prototypes/money-machine-sync-wizard/src/App.jsx`
- Modify: `prototypes/money-machine-sync-wizard/src/styles.css`
- Create: `prototypes/money-machine-sync-wizard/src/wizardState.js`
- Create: `prototypes/money-machine-sync-wizard/tests/multi-account-flow.test.mjs`
- Modify: `prototypes/money-machine-sync-wizard/scripts/capture-qa.mjs`

**Interfaces:**
- Consumes: the Task 4 API and Task 2 discovery account shape.
- Produces: screens `system`, `accounts`, `onedrive`, `test`, `finish`, and `monitor`; setup payload `{ vpsName, oneDriveRoot, accounts:[{ discoveryId, expectedMT4Login, sourceCsv }] }`.

- [ ] **Step 1: Write failing pure-state tests**

Extract reducer/state helpers so selection logic is testable without a DOM:

```js
const state = reduceWizard(initialWizardState, { type: "DISCOVERY_LOADED", accounts });
const selected = reduceWizard(state, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-1" });
assert.deepEqual(selected.selectedDiscoveryIds, ["ready-1"]);
assert.throws(() => reduceWizard(state, { type: "ACCOUNT_TOGGLED", discoveryId: "blocked-1" }), /not eligible/i);
assert.equal(canContinueFromAccounts(selected), true);
```

Test multiple selection, duplicate blocking, refresh preserving still-valid selections, OneDrive default choice, and stage result mapping.

- [ ] **Step 2: Run reducer test and verify it fails**

```bash
cd prototypes/money-machine-sync-wizard
node --test tests/multi-account-flow.test.mjs
```

Expected: failure because `wizardState.js` does not exist.

- [ ] **Step 3: Implement reducer and screen flow**

Use stable enums rather than string inference:

```js
export const screens = Object.freeze({ SYSTEM: "system", ACCOUNTS: "accounts", ONEDRIVE: "onedrive", TEST: "test", FINISH: "finish", MONITOR: "monitor" });
export const initialWizardState = { screen: screens.SYSTEM, accounts: [], selectedDiscoveryIds: [], roots: [], oneDriveRoot: "", stages: [], error: null };
```

Render account cards with account number, broker, terminal name, schema, freshness, and reason. Disabled cards remain visible. Add `Refresh` and `Browse manually`; do not display editable source paths in the primary flow.

- [ ] **Step 4: Add accessible progress, error, and monitoring states**

Use `aria-live="polite"` for discovery/setup progress, `role="alert"` for blocking failures, visible keyboard focus, 44-pixel minimum interactive controls, and never communicate eligibility by color alone. The finish view must label publication as local and present `Open AmmarTrading Folder`, `Run Sync Now`, `View Status`, `Add Another MT4 Account`, and `Export Support Report`.

- [ ] **Step 5: Build, test, and capture desktop QA**

```bash
cd prototypes/money-machine-sync-wizard
npm test
node scripts/capture-qa.mjs
```

Expected: tests pass; captures show all five setup screens plus monitoring at 1440x900 without overflow or Arabic/RTL text.

- [ ] **Step 6: Commit the multi-account UI**

```bash
git add prototypes/money-machine-sync-wizard/src prototypes/money-machine-sync-wizard/tests prototypes/money-machine-sync-wizard/scripts/capture-qa.mjs prototypes/money-machine-sync-wizard/qa-captures
git commit -m "feat: add multi-account MT4 setup flow"
```

### Task 6: .NET bridge contracts and security router

**Files:**
- Create: `windows/AmmarTrading.Sync.sln`
- Create: `windows/src/AmmarTrading.Sync.Core/AmmarTrading.Sync.Core.csproj`
- Create: `windows/src/AmmarTrading.Sync.Core/Bridge/BridgeContracts.cs`
- Create: `windows/src/AmmarTrading.Sync.Core/Bridge/BridgeCommandRouter.cs`
- Create: `windows/src/AmmarTrading.Sync.Core/Services/IAmmarTradingOperations.cs`
- Create: `windows/tests/AmmarTrading.Sync.Core.Tests/AmmarTrading.Sync.Core.Tests.csproj`
- Create: `windows/tests/AmmarTrading.Sync.Core.Tests/BridgeCommandRouterTests.cs`

**Interfaces:**
- Consumes: UTF-8 JSON messages from Task 4.
- Produces: `Task<BridgeResponse> BridgeCommandRouter.RouteAsync(string json, CancellationToken token)` and operation methods corresponding one-to-one with the ten command names.

- [ ] **Step 1: Scaffold solution and write failing router tests**

Target `net8.0`, enable nullable/reference warnings, and define a fake `IAmmarTradingOperations`. Tests assert a valid command dispatches once and these inputs are rejected: over 64 KiB, version other than 1, empty/duplicate ID, unknown command, extra top-level property, invalid JSON, UNC source, and non-CSV manual source.

```csharp
var response = await router.RouteAsync("""{"version":1,"id":"r1","command":"getSystemStatus","payload":{}}""", default);
Assert.True(response.Ok);
Assert.Equal("r1", response.Id);
Assert.Equal("Success", response.Code);
Assert.Equal(1, operations.SystemStatusCalls);
```

- [ ] **Step 2: Run tests and verify missing types fail**

```bash
dotnet test windows/tests/AmmarTrading.Sync.Core.Tests/AmmarTrading.Sync.Core.Tests.csproj
```

Expected: compile failure because bridge contracts/router are absent.

- [ ] **Step 3: Implement exact contracts and operation interface**

```csharp
public sealed record BridgeRequest(int Version, string Id, string Command, JsonElement Payload);
public sealed record BridgeResponse(int Version, string Id, bool Ok, string Code, string Message, object? Data);

public interface IAmmarTradingOperations
{
    Task<object> GetSystemStatusAsync(CancellationToken token);
    Task<object> DiscoverMt4AccountsAsync(CancellationToken token);
    Task<object> BrowseForCsvAsync(CancellationToken token);
    Task<object> GetOneDriveRootsAsync(CancellationToken token);
    Task<object> GetConfiguredAccountsAsync(CancellationToken token);
    Task<object> ValidateSelectionAsync(JsonElement payload, CancellationToken token);
    Task<object> ApplySetupAsync(JsonElement payload, CancellationToken token);
    Task<object> RunSyncNowAsync(JsonElement payload, CancellationToken token);
    Task<object> OpenReportingFolderAsync(JsonElement payload, CancellationToken token);
    Task<object> ExportSupportReportAsync(CancellationToken token);
}
```

- [ ] **Step 4: Implement strict deserialization and allowlisted dispatch**

Use `JsonSerializerOptions { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow }`, cap input by UTF-8 byte count, validate IDs with `^[A-Za-z0-9-]{1,64}$`, and switch only over the ten specified commands. Convert all internal exceptions to stable safe codes while logging details outside this core component.

- [ ] **Step 5: Run router tests and commit**

```bash
dotnet test windows/tests/AmmarTrading.Sync.Core.Tests/AmmarTrading.Sync.Core.Tests.csproj
git add windows/AmmarTrading.Sync.sln windows/src/AmmarTrading.Sync.Core windows/tests/AmmarTrading.Sync.Core.Tests
git commit -m "feat: add secure native command router"
```

Expected: all router tests pass.

### Task 7: PowerShell operations adapter and safe native actions

**Files:**
- Create: `windows/src/AmmarTrading.Sync.App/Services/PowerShellOperations.cs`
- Create: `windows/src/AmmarTrading.Sync.App/Services/NativeDialogService.cs`
- Create: `windows/src/AmmarTrading.Sync.App/Services/SupportReportService.cs`
- Create: `windows/tests/AmmarTrading.Sync.App.Tests/AmmarTrading.Sync.App.Tests.csproj`
- Create: `windows/tests/AmmarTrading.Sync.App.Tests/PowerShellOperationsTests.cs`
- Modify: `automation/MoneyMachineCsvSync/Test-MoneyMachineSyncStatus.ps1`

**Interfaces:**
- Consumes: fixed scripts copied beside the application and canonical runtime root `%LOCALAPPDATA%\AmmarTrading\Sync`.
- Produces: `PowerShellOperations : IAmmarTradingOperations`; child PowerShell stdout is one UTF-8 JSON object, stderr/exit code become safe bridge errors.

- [ ] **Step 1: Write failing adapter tests with a fake process runner**

Assert executable is `powershell.exe`, arguments are separate `ArgumentList` entries, user values never occur in a command string, timeout kills the child process, invalid JSON is rejected, and support export omits CSV rows and credentials:

```csharp
Assert.Equal("powershell.exe", invocation.FileName);
Assert.Contains("-NoProfile", invocation.ArgumentList);
Assert.Contains("-NonInteractive", invocation.ArgumentList);
Assert.DoesNotContain(invocation.ArgumentList, value => value.Contains("Invoke-Expression", StringComparison.OrdinalIgnoreCase));
```

- [ ] **Step 2: Run app-service tests and confirm missing implementation failure**

```bash
dotnet test windows/tests/AmmarTrading.Sync.App.Tests/AmmarTrading.Sync.App.Tests.csproj -p:EnableWindowsTargeting=true
```

Expected: compile failure because services are absent.

- [ ] **Step 3: Implement fixed entry points and JSON transport**

Add explicit operation values such as `Discover`, `Validate`, `Apply`, `Status`, and `SyncNow` to a PowerShell entry script; pass the request through a temporary UTF-8 JSON file created below the runtime root with current-user-only ACL. Delete that request file in `finally`. Set a 120-second setup timeout and 30-second discovery/status timeout.

- [ ] **Step 4: Implement native CSV browse, folder open, and support export**

The picker filter is `MT4 basket CSV (AGOLD___Baskets.csv)|AGOLD___Baskets.csv|CSV files (*.csv)|*.csv`. Canonicalize the result and send it back through the same PowerShell discovery validator. Open only a verified configured `AmmarTrading` account directory with `explorer.exe`. Support JSON includes application version, Windows version, OneDrive root availability, terminal IDs, account numbers, schema/status codes, task result codes, and redacted paths; it excludes row contents and unrelated directory listings.

- [ ] **Step 5: Run service and PowerShell regression tests**

```bash
dotnet test windows/tests/AmmarTrading.Sync.App.Tests/AmmarTrading.Sync.App.Tests.csproj -p:EnableWindowsTargeting=true
```

```powershell
pwsh -NoProfile -File tests/Test-AmmarTradingMt4Discovery.ps1
pwsh -NoProfile -File tests/Test-AmmarTradingBatchSetup.ps1
```

Expected: all tests pass.

- [ ] **Step 6: Commit the operations adapter**

```bash
git add windows/src/AmmarTrading.Sync.App/Services windows/tests/AmmarTrading.Sync.App.Tests automation/MoneyMachineCsvSync/Test-MoneyMachineSyncStatus.ps1
git commit -m "feat: connect native app to sync operations"
```

### Task 8: WPF/WebView2 desktop host

**Files:**
- Create: `windows/src/AmmarTrading.Sync.App/AmmarTrading.Sync.App.csproj`
- Create: `windows/src/AmmarTrading.Sync.App/App.xaml`
- Create: `windows/src/AmmarTrading.Sync.App/App.xaml.cs`
- Create: `windows/src/AmmarTrading.Sync.App/MainWindow.xaml`
- Create: `windows/src/AmmarTrading.Sync.App/MainWindow.xaml.cs`
- Create: `windows/src/AmmarTrading.Sync.App/Bridge/WebViewBridge.cs`
- Modify: `prototypes/money-machine-sync-wizard/scripts/package-windows-wizard.mjs`
- Modify: `prototypes/money-machine-sync-wizard/package.json`

**Interfaces:**
- Consumes: Task 5 Vite assets, Task 6 router, Task 7 operations.
- Produces: `AmmarTrading.Sync.exe`, a single normal WPF window with local content mapped to `https://ammartrading.app/` and no HTTP listener.

- [ ] **Step 1: Add a failing packaging test**

Change the packaging test to expect `windows/src/AmmarTrading.Sync.App/Assets/Web` and assert it refuses any destination whose normalized suffix is not that exact path. Assert copied `index.html` uses relative/local assets and contains no external script URL.

- [ ] **Step 2: Run packaging test and verify old destination failure**

```bash
cd prototypes/money-machine-sync-wizard
node --test tests/package-windows-wizard.test.mjs
```

Expected: failure because the script still targets `automation/MoneyMachineCsvSync/WizardApp`.

- [ ] **Step 3: Create the WPF project and local WebView boot**

Set `OutputType=WinExe`, `TargetFramework=net8.0-windows`, `UseWPF=true`, `RuntimeIdentifier=win-x64`, and reference `Microsoft.Web.WebView2`. Map bundled assets with:

```csharp
webView.CoreWebView2.SetVirtualHostNameToFolderMapping(
    "ammartrading.app",
    assetRoot,
    CoreWebView2HostResourceAccessKind.DenyCors);
webView.Source = new Uri("https://ammartrading.app/index.html");
```

Disable DevTools, context menus, browser accelerator keys, status bar, password autosave, and autofill in release builds. Reject navigation away from `https://ammartrading.app/`.

- [ ] **Step 4: Connect WebMessageReceived to the router**

`WebViewBridge` reads `WebMessageAsJson`, calls `RouteAsync`, serializes one `BridgeResponse`, and posts it with `PostWebMessageAsJson`. Limit concurrent requests to four with `SemaphoreSlim`; cancel them when the window closes.

- [ ] **Step 5: Add normal desktop lifecycle behavior**

Use a named mutex `Local\AmmarTrading.Sync` for single instance; a second launch brings the existing window forward. Start unelevated, show a friendly fatal page if WebView2 initialization fails, write app logs below `%LOCALAPPDATA%\AmmarTrading\Sync\Logs`, and never show a console.

- [ ] **Step 6: Package UI, build Windows target, and run all .NET tests**

```bash
cd prototypes/money-machine-sync-wizard
npm run package:windows
cd ../..
dotnet build windows/AmmarTrading.Sync.sln -c Release -p:EnableWindowsTargeting=true
dotnet test windows/AmmarTrading.Sync.sln -c Release -p:EnableWindowsTargeting=true
```

Expected: package and solution build successfully; all tests pass.

- [ ] **Step 7: Commit the desktop host**

```bash
git add windows/src/AmmarTrading.Sync.App prototypes/money-machine-sync-wizard/scripts/package-windows-wizard.mjs prototypes/money-machine-sync-wizard/package.json prototypes/money-machine-sync-wizard/tests/package-windows-wizard.test.mjs
git commit -m "feat: host sync wizard as a Windows desktop app"
```

### Task 9: Installer, upgrade, and build pipeline

**Files:**
- Create: `windows/installer/AmmarTradingSync.iss`
- Create: `windows/scripts/Build-AmmarTradingSync.ps1`
- Create: `windows/scripts/Test-AmmarTradingSyncAcceptance.ps1`
- Modify: `CSV_ONEDRIVE_EXCEL_SETUP.md`

**Interfaces:**
- Consumes: Release `win-x64` self-contained publish, bundled PowerShell runtime files, WebView2 Evergreen bootstrapper, Inno Setup 6 compiler.
- Produces: `artifacts/windows/AmmarTrading Sync Setup.exe` plus SHA-256 manifest.

- [ ] **Step 1: Write failing build-contract checks**

In the acceptance script, parse installer metadata and assert display name, filename, shortcuts, uninstall entry, retained local data, and no browser launcher:

```powershell
$Installer = Join-Path $RepoRoot 'artifacts\windows\AmmarTrading Sync Setup.exe'
if(-not (Test-Path -LiteralPath $Installer -PathType Leaf)) { throw "Installer missing: $Installer" }
if(Test-Path (Join-Path $InstallRoot 'Start-MoneyMachineSyncWizard.cmd')) { throw 'Legacy browser launcher must not be installed.' }
if(-not (Test-Path (Join-Path $InstallRoot 'AmmarTrading.Sync.exe'))) { throw 'Desktop executable is missing.' }
```

- [ ] **Step 2: Create deterministic publish/build script**

`Build-AmmarTradingSync.ps1` must stop on error, run `npm ci`, `npm test`, `npm run package:windows`, `dotnet test`, `dotnet publish --self-contained true -r win-x64`, copy only allowlisted PowerShell modules/scripts, verify the WebView2 bootstrapper Authenticode signer contains `Microsoft Corporation`, call `ISCC.exe`, and write `SHA256SUMS.txt`.

- [ ] **Step 3: Author installer and preservation rules**

Use these stable Inno values:

```ini
[Setup]
AppId={{8F488698-AB96-45DB-A2BB-D9E868823F43}
AppName=AmmarTrading Sync
DefaultDirName={autopf}\AmmarTrading Sync
OutputBaseFilename=AmmarTrading Sync Setup
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Uninstallable=yes
```

Install binaries under Program Files, never place runtime config/logs there, add Start Menu and opt-in desktop shortcuts, run the WebView2 bootstrapper silently only when the runtime registry key is absent, and launch the app unelevated after setup. Do not add uninstall delete directives for `%LOCALAPPDATA%\AmmarTrading`, scheduled tasks, or OneDrive folders.

- [ ] **Step 4: Document operator flow and legacy import**

Update the setup guide with: install, OneDrive sign-in prerequisite, selecting account cards, handling schema-v2/header-only/duplicate states, verifying local publication, verifying reporting-PC receipt, upgrade, and uninstall preservation. Remove instructions that tell the operator to double-click the browser CMD launcher.

- [ ] **Step 5: Build on the configured Windows worker**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows\scripts\Build-AmmarTradingSync.ps1 -Configuration Release
```

Expected: installer and SHA-256 manifest exist; build script exits 0.

- [ ] **Step 6: Install/upgrade/uninstall acceptance in a disposable Windows test profile**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows\scripts\Test-AmmarTradingSyncAcceptance.ps1 -Installer 'artifacts\windows\AmmarTrading Sync Setup.exe'
```

Expected: install and upgrade preserve mappings/history; app opens without Edge/console; uninstall removes binaries/shortcuts while runtime data remains.

- [ ] **Step 7: Commit installer and documentation**

```bash
git add windows/installer windows/scripts CSV_ONEDRIVE_EXCEL_SETUP.md
git commit -m "build: add AmmarTrading Sync Windows installer"
```

### Task 10: End-to-end VPS and reporting-PC acceptance

**Files:**
- Modify: `windows/scripts/Test-AmmarTradingSyncAcceptance.ps1`
- Modify: `tests/Run-WindowsProductionAcceptance.ps1`
- Modify: `DELIVERABLES.md`

**Interfaces:**
- Consumes: signed/internal installer candidate, a test VPS with at least two MT4 schema-v3 sources, signed-in OneDrive, and the reporting PC.
- Produces: timestamped acceptance JSON/screenshots/logs and a release-ready installer hash; no production customer data is committed.

- [ ] **Step 1: Add an end-to-end acceptance mode**

Require explicit parameters for VPS name, expected account numbers, OneDrive root, and evidence output. Assert each selected account has exactly one mapping, destination hash equals source hash, task state is Ready, and `CloudDeliveryVerified` remains false on the VPS.

```powershell
foreach($account in $ExpectedAccountNumber) {
    $destination = Join-Path $OneDriveRoot "AmmarTrading\Account_$account\Baskets.csv"
    if(-not (Test-Path -LiteralPath $destination)) { throw "Missing local publication for $account" }
}
```

- [ ] **Step 2: Run complete automated regression before VPS mutation**

```bash
cd prototypes/money-machine-sync-wizard && npm test && cd ../..
dotnet test windows/AmmarTrading.Sync.sln -c Release -p:EnableWindowsTargeting=true
```

```powershell
pwsh -NoProfile -File tests/Test-AmmarTradingMt4Discovery.ps1
pwsh -NoProfile -File tests/Test-AmmarTradingBatchSetup.ps1
pwsh -NoProfile -File tests/Run-WindowsProductionAcceptance.ps1 -StagingOnly
```

Expected: every suite passes before deployment.

- [ ] **Step 3: Install and configure two test MT4 accounts on the VPS**

Install the candidate, launch `AmmarTrading Sync`, confirm no browser/console process appears, select two eligible account cards, select the active OneDrive root, and complete setup. Capture all five screens and monitoring status.

- [ ] **Step 4: Verify restart-safe sync with the app closed**

Close the app, update a source fixture or wait for a real EA write, run the scheduled task, compare source/destination SHA-256, restart/log on to the VPS, and confirm the catch-up task publishes a newer source without opening the app.

- [ ] **Step 5: Prove physical receipt on the reporting PC**

On the reporting PC, wait for OneDrive to report sync complete, then verify both local paths exist and hashes match their VPS-published counterparts. Record `CloudDeliveryVerified=true` only in the reporting-PC acceptance evidence, then refresh Excel Master/Power Query and confirm both accounts load.

- [ ] **Step 6: Review evidence and commit acceptance automation**

```bash
git add windows/scripts/Test-AmmarTradingSyncAcceptance.ps1 tests/Run-WindowsProductionAcceptance.ps1 DELIVERABLES.md
git commit -m "test: verify AmmarTrading Sync end to end"
```

Expected: the release checklist identifies the installer by filename, version, SHA-256, tested Windows version, tested account numbers, and acceptance timestamp.

## Final verification gate

Before describing the work as complete, invoke `superpowers:verification-before-completion` and run:

```bash
cd prototypes/money-machine-sync-wizard && npm test && cd ../..
dotnet test windows/AmmarTrading.Sync.sln -c Release -p:EnableWindowsTargeting=true
git diff --check
```

```powershell
pwsh -NoProfile -File tests/Test-AmmarTradingMt4Discovery.ps1
pwsh -NoProfile -File tests/Test-AmmarTradingBatchSetup.ps1
pwsh -NoProfile -File tests/Test-MoneyMachineCsvSync.ps1
pwsh -NoProfile -File tests/Test-MoneyMachineSyncSetup.ps1
```

On Windows, also run the build and acceptance scripts from Tasks 9 and 10. Report exact pass counts, installer path, SHA-256, and any acceptance step that was not run. Do not claim OneDrive reporting-PC receipt from VPS-only evidence.
