# Signing AmmarTrading Sync without buying a certificate

Windows shows "Windows protected your PC / Unknown publisher" for any executable it cannot trace
to a certificate authority in Microsoft's Trusted Root program. A free, self-signed certificate
removes that warning **on machines where its public certificate has been installed as trusted** —
which is exactly our situation, because we install on the client's own PC and VPS rather than
publishing for anonymous download.

What this does and does not buy:

| | Self-signed (free) | Azure Trusted Signing (~$10/mo) |
| --- | --- | --- |
| Warning-free on machines we prepare | Yes | Yes |
| Warning-free on any machine | No | Yes |
| Tamper-evident, verifiable publisher | Yes | Yes |
| Survives certificate expiry (timestamped) | Yes | Yes |

If the app ever ships as a public download, the only part that changes is where the `.pfx` comes
from; everything below stays the same.

## Operator one-shot (Windows build machine)

```powershell
cd <repo>
.\windows\scripts\Publish-SignedRelease.ps1 -CreateCertificateIfMissing
```

That creates the self-signed identity if missing, builds the signed installer, and writes
`artifacts\windows\AmmarTrading-Sync-Signed-Client.zip`. Send the zip to the client. Send the
printed thumbprint on a separate WhatsApp/call. Never send the `.pfx`.

The zip contains setup, the public `.cer`, the trust installer, SHA-256 sums, and `README-AR.txt`.
It is refused if a private key would be included.

## One-time: create the signing identity only

Run once on the build machine, as administrator (elevation is only needed for `-TrustOnThisMachine`,
which trusts the certificate locally so the build can verify its own output):

```powershell
cd windows\scripts
.\New-AmmarTradingCodeSigningCertificate.ps1 -TrustOnThisMachine
```

This writes three files to `%LOCALAPPDATA%\AmmarTrading\CodeSigning`:

- `AmmarTrading-CodeSigning.pfx` — the private key. Back it up somewhere safe and never commit or
  send it. Losing it means clients must trust a new certificate; leaking it means anyone can sign
  software that the client's machine trusts.
- `AmmarTrading-CodeSigning.cer` — public only, safe to ship.
- `AmmarTrading-CodeSigning.thumbprint.txt` — the fingerprint to read out to the client over a
  separate channel (WhatsApp, a call) so they can confirm the certificate they are trusting.

The certificate is deliberately removed from the build machine's personal store afterwards, so the
`.pfx` is the single copy of the signing identity.

## Every build: point the build at the identity

```powershell
$env:AMMARTRADING_CODESIGN_PFX = "$env:LOCALAPPDATA\AmmarTrading\CodeSigning\AmmarTrading-CodeSigning.pfx"
$env:AMMARTRADING_CODESIGN_PFX_PASSWORD = '<the .pfx password>'
.\windows\scripts\Build-AmmarTradingSync.ps1
```

`Build-AmmarTradingSync.ps1` then signs `AmmarTrading.Sync.exe`, the first-party
`AmmarTrading.Sync*.dll` assemblies, the shipped PowerShell scripts, and both setup executables.
The bundled .NET runtime is left alone because it already carries Microsoft's signatures.

Two orderings matter and are locked in by `windows/tests/code-signing-contract.test.mjs`: signing
happens before the payload hashes the installer verifies at install time, and before the
`SHA256SUMS.txt` entry for the installer. Signing changes the bytes, so doing it the other way
round would produce an installer that rejects its own payload.

Every signature is timestamped through `http://timestamp.digicert.com`, which is what keeps
already-delivered releases verifiable after the certificate expires. A timestamp failure fails the
build rather than emitting a weaker signature. Override the server with `-TimestampUrl` if needed.

Omitting the two environment variables still produces a working build; it just warns and ships
unsigned.

## Delivering to the client

The build promotes these into `artifacts\windows`, all-or-nothing with the installer:

```
AmmarTrading Sync Setup.exe
SHA256SUMS.txt
AmmarTrading-CodeSigning.cer
AmmarTrading-CodeSigning.thumbprint.txt
Install-AmmarTradingCertificate.cmd
```

Ship the whole folder. The client runs `Install-AmmarTradingCertificate.cmd` **once**, confirms the
thumbprint against the one we gave them separately, and types `YES`. It then imports the
certificate into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`. From that point every
release signed with the same key installs, updates, and runs with no warning and with
"AmmarTrading" shown as the verified publisher.

Be straight with the client about what they are agreeing to: trusting this certificate means the
machine will accept anything signed with that key, so the `.pfx` has to be protected accordingly.

## Rotating or replacing the certificate

Pass `-Force` to overwrite existing signing material, and remember that the old certificate stays
trusted on client machines until removed. Clients must run the new
`Install-AmmarTradingCertificate.cmd` before they can install a release signed with the new key.
