# OneDrive Validation and Acceptance Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining OneDrive production-readiness gaps by enforcing the complete schema-v3 contract, escaping MQL4 CSV text, wiring freshness reporting into Excel, and producing fresh Windows and receiver-side acceptance evidence.

**Architecture:** Move the exact schema-v3 parsing rules into a focused PowerShell module consumed by the sync script and tests. Keep local publication atomic and serialized, add bounded observability plus a receiver-side heartbeat checker, then use one Windows PowerShell 5.1 acceptance runner to collect non-GUI evidence while retaining explicit interactive gates for OneDrive delivery and Excel refresh.

**Tech Stack:** MQL4, Windows PowerShell 5.1, Task Scheduler, OneDrive desktop sync, Power Query M, Excel COM for workbook provisioning and inspection, Bash/Git for repository verification.

**Spec:** `docs/superpowers/specs/2026-08-20-onedrive-csv-production-readiness-design.md`

## Global Constraints

- Production changes are limited to the V3 reporting writer, `MoneyMachineCsvSync`, its Power Query files, the supplied workbook, tests, and operating documentation.
- Do not change trading entries, grid logic, basket management, trailing, exits, or risk decisions.
- Preserve the exact schema-v3 header: 71 columns in the existing order.
- A valid header-only schema-v3 CSV is a zero-row current run and must replace stale destination data.
- The scheduled runtime is Windows PowerShell 5.1; the installer may be launched from Windows PowerShell 5.1 or PowerShell 7.
- Call a successful local write `LocalPublished`; never treat it as cloud-delivery proof.
- Keep credentials, OneDrive secrets, private keys, personal machine details, and unredacted source paths out of Git artifacts.
- Existing schema-v2 files remain workbook-import compatibility only; the production sync accepts schema v3.
- Preserve the previous task definitions, automation directory, workbook, account configuration, state, and last known-good destination until one full daily cycle and receiver refresh pass.
- Run Windows-only claims on the Windows worker; Linux-only evidence cannot certify Task Scheduler, OneDrive, Excel, or MetaTrader behavior.

## Current Baseline and Required Gates

- The deployed sync and installer hashes currently match the worktree versions.
- Local publication currently produces a 71-column, 10-row destination whose SHA-256 matches `SyncStatus.json`.
- The live heartbeat currently reports `CloudDeliveryVerified: false`; this is correct and must remain false on the publishing machine.
- Windows PowerShell 5.1 exposed default-parameter failures in both `Sync-BasketsToOneDrive.ps1` and `Test-MoneyMachineCsvSync.ps1` when `$PSScriptRoot` is evaluated during parameter binding.
- The current validator accepted two duplicate rows containing `Direction=SIDEWAYS`, `DurationSeconds=not-an-integer`, and an incorrect `TradeDate`. The remediation is not complete until this exact adversarial case fails without replacing the prior destination.
- The current production schema-v3 history uses blank `MaxOrdersInBasket` for the disabled value because of the existing writer. Preserve those rows by accepting blank only for this field as legacy value `0`; all new EA rows must serialize explicit `0`.

---

### Task 1: Make the PowerShell Entry Points Reliable and Test Process Exit Semantics

**Files:**
- Modify: `automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1:1-15`
- Modify: `tests/Test-MoneyMachineCsvSync.ps1:1-7`
- Test: `tests/Test-MoneyMachineCsvSync.ps1`

**Interfaces:**
- Consumes: optional `-ConfigPath` and `-ScriptPath` strings.
- Produces: defaults resolved after parameter binding; direct execution exits `0` for success and nonzero for any enabled-account error.

- [ ] **Step 1: Add a regression that launches the test with no `-ScriptPath`**

Add a child-process wrapper at the end of the Windows acceptance path rather than dot-sourcing the test. The command must be equivalent to:

```powershell
$windowsPowerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$testProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File', (Join-Path $PSScriptRoot 'Test-MoneyMachineCsvSync.ps1')
) -Wait -PassThru
if($testProcess.ExitCode -ne 0) { throw "Default test invocation exited $($testProcess.ExitCode)." }
```

- [ ] **Step 2: Run the default invocation on Windows PowerShell 5.1 and confirm the existing failure**

Run:

```powershell
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\tests\Test-MoneyMachineCsvSync.ps1
```

Expected before the fix: nonzero with `Join-Path ... Path ... empty string` from the parameter default.

- [ ] **Step 3: Resolve defaults after each `param` block**

Use nullable parameter defaults and resolve them only after `$PSScriptRoot` and `$PSCommandPath` are available:

```powershell
param(
    [string]$ConfigPath,
    [switch]$StartupCatchup,
    [switch]$AsLibrary,
    [int]$StableCheckSeconds = 2,
    [int]$MaxRetries = 3
)

$ScriptRoot = Split-Path -Parent $PSCommandPath
if([string]::IsNullOrWhiteSpace($ScriptRoot)) { throw 'Could not resolve the sync script directory.' }
if([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $ScriptRoot 'accounts.csv' }
```

Apply the same pattern to the test:

```powershell
param([string]$ScriptPath)
if([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1'
}
```

