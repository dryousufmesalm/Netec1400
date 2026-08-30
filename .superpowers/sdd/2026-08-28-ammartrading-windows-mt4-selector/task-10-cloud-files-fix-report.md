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

## Fix round 5 of 5: continuous temporary identity

### Bounded correction

- `Publish-AmmarTradingTrustedFile` now owns one continuous critical section for trusted publication. It retains the already validated root, parent, and any trusted-source component handles; creates a unique temporary leaf with `CREATE_NEW` plus `FILE_FLAG_OPEN_REPARSE_POINT`; and keeps that same read/write/attributes/delete-capable handle open without delete sharing through the callback/copy, `Flush(true)`, combined attribute/tag and stable-identity checks, exact length/SHA-256 verification, and `SetFileInformationByHandle(FileRenameInfo)` publication.
- The primitive rechecks the same handle identity and verified bytes immediately after the deterministic post-verification seam, compares the same handle identity after rename, and reopens the destination by name while the authoritative handle is still held. Handles are disposed deterministically. Failure cleanup uses `FileDispositionInfo` on only the task-created, still-held unpublished file; it never removes a temporary pathname by name and never deletes historical OneDrive data.
- Trusted text and CSV publication use the shared primitive with explicit replacement. CSV copies directly from the validated source into the held temporary stream and binds the copy to the caller's length, SHA-256, and last-write baseline. A CSV source canonically below the trusted root is validated with the Cloud Files policy and retained as an additional lock; an external MT4 source retains the existing local fixed-volume validation.
- Legacy migration uses the same primitive without replacement. Destination-exists Win32 errors `80`/`183` are classified only after safely verifying the raced destination as identical or conflicting.
- The non-trusted local atomic-write branches and the prior Cloud tag, registration-snapshot, fixed-volume, hydration, and negative-path boundaries are unchanged.

### Exact RED evidence

All RED runs used Windows PowerShell on the isolated `C:\CodexWorker\ammar-task10-cloud` staging tree. The first three runs occurred before their corresponding production changes. Each command deliberately converts the expected failure to exit code `7`, with pass count `0`, fail count `1`, and skip count `0`.

