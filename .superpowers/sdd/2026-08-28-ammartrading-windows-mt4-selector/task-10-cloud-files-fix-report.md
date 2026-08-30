# Task 10 Cloud Files Fix Report

## Scope and files changed

- `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1`: allows only Microsoft Cloud Files reparse tags `IO_REPARSE_TAG_CLOUD` through `IO_REPARSE_TAG_CLOUD_F` after direct `GetFileInformationByHandleEx(FileAttributeTagInfo)` inspection. The exception is gated to the canonical, registered signed-in OneDrive root and canonical descendants; all other reparse points still fail closed.
- `tests/Test-AmmarTradingCloudFiles.ps1`: behavior coverage for base, observed `0x9000701A`, and upper-bound Cloud Files tags; contained and escaped descendants; unregistered roots; and junction, symbolic-link, mount-point, and unknown tags.
- `tests/Test-AmmarTradingBatchSetup.ps1`: registers the synthetic legacy-migration fixture before asserting that its junction remains rejected, matching the trusted-root boundary.
- `tests/Test-WindowsProductionAcceptanceContract.ps1`: proves that a reporting-PC receipt with hydrated but hash-mismatched bytes is rejected. Existing assertions retain rejection of Offline, Recall-on-open, and Recall-on-data-access placeholder attributes.

## RED evidence

Before editing production code, the focused Windows PowerShell behavior test was run against the original module:

```text
& C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1 -SetupModulePath C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1
TEST-FAIL: OneDrive root contains a reparse point.
```

This was the expected failure: the original `Assert-AmmarTradingNoReparseAncestors` rejected the registered Cloud Files root solely from `FileAttributes.ReparsePoint`, without inspecting its tag.

## GREEN and suite verification

- Focused Cloud Files test: passed.
- Desktop security boundary test: passed.
- Windows production acceptance contract: passed, including hydrated-receipt hash mismatch and placeholder rejection.
- Sync/setup regression group: passed for transactional batch setup, MT4 discovery, CSV sync, and setup discovery/config/publication/rollback.
- .NET: `dotnet test AmmarTrading.Sync.sln --verbosity minimal` passed: 31 Core tests and 52 App tests (83 total).
- Node: `node --test windows/tests/installer-contract.test.mjs` passed: 18 tests.
- `git diff --check` passed.

## Security invariants retained

- UNC paths, mapped/network volumes, junctions, symbolic links, mount points, unknown tags, and containment escapes remain rejected.
- A Cloud Files tag alone does not confer trust: the root must exactly match the active signed-in OneDrive registration.
- Cloud-tag descendants are accepted only when canonically contained below that trusted root.
- Source-file, destination, request-file, atomic transaction, and local fixed-volume protections remain in place.
- VPS-local evidence still records `CloudDeliveryVerified=false`.
- Reporting-PC receipt still requires hydrated local bytes and an independent SHA-256 match to VPS evidence.

## Commit

`a80373948484cf96705b34c002d75901f7e22853` (`fix: allow trusted OneDrive Cloud Files roots`)

## Concerns / unrun verification

- The legacy browser-wizard acceptance test was not rerun because it is outside this native-app Cloud Files fix and its browser/prototype dependencies were not staged on the isolated worker. The focused, desktop-security, reporting-contract, sync/setup, .NET, and installer-Node suites above were run.
- No VPS, credentials, customer data, live OneDrive path, or generated installer binary was accessed or changed.

## Fix round 3 of 5: independent-review corrections

### Changes

- The only authoritative OneDrive trust source is the current-user `HKCU:\Software\Microsoft\OneDrive\Accounts\*\UserFolder` registration, accessed through `AmmarTradingOneDriveRegistrationResolver`. Environment values are retained only as non-authorizing activity hints, and only when their canonical path exactly equals a registered root.
- The shared local-path validator now requires `DriveType.Fixed`; UNC, DisplayRoot mapped drives, network, removable, RAM, and unknown volumes fail closed.
- Reparse decisions now use one `GetFileInformationByHandleEx(FileAttributeTagInfo)` result containing both `FileAttributes` and `ReparseTag`. Every existing module component uses that combined result. The numeric `0x9000001A` through `0x9000F01A` allowlist is unchanged, and name-surrogate tags are explicitly rejected.
- The focused helper now rejects a non-throwing negative action. The suite self-tests that behavior.
- Isolated fixtures set the private test seam or create and remove a unique synthetic current-user registration containing only their temporary local test root. No account name, email, credentials, customer data, or live path is used.

