amarTrading Sync - OneDrive folder picker test build

This is a self-signed test build for the VPS validation phase.

Setup
1. Extract this package to a local folder on the Windows VPS.
2. Start OneDrive and sign in with the approved uploader account.
3. Run amarTrading.Sync.Test.exe.
4. On the OneDrive step, choose the signed-in OneDrive root.
5. The reporting folder defaults to OneDrive\amartrading. Keep it or click Choose folder to select another folder inside that OneDrive root.
6. Complete the validation and apply the setup.

Important
- The application is self-signed for testing, so Smart App Control may still block it on a machine that does not trust the test certificate.
- This package does not disable Smart App Control or Windows security.
- If Windows blocks it, do not disable security. Send the exact message, Windows build, and the VPS name used for the test.
- The application publishes locally into OneDrive. Confirm cloud delivery separately on the reporting PC.