- [ ] **Step 4: Add a child-process failure assertion**

Create a temporary missing-source configuration, invoke the sync as a child process, and assert a nonzero exit:

```powershell
$process = Start-Process -FilePath $windowsPowerShell -ArgumentList @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File', $ScriptPath,
    '-ConfigPath', $missingConfig,
    '-StableCheckSeconds', '0',
    '-MaxRetries', '1'
) -Wait -PassThru
if($process.ExitCode -eq 0) { throw 'An enabled missing source must return a nonzero process exit code.' }
```

- [ ] **Step 5: Run the test in both supported invocation styles**

Run:

```powershell
.\tests\Test-MoneyMachineCsvSync.ps1
.\tests\Test-MoneyMachineCsvSync.ps1 -ScriptPath .\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1
```

Expected: both print `MoneyMachine CSV sync tests passed.` and exit `0`.

- [ ] **Step 6: Commit the entry-point fix**

```bash
git add automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1 tests/Test-MoneyMachineCsvSync.ps1
git commit -m "fix: make sync tests reliable on PowerShell 5.1"
```

---

### Task 2: Enforce the Complete Schema-v3 Contract in a Focused Module

**Files:**
- Create: `automation/MoneyMachineCsvSync/MoneyMachineCsvSchemaV3.psm1`
- Create: `tests/fixtures/AGOLD___Baskets_v3_quoted.csv`
- Modify: `automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1:16-82`
- Modify: `tests/Test-MoneyMachineCsvSync.ps1`
- Test: `tests/Test-MoneyMachineCsvSync.ps1`

**Interfaces:**
- Produces: `Get-MoneyMachineSchemaV3Columns -> string[]`.
- Produces: `Read-MoneyMachineBasketsCsv -Path <string> -ExpectedLogin <string> -> PSCustomObject { Rows; RowCount; Header }` or throws a row/field-specific validation error.
- Consumes: the module from `Sync-BasketsToOneDrive.ps1` using an absolute path relative to `$ScriptRoot`.

- [ ] **Step 1: Add adversarial tests before extracting the validator**

Extend `Test-MoneyMachineCsvSync.ps1` with isolated cases that each preserve a known-good destination:

```powershell
$invalidCases = @(
    @{ Name='duplicate key'; Mutate={ param($rows) @($rows[0], $rows[0]) }; Error='duplicate' },
    @{ Name='direction enum'; Mutate={ param($rows) $rows[0].Direction='SIDEWAYS'; $rows }; Error='Direction' },
    @{ Name='duration type'; Mutate={ param($rows) $rows[0].DurationSeconds='not-an-integer'; $rows }; Error='DurationSeconds' },
    @{ Name='trade date agreement'; Mutate={ param($rows) $rows[0].TradeDate='1999-01-01'; $rows }; Error='TradeDate' }
)
```

For every case, publish a valid baseline first, write the malformed source, call `Invoke-MoneyMachineCsvSync`, require `Status='Error'`, require the expected field name in `Message`, and require the destination SHA-256 to remain unchanged.

- [ ] **Step 2: Add exact type, enum, and relationship coverage**

Test these contracts independently so one failure cannot mask another:

```powershell
$booleanFields = @('UseBasketTrailingTP','KillSwitchEnable','RegimeEnable','EnableTradingDaysFilter','TradeMonday','TradeTuesday','TradeWednesday','TradeThursday','TradeFriday','EnableRecoveryStepUp')
$enumValues = @{
    Direction = @('BUY','SELL')
    CloseReason = @('TP','KILL','OTHER')
    OutcomeClass = @('KILL','NORMAL_PROFIT','RECOVERY_PROFIT','OTHER')
    RegimeAction = @('0','1')
}
```

Add cases for an invalid boolean (`true` instead of `0` or `1`), invalid decimal, invalid timestamp, `EndTime < StartTime`, a `DurationSeconds` mismatch, missing `RunID`, missing `BasketID`, mixed accounts, and `CsvSchemaVersion != 3`.

- [ ] **Step 3: Add a standards-aware quoted-field fixture**

Create `AGOLD___Baskets_v3_quoted.csv` with the exact 71-column header and one valid row where `BrokerName` contains a comma and quotes and another text field contains an embedded CRLF. Parse it with `Import-Csv` and assert:

```powershell
if($quotedResult.RowCount -ne 1) { throw 'Quoted fixture must contain one logical record.' }
if($quotedResult.Rows[0].BrokerName -ne 'Broker, "Gold" Desk') { throw 'Quoted BrokerName was not preserved.' }
```

- [ ] **Step 4: Run the tests and verify the current validator fails the new cases**

Run:

```powershell
.\tests\Test-MoneyMachineCsvSync.ps1
```

Expected before implementation: the invalid rows return `Success` or the quoted fixture is mishandled.

- [ ] **Step 5: Create the schema module with exact field groups**

Move the 71-column array into `MoneyMachineCsvSchemaV3.psm1`. Define invariant field groups and controlled values:

```powershell
$script:BooleanFields = @('UseBasketTrailingTP','KillSwitchEnable','RegimeEnable','EnableTradingDaysFilter','TradeMonday','TradeTuesday','TradeWednesday','TradeThursday','TradeFriday','EnableRecoveryStepUp')
$script:TimestampFields = @('StartTime','EndTime','RunStartTime')
$script:DateFields = @('TradeDate')
$script:ControlledValues = @{
    Direction = @('BUY','SELL')
    CloseReason = @('TP','KILL','OTHER')
    OutcomeClass = @('KILL','NORMAL_PROFIT','RECOVERY_PROFIT','OTHER')
    RegimeAction = @('0','1')
}
$script:RequiredKeyFields = @('AccountNumber','RunID','BasketID')
$script:IntegerFields = @(
    'BasketID','Timeframe','DurationSeconds','OrdersCount','MaxOrdersConcurrent','TimesNearKill',
    'ExposureBlocks','PipsStep','MaxOrdersInBasket','Magic','PointsPerPip','Tral','TralStart',
    'MaxSpread','TimeStart','TimeEnd','OpenTime','NewBasketDelaySeconds','SpeedEA',
    'KillCooldownMinutes','RegimeAction','RegimeADXPeriod','RegimeADXBars','RegimeRangeBars',
    'RegimeRecoveryBars','RecoveryWaitMinutes','CsvSchemaVersion'
)
$script:DecimalFields = @(
    'TotalLots','FixedLots','MaxTotalLots','MaxFloatingDrawdownAbs','MaxFloatingProfit','ClosePL',
    'SpreadAtEntry','EquityAtEntry','HeadroomAtEntry','MinHeadroom','TakeProfit','KillEquityLevel',
    'MaxTotalLotsInBasket','EquityAtExit','BalanceAfter','RunStartBalance','TrailingStart',
    'TrailingStep','RegimeADXLevel','RecoveryMaxTotalLotsInBasket'
)
$script:TextFields = @('AccountNumber','BrokerName','Symbol','SymbolNormalized','RunID','EAName','EAVersion')
```

Use `[System.Globalization.CultureInfo]::InvariantCulture`, `IntegerStyles`, `NumberStyles`, and exact formats `yyyy-MM-dd HH:mm:ss` and `yyyy-MM-dd`. Unit-test that the integer, decimal, boolean, timestamp, date, controlled-value, and text groups classify all 71 columns exactly once, allowing controlled fields to reuse their underlying text/integer parser deliberately.

- [ ] **Step 6: Implement record-width and duplicate-key checks**

Read the raw file using `Microsoft.VisualBasic.FileIO.TextFieldParser` with `HasFieldsEnclosedInQuotes=$true`, validate the first logical record as the exact header, require exactly 71 fields in every subsequent logical record, then parse with `ConvertFrom-Csv` only after width validation. Track the candidate key using an ordinal hash set:

```powershell
$key = '{0}|{1}|{2}' -f $row.AccountNumber,$row.RunID,$row.BasketID
if(-not $keys.Add($key)) { throw "Row $rowNumber has duplicate basket key '$key'." }
```

A file containing only the exact header must return `RowCount = 0`.

- [ ] **Step 7: Implement semantic relationships**

After invariant parsing, enforce:

```powershell
if($endTime -lt $startTime) { throw "Row $rowNumber EndTime precedes StartTime." }
if([int64]($endTime - $startTime).TotalSeconds -ne $duration) { throw "Row $rowNumber DurationSeconds does not match StartTime and EndTime." }
if($tradeDate -ne $startTime.Date) { throw "Row $rowNumber TradeDate does not match StartTime." }
```

Require every row account to equal `ExpectedLogin`, schema version to equal `3`, and all boolean values to be exactly `0` or `1`.

- [ ] **Step 8: Import the module from the sync script and delete the duplicated validator**

Use:

```powershell
$schemaModule = Join-Path $ScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
if(-not (Test-Path -LiteralPath $schemaModule)) { throw "Schema module not found: $schemaModule" }
Import-Module -Name $schemaModule -Force -ErrorAction Stop
```

Replace both source and temporary-file validation calls with `Read-MoneyMachineBasketsCsv`.

- [ ] **Step 9: Run all sync regressions on Windows PowerShell 5.1**

Run:

```powershell
.\tests\Test-MoneyMachineCsvSync.ps1
```

Expected: valid, header-only, and quoted cases succeed; every invalid case returns `Error`; every invalid case preserves the baseline destination hash.

- [ ] **Step 10: Commit the complete validator**

```bash
git add automation/MoneyMachineCsvSync/MoneyMachineCsvSchemaV3.psm1 automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1 tests/Test-MoneyMachineCsvSync.ps1 tests/fixtures/AGOLD___Baskets_v3_quoted.csv
git commit -m "feat: enforce complete schema v3 validation"
```

---

### Task 3: Escape Every MQL4 Text Field Without Changing Trading Behavior

