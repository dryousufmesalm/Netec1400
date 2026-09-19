import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testsRoot = path.dirname(fileURLToPath(import.meta.url));
const windowsRoot = path.resolve(testsRoot, "..");
const build = await readFile(path.join(windowsRoot, "scripts", "Build-AmmarTradingSync.ps1"), "utf8");
const module = await readFile(path.join(windowsRoot, "scripts", "AmmarTradingCodeSigning.psm1"), "utf8");
const operator = await readFile(path.join(windowsRoot, "scripts", "New-AmmarTradingCodeSigningCertificate.ps1"), "utf8");
const publish = await readFile(path.join(windowsRoot, "scripts", "Publish-SignedRelease.ps1"), "utf8");
const clientReadme = await readFile(path.join(windowsRoot, "installer", "README-SIGNED-AR.txt"), "utf8");
const trustInstaller = await readFile(path.join(windowsRoot, "installer", "Install-AmmarTradingCertificate.cmd"), "utf8");

test("payload is signed before the hashes the installer verifies against are computed", () => {
  const signPayload = build.indexOf("Set-AmmarTradingCodeSignature -Path $signedPayload");
  const payloadHashes = build.indexOf("$productionPayloadHashLines = foreach");
  const productionExeHash = build.indexOf("$productionExeHash = (Get-FileHash");
  assert.ok(signPayload >= 0, "the published payload must be signed");
  assert.ok(payloadHashes > signPayload, "payload hashes must cover the signed bytes");
  assert.ok(productionExeHash > signPayload, "the executable hash must cover the signed bytes");
});

test("installers are signed before the published SHA-256 manifest is computed", () => {
  const signSetup = build.indexOf("Set-AmmarTradingCodeSignature -Path $stagedSetupExecutables");
  const installerHash = build.indexOf("$installerHash = (Get-FileHash -LiteralPath $stagedInstallerPath");
  assert.ok(signSetup >= 0, "both staged setup executables must be signed");
  assert.ok(installerHash > signSetup, "SHA256SUMS.txt must describe the signed installer");
  assert.match(build, /\$stagedSetupExecutables\s*=\s*@\(\$stagedInstallerPath,\$stagedFaultInstallerPath\)/);
});

test("only first-party binaries and scripts are signed", () => {
  assert.match(build, /Get-AmmarTradingSignablePath -Root \$publishedScripts/);
  assert.doesNotMatch(build, /Get-AmmarTradingSignablePath -Root \$publishRoot/);
  assert.match(build, /'amartrading\.sync\.exe' = 'AmmarTrading\.Sync\.exe'/);
  assert.doesNotMatch(build, /'amartrading\.sync\.dll' = 'AmmarTrading\.Sync\.dll'/);
  assert.match(build, /Name -imatch '\^ammartrading\\\.sync\.\*\\\.dll\$'/);
});

test("every signature is bound to the expected certificate and a trusted timestamp", () => {
  assert.match(build, /Assert-AmmarTradingCodeSignature -Path \$signedPayload -ExpectedThumbprint \$signingCertificate\.Thumbprint/);
  assert.match(build, /Assert-AmmarTradingCodeSignature -Path \$stagedSetupExecutables -ExpectedThumbprint \$signingCertificate\.Thumbprint/);
  assert.match(module, /was signed by an unexpected certificate/);
  assert.match(module, /\$null -eq \$signature\.TimeStamperCertificate/);
  assert.match(module, /signed without a trusted timestamp/);
  assert.match(module, /-TimestampServer \$TimestampUrl/);
});

test("signing refuses unsupported inputs and an expired or private-keyless identity", () => {
  assert.match(module, /Refusing to sign an unsupported file type/);
  assert.match(module, /does not contain a private key/);
  assert.match(module, /The code signing certificate expired on/);
  assert.match(module, /Signing produced an unusable signature/);
});

test("the shipped trust material is public-only and matches the signing identity", () => {
  assert.match(build, /function New-PublisherTrustBootstrap/);
  assert.match(build, /\$Certificate\.Export\(\[Security\.Cryptography\.X509Certificates\.X509ContentType\]::Cert\)/);
  assert.match(build, /The staged publisher certificate does not match the signing identity/);
  assert.match(module, /Refusing to distribute trust material that carries a private key/);
  assert.doesNotMatch(build, /\$stagedTrustBootstrap[\s\S]{0,400}\.pfx/);
});

