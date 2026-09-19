# AmmarTrading ITISK Delivery Documentation

## Delivery purpose

This package contains the current AmmarTrading delivery workspace for ITISK. It includes:

- the MT4 XAUUSD grid/recovery Expert Advisor source and compiled binary;
- the Windows AmmarTrading Sync application source, installer definition, and sync automation;
- the Excel 2019 compatible analytics workbook and Power Query modules;
- installation, configuration, testing, parameter, FAQ, and troubleshooting documentation;
- source tests and acceptance scripts.

## Package structure

| Folder or file group | Purpose |
|---|---|
| `AmmarTradingGoldEA*`, `Netec1400*` | MT4 EA source/binary and original user guide assets |
| Root `*.md`, `*.pdf`, `*.txt` | Product, installation, parameter, testing, and project documentation |
| `automation/MoneyMachineCsvSync/` | CSV schema, OneDrive sync, Power Query, and setup wizard automation |
| `windows/` | Windows desktop sync app, bridge, tests, and installer project |
| `scripts/excel/` | Excel repair, import, validation, and visible-test scripts |
| `tests/` | PowerShell, Python, MQL4, and acceptance contract tests |
| `prototypes/money-machine-sync-wizard/` | Sync wizard UI source, tests, and QA artifacts |
| `outputs/` | Selected verification reports and the verified Excel 2019 workbook package |

## Recommended starting order

1. Read `ITISK_USER_GUIDE.md`.
2. Read `START_HERE.md` and `QUICK_START.md` for the MT4 EA.
3. Read `CSV_ONEDRIVE_EXCEL_SETUP.md` for the data and workbook workflow.
4. Read `INSTALLATION_GUIDE.md` and `COMPILE_INSTRUCTIONS.md` before installing the EA.
5. Use `TESTING_GUIDE.md` and `tests/` before any live account use.

## Current verification state

The included Excel 2019 compatible workbook was refreshed, recalculated, saved, and reopened in Excel 16.0 build 20326. The verification recorded 1,062 imported rows, four account/run groups, two preserved Power Query queries, two connections, no formula errors, and no modern-formula markers. The exact customer Office installation still requires final user acceptance.

The Windows sync application is an internal unsigned release candidate. Build and installer checks passed on the Windows 11 build worker. Authenticode signing, two-account live VPS acceptance, and independent reporting-PC OneDrive receipt/hash verification remain release gates.

`CloudDeliveryVerified=false` means the evidence proves VPS-local publication only. It does not prove OneDrive web delivery or reporting-PC receipt. Do not treat the included reports as proof of cross-device sync until the separate reporting-PC acceptance procedure passes.

## Safety and scope

The EA is designed for controlled testing and risk management; it cannot guarantee profit or prevent loss. Use a demo account first, keep live trading disabled during installation and validation, and review all inputs before enabling trading.

The package does not contain passwords, API keys, database URLs, service-role secrets, or RDP credentials. The included account and verification artifacts are operational test data and should be handled according to ITISK data policy.

## Handover acceptance

ITISK should confirm:

- the archive opens and its checksum matches the supplied manifest;
- the MT4 source compiles in MetaEditor and the EA passes demo testing;
- the Windows installer is signed before external production distribution;
- the selected workbook opens in the target Excel version and Refresh All is tested;
- VPS publication and reporting-PC receipt are verified separately with fresh evidence;
- the client accepts the outstanding release gates recorded above.