**Files:**
- Modify: `AmmarTradingGoldEA - ref reset every bar - V3.mq4:1081-1141`
- Modify: `AmmarTradingGoldEA - ref reset every bar - V3.mq4:1620-1681`
- Modify: `tests/Test-V3TelemetryReportingContract.ps1`
- Test: `tests/Test-V3TelemetryReportingContract.ps1`
- Test: `tests/fixtures/AGOLD___Baskets_v3_quoted.csv`

**Interfaces:**
- Produces: `string TelemetryCsvEscape(string value)` implementing RFC-style CSV quoting for commas, quotes, CR, and LF.
- Consumes: all textual telemetry values before they are appended to `line`.

- [ ] **Step 1: Add a failing telemetry contract assertion**

Require the helper and its escaping operations:

```powershell
foreach($token in @('TelemetryCsvEscape','StringReplace(value, """", """"")','StringFind(value, ",")','StringFind(value, "\r")','StringFind(value, "\n")')) {
    if($source -notmatch [regex]::Escape($token)) { throw "CSV escaping contract is missing: $token" }
}
```

Also require `TelemetryCsvEscape` around `AccountCompany()`, `Symbol()`, normalized symbol, direction, close reason, outcome class, `RunID`, `EAName`, and `EAVersion` output expressions.

Add a separate assertion that `MaxOrdersInBasket` is always serialized with `IntegerToString`, including the disabled value `0`; the current conditional blank conflicts with invariant integer validation.

- [ ] **Step 2: Run the contract test and confirm it fails**

Run:

```powershell
.\tests\Test-V3TelemetryReportingContract.ps1
```

Expected before implementation: failure stating `TelemetryCsvEscape` is missing.

- [ ] **Step 3: Implement the escaping helper**

Add a reporting-only helper near the other telemetry helpers:

```cpp
string TelemetryCsvEscape(string value)
{
   bool quote = StringFind(value, ",") >= 0 ||
                StringFind(value, "\"") >= 0 ||
                StringFind(value, "\r") >= 0 ||
                StringFind(value, "\n") >= 0;
   if(!quote) return value;
   StringReplace(value, "\"", "\"\"");
   return "\"" + value + "\"";
}
```

- [ ] **Step 4: Route every string-valued telemetry field through the helper**

Change only CSV serialization expressions. For example:

```cpp
line = line + accountNumber + "," + TelemetryCsvEscape(brokerName) + "," + IntegerToString(g_Telemetry_BasketID) + ",";
line = line + TelemetryCsvEscape(Symbol()) + "," + TelemetryCsvEscape(symbolNormalized) + "," + timeframe + ",";
line = line + TelemetryCsvEscape(g_Telemetry_RunID) + ",";
line = line + IntegerToString(g_Telemetry_MaxOrdersInBasketSnap) + ",";
```

Do not alter signal, order, basket, exit, or risk code.

- [ ] **Step 5: Run the static contract and compile the EA**

Run the PowerShell contract, then compile in an isolated Windows MT4 `MQL4\Experts\CodexTest` folder with the configured MetaEditor. Require zero compile errors; record warnings separately.

- [ ] **Step 6: Prove downstream compatibility with the quoted fixture**

Run `Test-MoneyMachineCsvSync.ps1` and require the quoted fixture to publish as one logical row with all 71 columns aligned.

- [ ] **Step 7: Commit the reporting-only MQL4 change**

```bash
git add 'AmmarTradingGoldEA - ref reset every bar - V3.mq4' tests/Test-V3TelemetryReportingContract.ps1 tests/fixtures/AGOLD___Baskets_v3_quoted.csv
git commit -m "fix: escape schema v3 CSV text fields"
```

---

### Task 4: Complete Sync Observability and Installer Preflight

**Files:**
- Create: `automation/MoneyMachineCsvSync/Test-MoneyMachineSyncStatus.ps1`
- Modify: `automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1:28-34`
- Modify: `automation/MoneyMachineCsvSync/Install-BasketsSyncTask.ps1`
- Modify: `tests/Test-MoneyMachineCsvSync.ps1`

**Interfaces:**
- Produces: rotating `logs/sync.log` capped at 5 MiB with `sync.log.1` through `sync.log.5`.
- Produces: atomic `state/last-run.json` containing run timestamps, overall status, result rows, and per-account success state used by startup catch-up.
- Produces: `Test-MoneyMachineSyncStatus.ps1 -OneDriveRoot <string> -ExpectedAccount <string[]> -FreshnessHours <double=26>`; exits nonzero for missing, unsuccessful, malformed, or stale heartbeats.
- Produces: `Get-BasketsSyncTaskDefinition` as a pure installer function returning actions, triggers, principal, and settings without registration.

- [ ] **Step 1: Add failing log-rotation and receiver-check tests**

Create a log larger than 5 MiB, call `Write-SyncLog`, and assert `sync.log.1` exists and no more than five archives remain. Create fresh, stale, missing, malformed, and unsuccessful heartbeat fixtures; invoke the checker as a child process and assert the expected exit codes.

- [ ] **Step 2: Implement bounded log rotation before `Add-Content`**

Use exact constants:

```powershell
$maxLogBytes = 5MB
$retainedLogs = 5
for($index = $retainedLogs; $index -ge 1; $index--) {
    $source = if($index -eq 1) { $logPath } else { "$logPath.$($index - 1)" }
    $target = "$logPath.$index"
    if(Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $target -Force }
}
```

Rotate only while the global sync mutex is held.

- [ ] **Step 3: Implement the receiver-side freshness checker**

For each expected account, read `MoneyMachine\Account_<login>\SyncStatus.json`, require `Status='Success'`, parse `PublishedUtc` as UTC, require age `<= FreshnessHours`, and require `CloudDeliveryVerified` to remain false because arrival at the receiver is the independent proof. Emit JSON result rows and exit `1` if any result is not fresh.

- [ ] **Step 4: Make `last-run.json` a complete atomic run summary**

Capture `StartedUtc` before account work and `CompletedUtc` after all results are known. Persist this shape atomically:

```powershell
$summary = [ordered]@{
    StartedUtc = $startedUtc
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    OverallStatus = if(@($results | Where-Object Status -eq 'Error').Count) { 'Error' } else { 'Success' }
    Accounts = $state
    Results = @($results)
}
```

Update `Get-LastRunState` to return `Accounts` for startup-catch-up decisions while tolerating the pre-remediation account-map shape during the first upgraded run. Do not store source or OneDrive paths in the summary.

- [ ] **Step 5: Extract a pure task-definition function**

Define:

```powershell
function Get-BasketsSyncTaskDefinition {
    param(
        [string]$ResolvedConfig,[string]$SyncScript,[string]$PowerShellPath,
        [string]$WorkingDirectory,[datetime]$DailyTime,[string]$TaskName,[string]$PrincipalUser
    )
    $baseArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $SyncScript,$ResolvedConfig
    $dailyAction = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $baseArguments -WorkingDirectory $WorkingDirectory
    $catchupAction = New-ScheduledTaskAction -Execute $PowerShellPath -Argument "$baseArguments -StartupCatchup" -WorkingDirectory $WorkingDirectory
    [pscustomobject]@{
        DailyAction = $dailyAction
        CatchupAction = $catchupAction
        DailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyTime
        LogonTrigger = New-ScheduledTaskTrigger -AtLogOn
        Principal = New-ScheduledTaskPrincipal -UserId $PrincipalUser -LogonType Interactive -RunLevel Limited
        Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    }
}
```

Resolve the script, config, working directory, and Windows PowerShell executable before calling it.

- [ ] **Step 6: Preflight every required ScheduledTasks command**

Require these commands before any registration:

```powershell
$requiredCommands = @('New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','Register-ScheduledTask')
foreach($command in $requiredCommands) {
    if(-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required ScheduledTasks command is unavailable: $command" }
}
```

- [ ] **Step 7: Test the task definition with `-WhatIf` and without registration**

Assert the executable is Windows PowerShell 5.1, both paths are absolute and quoted, the working directory is absolute, the current OneDrive user is the principal, `MultipleInstances=IgnoreNew`, restart count is `3`, restart interval is `5` minutes, and execution limit is `15` minutes.

- [ ] **Step 8: Run the sync and installer contract tests on Windows PowerShell 5.1**

Expected: rotation, receiver freshness, task definition, and all prior sync tests pass without changing real scheduled tasks.

- [ ] **Step 9: Commit observability and installer hardening**

```bash
git add automation/MoneyMachineCsvSync/Sync-BasketsToOneDrive.ps1 automation/MoneyMachineCsvSync/Install-BasketsSyncTask.ps1 automation/MoneyMachineCsvSync/Test-MoneyMachineSyncStatus.ps1 tests/Test-MoneyMachineCsvSync.ps1
git commit -m "feat: complete sync monitoring and task preflight"
```

---

### Task 5: Correct Power Query Identity and Prewire the Workbook

**Files:**
- Create: `automation/MoneyMachineCsvSync/PowerQuery/MoneyMachine_SyncStatus.m`
- Create: `automation/MoneyMachineCsvSync/Install-MoneyMachineWorkbookQueries.ps1`
- Create: `tests/Test-MoneyMachinePowerQueryContract.ps1`
- Modify: `automation/MoneyMachineCsvSync/PowerQuery/MoneyMachine_Baskets.m`
- Modify: `outputs/019fe209-a32e-7040-84de-fe9e289219a5/MoneyMachine_Account_Analysis.xlsx`
- Modify: `CSV_ONEDRIVE_EXCEL_SETUP.md`

**Interfaces:**
- Produces: `MoneyMachine_Baskets` with 71 source columns followed by `FolderAccountNumber`, `RunKey`, `FolderAccountMismatch`, and `ConfigFingerprint`.
- Produces: `MoneyMachine_SyncStatus` with account, status, row count, hashes, source/publication UTC, heartbeat age hours, cloud flag, and `IsFresh` using 26 hours.
- Produces: a workbook containing both queries/connections with refresh-on-open enabled and background refresh disabled.

- [ ] **Step 1: Add a failing static Power Query contract**

Declare the exact 37 fingerprint fields in stable order:

```powershell
$fingerprintFields = @(
  'FixedLots','Magic','PointsPerPip','PipsStep','TakeProfit','Tral','TralStart','MaxSpread',
  'TimeStart','TimeEnd','OpenTime','NewBasketDelaySeconds','SpeedEA','UseBasketTrailingTP',
  'TrailingStart','TrailingStep','KillSwitchEnable','KillEquityLevel','KillCooldownMinutes',
  'MaxOrdersInBasket','MaxTotalLotsInBasket','RegimeEnable','RegimeAction','RegimeADXPeriod',
  'RegimeADXLevel','RegimeADXBars','RegimeRangeBars','RegimeRecoveryBars','EnableTradingDaysFilter',
  'TradeMonday','TradeTuesday','TradeWednesday','TradeThursday','TradeFriday',
  'EnableRecoveryStepUp','RecoveryWaitMinutes','RecoveryMaxTotalLotsInBasket'
)
```

Require each exactly once, require `Text.From(_, "en-US")`, require the final 75-column order, and require the sync-status query to contain `Duration.TotalHours`, `26`, and `IsFresh`.

- [ ] **Step 2: Update the basket query**

Use the 37 fields above and invariant conversion:

```powerquery
Text.Combine(
    List.Transform(FingerprintValues, each if _ = null then "" else Text.From(_, "en-US")),
    "|"
)
```

Explicitly reorder the final table rather than relying on append order.

- [ ] **Step 3: Create the sync-status query**

Read only files named `SyncStatus.json` beneath `Account_` folders, parse with `Json.Document`, normalize UTC values, compute `HeartbeatAgeHours`, and set `IsFresh = [Status] = "Success" and [HeartbeatAgeHours] <= 26`.

- [ ] **Step 4: Implement workbook provisioning through Excel COM**

The provisioning script must open a copy of the tracked workbook, remove only queries named `MoneyMachine_Baskets` and `MoneyMachine_SyncStatus`, add both from the checked-in M files, load them into the existing `Basket Data` table and a new `Sync Status` table, set `RefreshOnFileOpen=$true`, set `BackgroundQuery=$false`, refresh synchronously, save, and close Excel in `finally`.

Use the Excel Mashup provider for each checked-in query:

```powershell
$excel = New-Object -ComObject Excel.Application
$workbook = $null
try {
    $workbook = $excel.Workbooks.Open($WorkbookPath)
    foreach($queryName in @('MoneyMachine_Baskets','MoneyMachine_SyncStatus')) {
        try { $workbook.Queries.Item($queryName).Delete() } catch { }
        $formula = Get-Content -LiteralPath (Join-Path $PowerQueryRoot "$queryName.m") -Raw
        [void]$workbook.Queries.Add($queryName, $formula)
    }
    $connection = 'OLEDB;Provider=Microsoft.Mashup.OleDb.1;Data Source=$Workbook$;Location={0};Extended Properties=""'
    try { $null = $workbook.Worksheets.Item('Sync Status') } catch {
        $newSheet = $workbook.Worksheets.Add()
        $newSheet.Name = 'Sync Status'
    }
    $targets = @{
        MoneyMachine_Baskets = @{ Sheet='Basket Data'; Table='BasketDataTable'; Cell='A1' }
        MoneyMachine_SyncStatus = @{ Sheet='Sync Status'; Table='SyncStatusTable'; Cell='A1' }
    }
    foreach($queryName in $targets.Keys) {
        $target = $targets[$queryName]
        $sheet = $workbook.Worksheets.Item($target.Sheet)
        try { $sheet.ListObjects.Item($target.Table).Delete() } catch { }
        $listObject = $sheet.ListObjects.Add(0, ($connection -f $queryName), $null, 1, $sheet.Range($target.Cell))
        $listObject.Name = $target.Table
        $listObject.QueryTable.CommandType = 2
        $listObject.QueryTable.CommandText = "SELECT * FROM [$queryName]"
        $listObject.QueryTable.BackgroundQuery = $false
        $listObject.QueryTable.RefreshOnFileOpen = $true
    }
    $workbook.RefreshAll()
    $excel.CalculateUntilAsyncQueriesDone()
    $workbook.Save()
} finally {
    if($workbook) { $workbook.Close($false) }
    $excel.Quit()
    if($workbook) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($workbook) | Out-Null }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) | Out-Null
}
```

The implementation must address tables by exact worksheet/table name and must not delete formulas, manual fields, or unrelated workbook connections.

- [ ] **Step 5: Provision and inspect the tracked workbook on Windows**

Run the script against `MoneyMachine_Account_Analysis.xlsx`, reopen it through Excel COM, and assert both queries and both connections exist, both background-refresh flags are false, and the two destination tables have the expected names.

- [ ] **Step 6: Update the operating guide**

Make the prewired workbook the normal path. Retain manual query recreation only as recovery. Document the `Sync Status` table, 26-hour SLO, synchronous Refresh All behavior, and the distinction between local publication and receiver-observed delivery.

- [ ] **Step 7: Run the Power Query static test and Excel COM inspection**

Expected: exact 37-field contract passes; workbook package includes query connections; both queries refresh from a staging OneDrive root without background calculation races.