test("publisher-trust files are promoted and invalidated with the installer", () => {
  assert.match(build, /Every staged publisher-trust file must have exactly one canonical destination/);
  assert.match(build, /Remove-CanonicalReleaseArtifacts -InstallerPath \$installerPath[^\n]+-TrustBootstrapPath \$trustBootstrapPath/);
  assert.match(build, /Assert-CanonicalReleaseArtifactsAbsent -InstallerPath \$installerPath[^\n]+-TrustBootstrapPath \$trustBootstrapPath/);
  const promote = build.indexOf("[IO.File]::Move($StagedTrustBootstrap[$index],$TrustBootstrapPath[$index])");
  const promoteInstaller = build.indexOf("[IO.File]::Move($StagedInstaller,$InstallerPath)");
  assert.ok(promote >= 0 && promoteInstaller > promote, "the installer must remain the last promoted artifact");
});

test("a stale publisher certificate cannot survive an unsigned rebuild", () => {
  const invalidate = build.indexOf("Remove-CanonicalReleaseArtifacts -InstallerPath $installerPath");
  const promotedSubset = build.indexOf("$promotedTrustBootstrapPath = @()");
  assert.ok(invalidate >= 0 && promotedSubset > invalidate, "trust files must be invalidated unconditionally, promoted conditionally");
  assert.match(build, /\$promotedTrustBootstrapPath = \$trustBootstrapPath/);
});

test("an unconfigured signing identity warns instead of failing quietly", () => {
  assert.match(build, /Write-Warning 'No code signing identity was supplied/);
  assert.match(build, /A code signing \.pfx was supplied without its password/);
  assert.match(build, /The publisher-trust bootstrap is missing/);
  assert.match(build, /\$CodeSigningPfxPath = \$env:AMMARTRADING_CODESIGN_PFX/);
});

test("the signing key is never persisted in an ambient certificate store", () => {
  assert.match(operator, /-AsSecureString/);
  assert.match(operator, /at least 12 characters/);
  assert.match(module, /Remove-Item -LiteralPath \$storePath -Force -ErrorAction SilentlyContinue/);
  assert.match(module, /Refusing to overwrite existing signing material/);
  assert.match(build, /\$signingCertificate\.Dispose\(\)/);
});

test("signed client zip is assembled only from public files and never includes the pfx", () => {
  assert.match(publish, /function New-ClientDeliveryPackage/);
  assert.match(publish, /function Assert-NoPrivateKeyInPackage/);
  assert.match(publish, /Client package contains private signing material/);
  assert.match(publish, /AmmarTrading-Sync-Signed-Client\.zip/);
  assert.match(publish, /README-SIGNED-AR\.txt/);
  assert.doesNotMatch(publish, /Copy-Item[^\n]+\.pfx/);
  assert.match(publish, /must run on Windows/);
  assert.match(publish, /The build ran without a signing identity/);
});

test("Arabic client readme requires trust before setup", () => {
  assert.match(clientReadme, /Install-AmmarTradingCertificate\.cmd/);
  assert.match(clientReadme, /AmmarTrading Sync Setup\.exe/);
  assert.match(clientReadme, /لا تشغّل ملف الإعداد أولاً/);
  assert.match(clientReadme, /AmmarTrading-CodeSigning\.thumbprint\.txt/);
});

test("the client trust step is explicit, elevated, and thumbprint bound", () => {
  assert.match(trustInstaller, /net session >nul 2>&1/);
  assert.match(trustInstaller, /Start-Process -Verb RunAs/);
  assert.match(trustInstaller, /does not match the published thumbprint/);
  assert.match(trustInstaller, /carries a private key and must not be trusted/);
  assert.match(trustInstaller, /Type YES to trust this publisher/);
  assert.match(trustInstaller, /Cert:\\LocalMachine\\Root/);
  assert.match(trustInstaller, /Cert:\\LocalMachine\\TrustedPublisher/);
});
