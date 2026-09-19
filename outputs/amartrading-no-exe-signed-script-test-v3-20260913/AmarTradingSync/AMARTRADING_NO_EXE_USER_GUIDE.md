# AmarTrading Sync browser version

This package runs the AmarTrading Sync GUI in Chrome or Edge through a local PowerShell service. It does not include a custom `.exe`, installer, or Electron runtime. The included PowerShell scripts are signed with the AmarTrading Test Publisher certificate, chained to an included test root, so they can run on a test VPS that enforces `RemoteSigned`.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Chrome or Microsoft Edge
- OneDrive signed in on the VPS
- MT4 running with the AmarTrading EA writing `AGOLD___Baskets.csv`

## Start

1. Extract the package to a local folder on the VPS.
2. Run `Install-AmarTradingTestCertificate.cmd` once. It adds the included test certificate only for the current Windows user.
3. Start OneDrive and sign in with the approved account.
4. Double-click `Start-AmarTradingBrowser.cmd`.
5. The GUI opens at a local address in the browser.
6. Continue through the setup screens. MT4 accounts are discovered automatically.
7. On the OneDrive screen, the default reporting folder is `OneDrive\\amartrading`. Use **Choose folder** to select another folder inside the selected OneDrive root.

The CMD window must remain open while the GUI is being used. Close it when finished.

## Security and policy

The service listens only on `127.0.0.1` and uses a per-run session cookie. It does not request trading or Microsoft passwords. The launcher does not use `-ExecutionPolicy Bypass` and does not disable Windows security. The certificate installer does not install an EXE or change Smart App Control, Microsoft Defender, AppLocker, WDAC, or PowerShell execution policy.

This design avoids the custom unsigned application EXE check. A locked-down organization policy can still restrict scripts even after the test certificate is installed. If startup fails, send `%LOCALAPPDATA%\\AmarTradingSync\\Logs\\latest-start.log` and the first Windows error message; do not disable Smart App Control, AppLocker, or Defender.

## Validation boundary

The GUI confirms local MT4 discovery, local CSV publication, and scheduled synchronization. OneDrive cloud delivery and receipt on the reporting PC must be verified separately.