- [ ] **Step 8: Commit the query and workbook deliverables**

```bash
git add automation/MoneyMachineCsvSync/PowerQuery/MoneyMachine_Baskets.m automation/MoneyMachineCsvSync/PowerQuery/MoneyMachine_SyncStatus.m automation/MoneyMachineCsvSync/Install-MoneyMachineWorkbookQueries.ps1 tests/Test-MoneyMachinePowerQueryContract.ps1 outputs/019fe209-a32e-7040-84de-fe9e289219a5/MoneyMachine_Account_Analysis.xlsx CSV_ONEDRIVE_EXCEL_SETUP.md
git commit -m "feat: prewire OneDrive freshness reporting in Excel"
```

---

### Task 6: Build the Windows Production Acceptance Runner

**Files:**
- Create: `tests/Run-WindowsProductionAcceptance.ps1`
- Create at runtime: `audit/windows-production-acceptance.json`
- Modify: `.gitignore` only if machine-local acceptance artifacts are not already ignored

**Interfaces:**
- Produces: `Run-WindowsProductionAcceptance.ps1 -StagingRoot <string> [-MetaEditorPath <string>] [-WorkbookPath <string>] [-OutputPath <string>]`.
- Produces: JSON with `StartedUtc`, `CompletedUtc`, redacted runtime details, named check results, artifact hashes, overall status, and no credentials or personal paths.
- Returns: `0` only when all required available checks pass; `3` when an explicitly optional product such as MetaEditor or Excel is unavailable; `1` for a failed required check.

- [ ] **Step 1: Write the acceptance result schema and redaction test**

Use result objects shaped as:

```powershell
[ordered]@{
    Name = 'schema-v3-adversarial-validation'
    Status = 'Pass'
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Message = 'Invalid rows were rejected and the prior destination hash was preserved.'
    Artifacts = @()
}
```

