AmarTrading Sync - browser test version (no custom EXE)

This package opens AmarTrading Sync in Chrome or Edge through a local PowerShell service. It contains no custom application EXE or installer.

First-time setup
1. Extract the complete ZIP to a local folder on the Windows VPS.
2. Run Install-AmarTradingTestCertificate.cmd once and approve its Windows administrator prompt.
3. Start OneDrive and sign in with the approved uploader account.
4. Double-click Start-AmarTradingBrowser.cmd.

The test root and publisher certificates are installed only in this VPS's trusted root and trusted publisher stores. They let the signed test scripts run when the VPS uses PowerShell RemoteSigned. They do not disable Smart App Control, Defender, AppLocker, WDAC, or PowerShell execution policy.

The GUI opens in Chrome or Edge at a local 127.0.0.1 address and discovers MT4 accounts automatically. The default reporting folder is OneDrive\amartrading.

If startup fails, send this log to support:
%LOCALAPPDATA%\AmarTradingSync\Logs\latest-start.log