### Exact RED evidence

Runtime: Windows PowerShell through `win ps` on `zenbook_duo_25\dryou`. Each command exited `7` by design. Pass count `0`; fail count `1`; skip count `0`.

```text
win ps 'try { & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; Write-Output "TEST-PASS" } catch { Write-Output ("TEST-FAIL: " + $_.Exception.Message); exit 7 }'
```

- Runtime `4.4s`: `TEST-FAIL: Assert-ThrowsLike must fail when its action does not throw.`
- Runtime `12.0s`: `TEST-FAIL: Expected failure containing 'signed-in OneDrive root'.` This proves a forged environment root was incorrectly trusted before the registration-source change.
- Runtime `8.3s`: `TEST-FAIL: Expected failure containing 'local fixed filesystem'.` This was the Fixed-volume negative branch mutation.
- Runtime `13.5s`: `TEST-FAIL: Expected failure containing 'inconsistent reparse metadata'.` This was the combined-metadata negative branch mutation.

### Exact GREEN evidence

Runtime: Windows PowerShell through `win ps`; exit code `0`; pass count `1`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; Write-Output "FOCUSED_PASS_COUNT=1"'
```

Runtime `8.7s`; output included `AmmarTrading Cloud Files trust-boundary tests passed.` and `FOCUSED_PASS_COUNT=1`.

The focused test covers a real Windows `FileAttributeTagInfo` handle query, base Cloud Files, observed `0x9000701A`, upper `0x9000F01A`, forged environment root, stale registration, exact activity hint, multiple registrations, removable/RAM/unknown/network drives, inconsistent combined metadata, contained revalidation after mutation, and rejected junction/symlink/mount/unknown tags.

### Full relevant suite evidence

Runtime: Windows PowerShell through `win ps`; exit code `0`; pass count `13` scripts; fail count `0`; skip count `1` browser-acceptance prerequisite. The PowerShell scripts have no individual framework test-count output, so the counts are script invocations.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineSyncSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"'
```

Runtime `6.3s`; exit code `0`; pass count `2`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingBatchSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineCsvSync.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"'
```

Runtime `27.7s`; exit code `0`; pass count `2`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingDesktopSecurity.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -EntryPoint "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-WindowsProductionAcceptanceContract.ps1" -RunnerPath "C:\CodexWorker\ammar-task10-cloud\tests\Run-WindowsProductionAcceptance.ps1" -InstallerAcceptancePath "C:\CodexWorker\ammar-task10-cloud\windows\scripts\Test-AmmarTradingSyncAcceptance.ps1"'
```

Runtime `14.0s`; exit code `0`; pass count `2`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingDesktopOperation.ps1" -EntryPoint "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1"'
```

Runtime `20.4s`; exit code `0`; pass count `1`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingMt4Discovery.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -SchemaModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineCsvSchemaV3.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-InstallBasketsSyncTask.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Install-BasketsSyncTask.ps1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineDeploymentDefaults.ps1" -AutomationRoot "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync"; Write-Output "POWER_SHELL_PASS_COUNT=3"'
```