The text/CSV substitution test and its expanded direct-helper contract used this exact command at two TDD checkpoints:

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); try { & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -SyncScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"; $sw.Stop(); Write-Output ("RED_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "RED_UNEXPECTED_PASS=1"; exit 8 } catch { $sw.Stop(); Write-Output ("TEST-FAIL: " + $_.Exception.Message); Write-Output ("RED_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "RED_PASS_COUNT=0 RED_FAIL_COUNT=1 RED_SKIP_COUNT=0"; exit 7 }'
```

- Split-path text/CSV RED: runtime `1.5272297s`; exit `7`; `TEST-FAIL: A verified temporary regular file must remain held so text and CSV pathname substitution is blocked before publication.` Under the old split operations, both ordinary-file substitutions succeeded and attacker bytes reached the publication path.
- Full primitive-contract RED: runtime `1.0656166s`; exit `7`; `TEST-FAIL: The term 'Publish-AmmarTradingTrustedFile' is not recognized ...`. The same-handle primitive did not yet exist.

Migration used this exact command before changing migration production code:

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); try { & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingBatchSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; $sw.Stop(); Write-Output ("RED_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "RED_UNEXPECTED_PASS=1"; exit 8 } catch { $sw.Stop(); Write-Output ("TEST-FAIL: " + $_.Exception.Message); Write-Output ("RED_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "RED_PASS_COUNT=0 RED_FAIL_COUNT=1 RED_SKIP_COUNT=0"; exit 7 }'
```

Runtime `5.9649794s`; exit `7`; `TEST-FAIL: Legacy migration destination verification failed for '...\held.csv'.` The old split migration temporarily or permanently installed the substituted ordinary file before its post-publication hash check detected it.

An independent compatibility review then tagged the trusted fixture root before exercising a CSV source contained below that root. Before the source-policy correction, the first RED command above produced runtime `1.5234119s`, exit `7`, counts `0/1/0`, and `TEST-FAIL: CSV publication source file contains a reparse point.` This exposed the regression before the production compatibility change.

### Exact focused GREEN evidence

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -SyncScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"; $sw.Stop(); Write-Output ("FOCUSED_CLOUD_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FOCUSED_CLOUD_PASS_COUNT=1 FOCUSED_CLOUD_FAIL_COUNT=0 FOCUSED_CLOUD_SKIP_COUNT=0"'
```

- Initial same-handle GREEN: runtime `2.2665557s`; exit `0`; counts `1/0/0`.
- Cloud-tagged trusted-source compatibility GREEN after its RED: runtime `2.1441702s`; exit `0`; counts `1/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingBatchSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; $sw.Stop(); Write-Output ("FOCUSED_MIGRATION_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FOCUSED_MIGRATION_PASS_COUNT=1 FOCUSED_MIGRATION_FAIL_COUNT=0 FOCUSED_MIGRATION_SKIP_COUNT=0"'
```

Runtime `12.3334424s`; exit `0`; counts `1/0/0`. It covers the after-verification regular-file substitution seam and the no-replace destination race.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineSyncSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineCsvSync.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"; $sw.Stop(); Write-Output ("FOCUSED_CONSUMERS_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FOCUSED_CONSUMERS_PASS_COUNT=2 FOCUSED_CONSUMERS_FAIL_COUNT=0 FOCUSED_CONSUMERS_SKIP_COUNT=0"'
```

Runtime `22.5733441s`; exit `0`; counts `2/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineCsvSync.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"; $sw.Stop(); Write-Output ("FOCUSED_EXTERNAL_SOURCE_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FOCUSED_EXTERNAL_SOURCE_PASS_COUNT=1 FOCUSED_EXTERNAL_SOURCE_FAIL_COUNT=0 FOCUSED_EXTERNAL_SOURCE_SKIP_COUNT=0"'
```

Runtime `20.7894987s`; exit `0`; counts `1/0/0`, retaining external fixed-volume MT4 source behavior.

The focused Cloud suite covers success; callback/write failure; SHA mismatch; rename failure; temporary cleanup; normal replacement; deterministic text, CSV, and migration regular-file substitution after verification; real Windows rename/delete/`File.Replace` blocking while the temporary handle is held; post-disposal replace/rename/delete; and absence of a handle leak. Batch coverage retains no-replace migration conflict classification.

### Exact final amended-head suite evidence

Every executable gate below ran against code/test commit `e33f3b32b4319c7c39ce049a125d352cab3459e3`. At verification close, local and isolated-worker SHA-256 values matched for all four changed product/test files.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -SyncScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineSyncSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; $sw.Stop(); Write-Output ("FINAL_PS_GROUP_1_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_PS_GROUP_1_PASS_COUNT=2 FINAL_PS_GROUP_1_FAIL_COUNT=0 FINAL_PS_GROUP_1_SKIP_COUNT=0"'
```

Runtime `6.1290277s`; exit `0`; counts `2/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingBatchSetup.ps1" -ModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1"; $sw.Stop(); Write-Output ("FINAL_PS_GROUP_2A_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_PS_GROUP_2A_PASS_COUNT=1 FINAL_PS_GROUP_2A_FAIL_COUNT=0 FINAL_PS_GROUP_2A_SKIP_COUNT=0"'
```

Runtime `11.5270107s`; exit `0`; counts `1/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineCsvSync.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Sync-BasketsToOneDrive.ps1"; $sw.Stop(); Write-Output ("FINAL_PS_GROUP_2B_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_PS_GROUP_2B_PASS_COUNT=1 FINAL_PS_GROUP_2B_FAIL_COUNT=0 FINAL_PS_GROUP_2B_SKIP_COUNT=0"'
```

Runtime `22.8765369s`; exit `0`; counts `1/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingDesktopSecurity.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -EntryPoint "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-WindowsProductionAcceptanceContract.ps1" -RunnerPath "C:\CodexWorker\ammar-task10-cloud\tests\Run-WindowsProductionAcceptance.ps1" -InstallerAcceptancePath "C:\CodexWorker\ammar-task10-cloud\windows\scripts\Test-AmmarTradingSyncAcceptance.ps1"; $sw.Stop(); Write-Output ("FINAL_PS_GROUP_3_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_PS_GROUP_3_PASS_COUNT=2 FINAL_PS_GROUP_3_FAIL_COUNT=0 FINAL_PS_GROUP_3_SKIP_COUNT=0"'
```

Runtime `14.255803s`; exit `0`; counts `2/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingDesktopOperation.ps1" -EntryPoint "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1"; $sw.Stop(); Write-Output ("FINAL_PS_GROUP_4_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_PS_GROUP_4_PASS_COUNT=1 FINAL_PS_GROUP_4_FAIL_COUNT=0 FINAL_PS_GROUP_4_SKIP_COUNT=0"'
```

Runtime `17.2371023s`; exit `0`; counts `1/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingMt4Discovery.ps1" -SetupModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineSyncSetup.psm1" -SchemaModulePath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\MoneyMachineCsvSchemaV3.psm1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-InstallBasketsSyncTask.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Install-BasketsSyncTask.ps1"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineDeploymentDefaults.ps1" -AutomationRoot "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync"; $sw.Stop(); Write-Output ("FINAL_PS_GROUP_5_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_PS_GROUP_5_PASS_COUNT=3 FINAL_PS_GROUP_5_FAIL_COUNT=0 FINAL_PS_GROUP_5_SKIP_COUNT=0"'
```

Runtime `1.1975797s`; exit `0`; counts `3/0/0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachinePowerQueryContract.ps1" -BasketQueryPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_Baskets.m" -StatusQueryPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\PowerQuery\MoneyMachine_SyncStatus.m"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-V3TelemetryReportingContract.ps1" -SourcePath "C:\CodexWorker\ammar-task10-cloud\AmmarTradingGoldEA - ref reset every bar - V3.mq4"; & "C:\CodexWorker\ammar-task10-cloud\tests\Test-MoneyMachineSyncWizardHost.ps1" -ScriptPath "C:\CodexWorker\ammar-task10-cloud\automation\MoneyMachineCsvSync\Start-MoneyMachineSyncWizard.ps1"; $sw.Stop(); Write-Output ("FINAL_PS_GROUP_6_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_PS_GROUP_6_PASS_COUNT=3 FINAL_PS_GROUP_6_FAIL_COUNT=0 FINAL_PS_GROUP_6_SKIP_COUNT=0"'
```

Runtime `7.1063348s`; exit `0`; counts `3/0/0`.

The PowerShell total is `13` passed script invocations, `0` failed, `0` skipped, cumulative measured runtime `80.3293951s`.

```text
win ps '$ErrorActionPreference="Stop"; Set-Location "C:\CodexWorker\ammar-task10-cloud\windows"; $sw=[Diagnostics.Stopwatch]::StartNew(); dotnet test "AmmarTrading.Sync.sln" --verbosity minimal; if ($LASTEXITCODE -ne 0) { throw "dotnet test failed with exit code $LASTEXITCODE" }; $sw.Stop(); Write-Output ("FINAL_DOTNET_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output "FINAL_DOTNET_PASS_COUNT=83 FINAL_DOTNET_FAIL_COUNT=0 FINAL_DOTNET_SKIP_COUNT=0"'
```

Runtime `5.1391953s`; exit `0`; pass `83` (`31` Core + `52` App); fail `0`; skip `0`.

```text
/usr/bin/time -f 'FINAL_NODE_RUNTIME_SECONDS=%e FINAL_NODE_EXIT=%x' node --test windows/tests/installer-contract.test.mjs
```

Runtime `0.44s`; exit `0`; pass `18`; fail `0`; skip `0`.

```text
/usr/bin/time -f 'FINAL_DIFF_WORKTREE_RUNTIME_SECONDS=%e FINAL_DIFF_WORKTREE_EXIT=%x' git diff --check
/usr/bin/time -f 'FINAL_DIFF_COMMIT_RUNTIME_SECONDS=%e FINAL_DIFF_COMMIT_EXIT=%x' git diff --check HEAD^ HEAD
```

Each runtime was `0.01s`; each exited `0`; pass `2`; fail `0`; skip `0`.

```text
win ps '$ErrorActionPreference="Stop"; $sw=[Diagnostics.Stopwatch]::StartNew(); $path="C:\CodexWorker\ammar-task10-cloud\prototypes\money-machine-sync-wizard\scripts\accept-windows-wizard.mjs"; $exists=Test-Path -LiteralPath $path; $sw.Stop(); Write-Output ("FINAL_BROWSER_RUNTIME_SECONDS=" + $sw.Elapsed.TotalSeconds); Write-Output ("FINAL_BROWSER_PREREQUISITE_EXISTS=" + $exists); if ($exists) { Write-Output "FINAL_BROWSER_PASS_COUNT=0 FINAL_BROWSER_FAIL_COUNT=0 FINAL_BROWSER_SKIP_COUNT=0" } else { Write-Output "FINAL_BROWSER_PASS_COUNT=0 FINAL_BROWSER_FAIL_COUNT=0 FINAL_BROWSER_SKIP_COUNT=1" }'
```

Runtime `0.030479s`; exit `0`; output `FINAL_BROWSER_PREREQUISITE_EXISTS=False`; pass `0`; fail `0`; skip `1`. The browser acceptance prerequisite is not staged on the isolated Windows worker.

### Full round-five commit identities

- `e33f3b32b4319c7c39ce049a125d352cab3459e3` — code/tests, `fix: retain trusted publication handles`.
- The separate documentation commit is created after this report content is finalized; its full identity is supplied in the final handoff because a Git commit cannot contain its own identity.

### Concerns / unrun verification

- Browser acceptance is the single explicit skip because its prototype prerequisite is absent from the isolated Windows staging tree.
- The bounded tests used only temporary local roots and unique synthetic current-user registry keys. No VPS, credentials, customer data, live OneDrive path/data, installer artifact, or generated installer binary was accessed or changed, and no installer was built.
