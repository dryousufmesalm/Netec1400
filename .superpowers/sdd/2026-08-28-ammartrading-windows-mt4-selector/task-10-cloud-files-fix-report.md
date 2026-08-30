# Task 10 Cloud Files Fix Report

## Scope and files changed

- `automation/MoneyMachineCsvSync/MoneyMachineSyncSetup.psm1`: allows only Microsoft Cloud Files reparse tags `IO_REPARSE_TAG_CLOUD` through `IO_REPARSE_TAG_CLOUD_F` after direct `GetFileInformationByHandleEx(FileAttributeTagInfo)` inspection. The exception is gated to the canonical, registered signed-in OneDrive root and canonical descendants; all other reparse points still fail closed.
- `tests/Test-AmmarTradingCloudFiles.ps1`: behavior coverage for base, observed `0x9000701A`, and upper-bound Cloud Files tags; contained and escaped descendants; unregistered roots; and junction, symbolic-link, mount-point, and unknown tags.
- `tests/Test-AmmarTradingBatchSetup.ps1`: registers the synthetic legacy-migration fixture before asserting that its junction remains rejected, matching the trusted-root boundary.
- `tests/Test-WindowsProductionAcceptanceContract.ps1`: proves that a reporting-PC receipt with hydrated but hash-mismatched bytes is rejected. Existing assertions retain rejection of Offline, Recall-on-open, and Recall-on-data-access placeholder attributes.

## RED evidence

Before editing production code, the focused Windows PowerShell behavior test was run against the original module:

```text
& C:\CodexWorker\ammar-task10-cloud\tests\Test-AmmarTradingCloudFiles.ps1 ...
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