Runtime `4.4s`; exit code `0`; pass count `3`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachinePowerQueryContract.ps1" -BasketQueryPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_Baskets.m" -StatusQueryPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_SyncStatus.m"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-V3TelemetryReportingContract.ps1" -SourcePath "C:\CodexWorker\ammar-task10-cloud\AmmarTradingGoldEA - ref reset every bar - V3.mq4"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineSyncWizardHost.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Start-MoneyMachineSyncWizard.ps1"'
```

Runtime `16.4s`; exit code `0`; pass count `3`; fail count `0`; skip count `0`.

```text
win ps 'Set-Location "C:\CodexWorker\ammar-task10-cloud\windows"; dotnet test "AmmarTrading.Sync.sln" --verbosity minimal'
```

Runtime `14.5s`; exit code `0`; pass count `83`; fail count `0`; skip count `0`.

```text
node --test windows/tests/installer-contract.test.mjs
```

Runtime `1.2s`; exit code `0`; pass count `18`; fail count `0`; skip count `0`.

```text
git diff --check
```

Runtime `0.5s`; exit code `0`; pass count `1`; fail count `0`; skip count `0`.

```text
win ps 'Test-Path -LiteralPath "C:\CodexWorker\ammar-task10-cloud\prototypes\money-machine-sync-wizard\scripts\accept-windows-wizard.mjs"'
```

Runtime `3.8s`; exit code `0`; output `False`; browser acceptance skip count `1` because its required prototype script was not staged on the isolated worker.

## Fix round 4 of 5: registration coherence and held identity

### Changes

- Each public OneDrive enumeration or resolution now obtains exactly one registration sample, expands and canonicalizes it, deduplicates canonical paths before filesystem inspection, validates each remaining root once as an existing local fixed-volume path, and uses that immutable snapshot for authorization, activity, and writability. Environment variables remain exact-match activity hints only.
- Every existing component of a OneDrive-sensitive path is opened with `FILE_FLAG_OPEN_REPARSE_POINT`, inspected for combined attributes/tag plus volume serial/file index identity, kept open without `FILE_SHARE_DELETE` across the protected operation, re-opened by name and revalidated before release, and disposed in reverse order on every exit. Trusted directories request `DELETE` access so Windows also blocks their rename/delete through the parent namespace.
- Directory creation, write probes, trusted temporary writes/copies, CSV and heartbeat publication, and legacy migration now use that critical section. Atomic publication renames the already-validated source by handle with `SetFileInformationByHandle(FileRenameInfo)` and revalidates that same handle after publication. Replacement is explicit for normal publication and disabled for legacy migration, so a racing legacy destination is preserved and classified as a conflict.
- The three real-HKCU synthetic fixtures establish `finally` cleanup before their first registry mutation, remove only their GUID-suffixed key, verify absence, and fail if exact-key cleanup fails.
- Focused coverage includes duplicate canonical registrations, distinct roots, existing inactive and missing stale registrations, forged environment input, a changing resolver, a held-identity mutation seam, deterministic exception disposal, real Windows rename/delete blocking and release, and a destination-created-during-migration race.

### Exact RED evidence

The first two RED runs occurred after adding the focused registration/identity tests and before editing production files. Runtime was Windows PowerShell through `win ps` on `zenbook_duo_25\dryou`; each had pass count `0`, fail count `1`, skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; try { & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; Write-Output "TEST-PASS" } catch { Write-Output ("TEST-FAIL: " + $_.Exception.Message); exit 7 }'
```

- Registration-coherence RED: runtime `3.510310660s`; exit code `7`; output `TEST-FAIL: OneDrive root must exactly match a currently signed-in OneDrive root.` Duplicate rows that canonicalized to one root were still treated as multiple registrations and the resolver was reread.
- Held-identity RED: runtime `6.944137167s`; exit code `7`; output `TEST-FAIL: The term 'Invoke-AmmarTradingTrustedPathOperation' is not recognized as the name of a cmdlet, function, script file, or operable program.` No critical-section mechanism existed.

Final invariant review introduced a migration-race test before changing the replacement policy:

```text
win put tests/Test-AmmarTradingBatchSetup.ps1 C:/CodexWorker/ammar-task10-cloud/tests/Test-AmmarTradingBatchSetup.ps1
win ps '$ErrorActionPreference="Stop"; try { & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingBatchSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; Write-Output "TEST-PASS" } catch { Write-Output ("TEST-FAIL: " + $_.Exception.Message); exit 7 }'
```

Runtime `17.091909144s`; exit code `7`; pass count `0`; fail count `1`; skip count `0`; output `TEST-FAIL: A destination created during legacy publication must be counted as a conflict. Expected '1', got '0'.`

### Exact focused GREEN evidence

```text
win ps '$ErrorActionPreference="Stop"; try { & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; Write-Output "TEST-PASS" } catch { Write-Output ("TEST-FAIL: " + $_.Exception.Message); exit 7 }'
```

Runtime `4.204405413s`; exit code `0`; pass count `1`; fail count `0`; skip count `0`; output included `AmmarTrading Cloud Files trust-boundary tests passed.` and `TEST-PASS`.

The focused migration regression also passed after the explicit no-replace policy:

```text
win ps '$ErrorActionPreference="Stop"; try { & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingBatchSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; Write-Output "TEST-PASS" } catch { Write-Output ("TEST-FAIL: " + $_.Exception.Message); exit 7 }'
```

Runtime `21.512316427s`; exit code `0`; pass count `1`; fail count `0`; skip count `0`; output included `AmmarTrading transactional batch setup and legacy migration tests passed.` and `TEST-PASS`.

### Exact final suite evidence