Test that serialized JSON contains no `C:\Users\`, computer name, source CSV path, OneDrive credential, or account configuration content.

- [ ] **Step 2: Implement non-GUI checks**

Include Windows PowerShell 5.1 version, valid/header-only/quoted/malformed/duplicate/type/enum/date cases, prior-destination preservation, hash consistency, mutex contention, atomic state/heartbeat writes, direct-process exit codes, installer preflight/task-definition inspection, 37-field fingerprint contract, and workbook package inspection.

- [ ] **Step 3: Add optional product checks**

When `MetaEditorPath` is supplied, compile the V3 MQ4 source in an isolated test directory and require zero errors. When Excel is installed and `WorkbookPath` is supplied, inspect the two queries/connections through Excel COM and refresh against staging; otherwise record `NotRun` and use exit `3` only when the caller marked that product check as required.

- [ ] **Step 4: Write the acceptance JSON atomically**

Write to a sibling `.tmp`, parse the temporary JSON back with `ConvertFrom-Json`, then replace/move it into `audit/windows-production-acceptance.json`. Include SHA-256 for produced CSV, heartbeat, compile log, and workbook evidence artifacts.

- [ ] **Step 5: Run the acceptance runner on the Windows worker**

Use a task-specific directory beneath `C:\CodexWorker\`, Windows PowerShell 5.1, and a staging OneDrive root. Expected: all non-GUI checks pass; optional GUI/product checks are explicitly `Pass` or `NotRun`, never silently omitted.

- [ ] **Step 6: Retrieve and validate the JSON on Linux**

Parse it, require overall success for all required checks, confirm every referenced artifact hash, and scan it for secrets and unredacted personal paths.

- [ ] **Step 7: Commit the acceptance runner**

```bash
git add tests/Run-WindowsProductionAcceptance.ps1 .gitignore
git commit -m "test: add Windows OneDrive production acceptance"
```

Do not commit machine-specific acceptance output unless it is redacted and intentionally retained as release evidence.

---

### Task 7: Stage, Deploy, Verify Receiver Delivery, and Exercise Rollback

**Files:**
- Modify: `CSV_ONEDRIVE_EXCEL_SETUP.md`
- Verify: `automation/MoneyMachineCsvSync/**`
- Verify: `outputs/019fe209-a32e-7040-84de-fe9e289219a5/MoneyMachine_Account_Analysis.xlsx`
- Produce outside Git: task-definition backups, configuration backup, state backup, destination backup, receiver screenshot/operator record

**Interfaces:**
- Consumes: the completed automation folder, acceptance runner, existing production `accounts.csv`, account `36097370`, and the OneDrive user `dryou`.
- Produces: a side-by-side deployment, reversible task cutover, receiver-observed heartbeat within 30 minutes, fresh Excel results, and one successful full daily cycle.

- [ ] **Step 1: Create exact rollback artifacts before cutover**

On the target Windows user session, create a timestamped directory beneath `$env:LOCALAPPDATA\MoneyMachineCsvSyncRollback`. Export both task XML definitions and copy the current automation directory, `accounts.csv`, `state`, destination `Baskets.csv`, `SyncStatus.json`, and workbook into it. Record SHA-256 for every copied file.

- [ ] **Step 2: Deploy side-by-side**

Copy the completed automation package to `$env:LOCALAPPDATA\MoneyMachineCsvSync-20260823-remediation`. Copy the existing production `accounts.csv` into that directory without printing it. Verify the module, sync script, installer, receiver checker, and both M files are present and hash-match the reviewed repository files.

- [ ] **Step 3: Run staging acceptance before changing tasks**

Use a dedicated staging root beneath `$env:OneDrive\MoneyMachine-StagingAcceptance`. Require valid, header-only, quoted, malformed, concurrent-run, task-definition, heartbeat, and child-process exit checks to pass. Remove only staging files created by the acceptance run after evidence is collected.

- [ ] **Step 4: Re-register both tasks as the OneDrive user**

Run the hardened installer from the `dryou` interactive session. Inspect both task actions, absolute arguments, working directory, principal, triggers, `IgnoreNew`, retry settings, and execution limit before triggering either task.

- [ ] **Step 5: Prove mutex and failure semantics through Task Scheduler**

Trigger daily and startup-catch-up tasks close together and require serialized completion with final result `0`. Then point a temporary copied task definition at a missing staging source and require nonzero `LastTaskResult`; do not alter the production configuration for the negative test.

- [ ] **Step 6: Publish production locally and verify identity**

Run the daily task once. Require destination/header row count, source hash, destination hash, heartbeat account, source last-write UTC, publication UTC, and `CloudDeliveryVerified=false` to agree. Call this result `LocalPublished` only.

- [ ] **Step 7: Verify OneDrive delivery from the receiving side**

Within 30 minutes, on the reporting Windows machine run:

```powershell
.\Test-MoneyMachineSyncStatus.ps1 -OneDriveRoot $env:OneDrive -ExpectedAccount 36097370 -FreshnessHours 26
```

Require exit `0`, record the receiver file timestamps and hashes, and capture a OneDrive web or receiver-side screenshot/operator confirmation. The publisher's local filesystem is not acceptable evidence for this step.

- [ ] **Step 8: Refresh and inspect the production workbook interactively**

Open the prewired workbook on the receiver, run Refresh All, wait for both synchronous queries, and confirm account `36097370`, expected row count, run ID, 37-field fingerprint, heartbeat age, and `IsFresh=true`. Save the workbook and record operator confirmation or screenshots.

- [ ] **Step 9: Exercise rollback without deleting the known-good destination**

Disable the remediated tasks, restore the previous task XML/actions and workbook from the rollback directory, verify the last known-good destination remains present, then restore the remediated definitions. Record both rollback and re-apply checks as passing.

- [ ] **Step 10: Observe one complete daily cycle**

Keep the previous automation and workbook. After the next scheduled daily run, require `LastTaskResult=0`, a receiver-fresh heartbeat, and a successful workbook refresh before removing rollback eligibility.

- [ ] **Step 11: Update the final operating guide and commit documentation**

Document installation, receiver verification, alert interpretation, workbook recovery, rollback, and the exact production-ready decision rule.

```bash
git add CSV_ONEDRIVE_EXCEL_SETUP.md
git commit -m "docs: add OneDrive acceptance and rollback runbook"
```

---

### Task 8: Final Evidence Review and Production-Ready Decision

**Files:**
- Verify: all files changed by Tasks 1-7
- Verify: `audit/onedrive-sync-production-findings.csv`
- Verify: `audit/windows-production-acceptance.json` when intentionally retained

**Interfaces:**
- Consumes: fresh repository tests, Windows acceptance JSON, receiver evidence, Excel refresh evidence, task state, and rollback hashes.
- Produces: a release decision mapping all 11 original findings to passing regression evidence or an explicitly verified operating control.

- [ ] **Step 1: Run all repository contracts freshly**

Run the sync, telemetry, Power Query, JSON, schema, and workbook-package checks. Run `git diff --check` and confirm no test depends on the developer's current working directory.

- [ ] **Step 2: Re-run the Windows acceptance suite**

Require Windows PowerShell 5.1 and every required check to pass in one fresh run. Verify the acceptance JSON timestamps belong to this release attempt and all artifact hashes still match.

- [ ] **Step 3: Map the original findings to evidence**

For findings 1 through 11, record the exact test/check name or operating evidence that closes it. Any `NotRun`, stale timestamp, missing receiver confirmation, missing Excel refresh, or missing rollback evidence keeps the release status at `Not production-ready`.

- [ ] **Step 4: Review source-control safety**

Run:

```bash
git status --short
git diff --check
git diff --name-only
rg -n -i "password|secret|token|private key|C:\\\\Users\\\\dryou" audit automation tests docs
```

Inspect matches; do not commit credentials, local account configuration, or unredacted machine paths.

- [ ] **Step 5: Declare the result accurately**

Declare `Production-ready` only if all automated Windows checks pass, the V3 source compiles with zero errors, the receiver heartbeat arrives within 30 minutes, the prewired workbook refreshes both queries and reports fresh data, Task Scheduler completes a daily cycle with result `0`, and rollback was demonstrated. Otherwise list the remaining external gate explicitly.
