# AmarTrading browser test certificate

This browser package contains PowerShell scripts, not a custom application EXE. Windows VPS servers commonly enforce the `RemoteSigned` PowerShell policy for files downloaded from the internet. Under that policy, an unsigned script cannot run.

The package is signed with the **AmarTrading Test Publisher** certificate, chained to the included **AmarTrading Test Root** certificate. Both are only for this test package and are not public Microsoft-trusted production certificates.

## First-time setup

1. Extract the complete ZIP package to a local folder, for example `C:\AmarTradingSync`.
2. Run `Install-AmarTradingTestCertificate.cmd`.
3. Confirm the single prompt to install the certificate for the current Windows user.
4. Run `Start-AmarTradingBrowser.cmd`.

The installer adds the included test root only to the current user's Trusted Root store and its publisher certificate only to the current user's Trusted Publishers store. It does not disable Smart App Control, Microsoft Defender, AppLocker, WDAC, or the PowerShell execution policy. It does not install an EXE.

If startup still fails, send `%LOCALAPPDATA%\AmarTradingSync\Logs\latest-start.log` together with a screenshot of the first warning or error.