All commands below ran against the final product/test commit. The six PowerShell groups completed in cumulative runtime `99.686519219s`, exit code `0`, pass count `13` script invocations, fail count `0`, skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineSyncSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; Write-Output "POWER_SHELL_PASS_COUNT=2"'
```

Runtime `8.727710790s`; exit code `0`; pass count `2`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingBatchSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineCsvSync.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"; Write-Output "POWER_SHELL_PASS_COUNT=2"'
```

Cumulative runtime `37.987258007s`; exit code `0`; pass count `2`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingDesktopSecurity.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -EntryPoint "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-WindowsProductionAcceptanceContract.ps1" -RunnerPath "C:\CodexWorker\ammar-task10-cloud\tests\Run-WindowsProductionAcceptance.ps1" -InstallerAcceptancePath "C:\CodexWorker\ammar-task10-cloud\windows\scripts\Test-AmmarTradingSyncAcceptance.ps1"; Write-Output "POWER_SHELL_PASS_COUNT=2"'
```

Runtime `16.710501733s`; exit code `0`; pass count `2`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingDesktopOperation.ps1" -EntryPoint "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1"; Write-Output "POWER_SHELL_PASS_COUNT=1"'
```

Runtime `21.322824438s`; exit code `0`; pass count `1`; fail count `0`; skip count `0`. Its real synthetic HKCU key was verified absent by the fixture before success.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingMt4Discovery.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -SchemaModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineCsvSchemaV3.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-InstallBasketsSyncTask.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Install-BasketsSyncTask.ps1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineDeploymentDefaults.ps1" -AutomationRoot "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync"; Write-Output "POWER_SHELL_PASS_COUNT=3"'
```

Runtime `4.025219875s`; exit code `0`; pass count `3`; fail count `0`; skip count `0`.

```text
win ps '$ErrorActionPreference="Stop"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachinePowerQueryContract.ps1" -BasketQueryPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_Baskets.m" -StatusQueryPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_SyncStatus.m"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-V3TelemetryReportingContract.ps1" -SourcePath "C:\CodexWorker\ammar-task10-cloud\AmmarTradingGoldEA - ref reset every bar - V3.mq4"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineSyncWizardHost.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Start-MoneyMachineSyncWizard.ps1"; Write-Output "POWER_SHELL_PASS_COUNT=3"'
```

Runtime `10.913004376s`; exit code `0`; pass count `3`; fail count `0`; skip count `0`. The wizard-host fixture verified deletion of its exact real synthetic HKCU key before success.

```text
win ps 'Set-Location "C:\CodexWorker\ammar-task10-cloud\windows"; dotnet test "AmmarTrading.Sync.sln" --verbosity minimal'
```

Runtime `6.449135861s`; exit code `0`; pass count `83` (`31` Core + `52` App); fail count `0`; skip count `0`.

```text
node --test windows/tests/installer-contract.test.mjs
```

Runtime `0.806498601s`; exit code `0`; pass count `18`; fail count `0`; skip count `0`.

```text
win ps '$exists = Test-Path -LiteralPath "C:\CodexWorker\ammar-task10-cloud\prototypes\money-machine-sync-wizard\scripts\accept-windows-wizard.mjs"; Write-Output ("BROWSER_PREREQUISITE_EXISTS=" + $exists); if ($exists) { exit 9 }'
```

Runtime `2.297785725s`; exit code `0`; output `BROWSER_PREREQUISITE_EXISTS=False`; browser-acceptance prerequisite skip count `1` because its required prototype script is not staged on the isolated worker.

```text
git diff --check
```

Runtime `0.01s`; exit code `0`; pass count `1`; fail count `0`; skip count `0`.

### Full correction commit identities

- `a80373948484cf96705b34c002d75901f7e22853` — `fix: allow trusted OneDrive Cloud Files roots`
- `3df34b017134b87d737dba796808a61b4b41fac6` — `fix: harden OneDrive Cloud Files trust`
- `061dc1127271d29897e02eb50d37c696e672d121` — round-four product/test head, `fix: bind OneDrive operations to held identities`

### Concerns / unrun verification

- Browser acceptance remains the single explicit skip because the isolated worker lacks its prototype script prerequisite.
- The bounded tests used only temporary local roots and unique synthetic current-user registry keys. No VPS, credentials, customer data, live OneDrive path/data, or installer artifact was accessed or changed, and no installer was built.
