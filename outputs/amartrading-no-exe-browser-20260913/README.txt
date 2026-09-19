AmarTrading Sync - browser version (no custom EXE)

This package opens the same AmarTrading Sync GUI in Chrome or Edge through a local PowerShell service. It contains no custom application EXE, installer, Electron runtime, or signing certificate.

Requirements
- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Chrome or Microsoft Edge
- OneDrive signed in on the VPS
- MT4 running with the AmarTrading EA writing AGOLD___Baskets.csv

Setup
1. Extract this package to a local folder on the Windows VPS.
2. Start OneDrive and sign in with the approved uploader account.
3. Double-click Start-AmarTradingBrowser.cmd.
4. The GUI opens in Chrome or Edge at a local 127.0.0.1 address.
5. Continue through the setup screens. MT4 accounts are discovered automatically.
6. On the OneDrive screen, the default folder is OneDrive\amartrading. Keep it or click Choose folder to select another folder inside the selected OneDrive root.

Operation
- Keep the CMD window open while using the GUI. Close it when finished.
- The launcher does not use ExecutionPolicy Bypass and does not disable Windows security.
- The local service is bound to 127.0.0.1 and uses a per-run session cookie.
- If Windows policy blocks a script, send the exact message to support. Do not disable Smart App Control, AppLocker, or Defender.

Validation
The GUI confirms local MT4 discovery, local CSV publication, and scheduled synchronization. Confirm OneDrive cloud delivery and reporting-PC receipt separately.
