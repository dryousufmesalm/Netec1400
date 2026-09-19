# AmarTrading Sync browser version

This package runs the AmarTrading Sync GUI in Chrome or Edge through a local PowerShell service. It does not include a custom `.exe`, installer, Electron runtime, or application signing certificate.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Chrome or Microsoft Edge
- OneDrive signed in on the VPS
- MT4 running with the AmarTrading EA writing `AGOLD___Baskets.csv`

## Start

1. Extract the package to a local folder on the VPS.
2. Start OneDrive and sign in with the approved account.
3. Double-click `Start-AmarTradingBrowser.cmd`.
4. The GUI opens at a local address in the browser.
5. Continue through the setup screens. MT4 accounts are discovered automatically.
6. On the OneDrive screen, the default reporting folder is `OneDrive\\amartrading`. Use **Choose folder** to select another folder inside the selected OneDrive root.

The CMD window must remain open while the GUI is being used. Close it when finished.

## Security and policy

The service listens only on `127.0.0.1` and uses a per-run session cookie. It does not request trading or Microsoft passwords. The launcher does not use `-ExecutionPolicy Bypass` and does not disable Windows security.

This design avoids the custom unsigned application EXE check. Windows policies can still restrict PowerShell or script files. If the launcher is blocked by an organization policy, send the exact Windows message to support; do not disable Smart App Control, AppLocker, or Defender.

## Validation boundary

The GUI confirms local MT4 discovery, local CSV publication, and scheduled synchronization. OneDrive cloud delivery and receipt on the reporting PC must be verified separately.
