import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testsRoot = path.dirname(fileURLToPath(import.meta.url));
const windowsRoot = path.resolve(testsRoot, "..");
const build = await readFile(path.join(windowsRoot, "scripts", "Build-AmmarTradingSync.ps1"), "utf8");
const acceptance = await readFile(path.join(windowsRoot, "scripts", "Test-AmmarTradingSyncAcceptance.ps1"), "utf8");
const installer = await readFile(path.join(windowsRoot, "installer", "AmmarTradingSync.iss"), "utf8");
const appProject = await readFile(path.join(windowsRoot, "src", "AmmarTrading.Sync.App", "AmmarTrading.Sync.App.csproj"), "utf8");

test("acceptance owns its isolated install root and validates containment before mutation", () => {
  const topLevelParameters = acceptance.slice(0, acceptance.indexOf("$ErrorActionPreference"));
  assert.doesNotMatch(topLevelParameters, /\[string\]\$InstallRoot/);
  assert.match(acceptance, /function Assert-SafeAcceptancePath/);
  assert.match(acceptance, /The acceptance path escaped its isolated root/);
  assert.match(acceptance, /Acceptance paths cannot contain reparse points/);
});

test("release outputs are staged uniquely and promoted as one guarded operation", () => {
  assert.match(build, /\.build-/);
  assert.match(build, /function Publish-ReleaseArtifacts/);
  assert.match(build, /Remove-CanonicalReleaseArtifacts/);
  assert.match(build, /AmmarTrading Sync Upgrade Fault Test\.exe/);
});

test("canonical outputs fail closed before preflight and after promoted cleanup failure", () => {
  const invalidate = build.indexOf("Remove-CanonicalReleaseArtifacts -InstallerPath $installerPath");
  const resolveCompiler = build.indexOf("Resolve-InnoCompiler -RequestedPath $InnoCompilerPath");
  assert.ok(invalidate >= 0 && resolveCompiler > invalidate, "canonical outputs must be invalidated before compiler preflight");
  assert.match(build, /function Assert-CanonicalReleaseArtifactsAbsent/);
  assert.match(build, /\[ValidateSet\('None','Preflight','PostPromotionCleanup'\)\]/);
  assert.match(build, /Task 9 injected post-promotion cleanup failure/);
  assert.match(build, /Remove-CanonicalReleaseArtifacts[\s\S]+Assert-CanonicalReleaseArtifactsAbsent[\s\S]+throw/);
});

test("published and installed executable payloads use explicit allowlists", () => {
  assert.match(build, /\$createdumpPath\s*=\s*Join-Path[^\n]+'createdump\.exe'/);
  assert.match(build, /Remove-Item -LiteralPath \$createdumpPath -Force/);
  assert.match(build, /\$allowedExecutables\s*=\s*@\('AmmarTrading\.Sync\.exe'\)/);
  assert.match(acceptance, /\$allowedInstalledExecutables\s*=\s*@\('AmmarTrading\.Sync\.exe','unins000\.exe'\)/);
});

test("release payload uses unified apphost companions and rejects legacy names", () => {
  assert.match(appProject, /<AssemblyName>AmmarTrading\.Sync<\/AssemblyName>/);
  const releasePayloadAssertion = build.slice(
    build.indexOf("function Assert-ReleasePayload"),
    build.indexOf("function Remove-CanonicalReleaseArtifacts"),
  );
  for (const companion of [
    "AmmarTrading.Sync.exe",
    "AmmarTrading.Sync.dll",
    "AmmarTrading.Sync.deps.json",
    "AmmarTrading.Sync.runtimeconfig.json",
  ]) {
    assert.match(releasePayloadAssertion, new RegExp(`['\"]${companion.replaceAll(".", "\\.")}['\"]`));
  }
  for (const legacy of [
    "amarTrading.Sync.dll",
    "amarTrading.Sync.deps.json",
    "amarTrading.Sync.runtimeconfig.json",
  ]) {
    assert.match(releasePayloadAssertion, new RegExp(`['\"]${legacy.replaceAll(".", "\\.")}['\"]`));
  }
  const legacyCompanionCheck = releasePayloadAssertion.slice(
    releasePayloadAssertion.indexOf("$legacyCompanionNames"),
    releasePayloadAssertion.indexOf("$forbiddenExtensions"),
  );
  assert.match(legacyCompanionCheck, /\$legacyCompanionNames\s+-ccontains\s+\$file\.Name/);
  assert.doesNotMatch(legacyCompanionCheck, /ToLowerInvariant/);
  assert.doesNotMatch(build, /canonicalProductNames|apphost is compiled against AssemblyName/i);
});

test("acceptance cleanup is anchored to the exact AppId and attempted root", () => {
  assert.match(acceptance, /\$uninstallSubKey\s*=\s*'\{8F488698-AB96-45DB-A2BB-D9E868823F43\}_is1'/);
  assert.match(acceptance, /\$setupAttempted\s*=\s*\$true/);
  assert.match(acceptance, /function Repair-FailedSetupAttempt/);
  const preservationAssertion = acceptance.indexOf("Uninstall removed preserved state.");
  const disarm = acceptance.lastIndexOf("$setupAttempted = $false");
  assert.ok(disarm > preservationAssertion, "cleanup must remain armed through uninstall assertions");
});

test("failed-upgrade rollback uses a compile-time-only manifest-owned fault payload", () => {
  assert.match(installer, /#ifdef AcceptanceFaultInjection/);
  assert.match(installer, /Source: "\{#FaultProbePath\}"; DestDir: "\{app\}"; DestName: "\{#ProductExe\}"/);
  assert.match(installer, /DestName: "Task9IncomingOnly\.bin"/);
  assert.match(installer, /DestName: "Task9UpgradeFault\.blocked"/);
  assert.doesNotMatch(installer, /InjectDeterministicUpgradeFailure|RaiseException\('Task 9 deterministic upgrade failure\.'/);
  assert.match(installer, /function PrepareToInstall\(var NeedsRestart: Boolean\): String/);
  assert.match(installer, /procedure DeinitializeSetup/);
  assert.match(build, /AmmarTrading\.Sync\.payload-manifest\.txt/);
  assert.match(installer, /procedure SnapshotProductPayload/);
  assert.match(installer, /IncomingPayloadManifest/);
  assert.match(installer, /GetFileAttributesW@kernel32\.dll/);
  assert.match(installer, /FILE_ATTRIBUTE_REPARSE_POINT/);
  assert.match(acceptance, /function Get-InstalledPayloadHashes/);
  assert.match(acceptance, /Failed upgrade changed the allowlisted product payload/);
  assert.match(build, /FaultManifestPath/);
  assert.match(installer, /Task9IncomingOnly\.bin/);
  assert.match(installer, /\.ammar-installer-recovery\.active/);
  assert.match(installer, /\.ammar-installer-recovery\.verified/);
  assert.match(installer, /GetSHA256OfFile/);
  assert.match(installer, /MoveFileExW@kernel32\.dll/);
  const atomicWriter = installer.slice(installer.indexOf("procedure AtomicWriteLines"), installer.indexOf("procedure AtomicWriteText"));
  assert.doesNotMatch(atomicWriter, /DeleteFile\(Path\)/);
  assert.match(installer, /TASK9MODE/);
  assert.match(acceptance, /recoveryonly/);
  assert.match(acceptance, /restorefail/);
  assert.match(acceptance, /crash-ready/);
  assert.match(build, /Task9 fault payload - never distribute/);
  assert.match(build, /AmmarTrading Sync Upgrade Fault Probe\.sha256/);
  assert.match(acceptance, /Fault probe hash unexpectedly matches the production executable/);
  assert.match(acceptance, /Fault installer did not copy the distinguishable probe before rollback/);
  assert.match(acceptance, /\$faultCollision/);
  assert.match(acceptance, /Failed upgrade changed the installed executable/);
  assert.match(acceptance, /Fault-injection installer unexpectedly succeeded/);
});

test("durable recovery is Program Files bound, manifest verified, and atomic", () => {
  assert.match(installer, /ValidateProtectedAppRoot/);
  assert.match(installer, /ExpandConstant\('\{autopf\}'\)/);
  assert.match(installer, /AMMAR_STATE_MAGIC = 'AMMAR_TX_V3'/);
  assert.match(installer, /APPID\|/);
  assert.match(installer, /GetSHA256OfFile/);
  assert.match(installer, /RenameFile\(BuildingRoot, ActiveRecoveryRoot\)/);
  assert.match(installer, /CountFilesRecursive/);
  assert.match(installer, /VerifyRestoredPayload/);
  assert.doesNotMatch(installer, /DelTree\(AppRoot/);
});

test("acceptance exercises crash, restore failure, corruption, and recovery before mutation", () => {
  assert.match(acceptance, /TASK9MODE=recoveryonly/);
  assert.match(acceptance, /TASK9MODE=restorefail/);
  assert.match(acceptance, /TASK9MODE=crash/);
  assert.match(acceptance, /crash-ready/);
  assert.match(acceptance, /Corrupt recovery state changed product payload before validation/);
  assert.match(acceptance, /Injected restore failure did not retain active durable state/);
  assert.match(acceptance, /Crash recovery did not remove the manifest-owned incoming-only path/);
});

test("fault seams require the acceptance-only compile define", () => {
  assert.match(build, /\/DAcceptanceFaultInjection=1/);
  assert.match(build, /FaultManifestPath/);
  assert.match(installer, /#ifdef AcceptanceFaultInjection[\s\S]+TASK9MODE/);
});

test("recovery classifies prior, committed incoming, and invalid metadata before mutation", () => {
  assert.match(installer, /function ClassifyActiveTransaction/);
  assert.match(installer, /AMMAR_TX_PRIOR/);
  assert.match(installer, /AMMAR_TX_INCOMING/);
  assert.match(installer, /VerifyIncomingCommittedPayload/);
  assert.match(installer, /DisplayVersion/);
  assert.match(installer, /QuietUninstallString/);
  assert.match(installer, /unins000\.dat/);
  assert.match(installer, /IncomingPayloadHashes/);
  assert.match(acceptance, /premarkercrash/);
  assert.match(acceptance, /Post-marker recovery restored the prior payload/);
});

test("WebView prerequisite completes before snapshot and post-install is the commit boundary", () => {
  assert.match(installer, /BootstrapperPath\}"; Flags: dontcopy noencryption/);
  const runSection = installer.slice(installer.indexOf("[Run]"), installer.indexOf("[Code]"));
  assert.doesNotMatch(runSection, /MicrosoftEdgeWebView2Setup/);
  assert.match(installer, /function InstallWebViewPrerequisite/);
  assert.match(installer, /function GetCustomSetupExitCode/);
  assert.match(installer, /ssPostInstall/);
  assert.match(installer, /CommitFailed/);
  assert.match(acceptance, /TASK9MODE=webviewfail/);
});

test("uninstall uses the same durable transaction classifier and fails closed", () => {
  assert.match(installer, /function InitializeUninstall/);
  assert.match(installer, /ClassifyActiveTransaction/);
  assert.match(acceptance, /Corrupt prior-uninstaller proof uninstall unexpectedly succeeded/);
  assert.match(acceptance, /Active transaction uninstall did not recover before removal/);
});

test("uninstall requires a transaction-bound prior-uninstaller proof created outside uninstall", () => {
  assert.match(installer, /AMMAR_UNINS_PROOF_MAGIC/);
  assert.match(installer, /prior-uninstaller-verified\.txt/);
  assert.match(installer, /function WritePriorUninstallerProof/);
  assert.match(installer, /function ValidatePriorUninstallerProof/);
  assert.match(installer, /InsideUninstaller/);
  assert.match(acceptance, /ACTIVE uninstall without prior-uninstaller proof unexpectedly succeeded/);
  assert.match(acceptance, /Corrupt prior-uninstaller proof uninstall unexpectedly succeeded/);
});

test("committed incoming uninstall uses its own fully bound pre-uninstall proof", () => {
  const priorMagic = installer.match(/AMMAR_UNINS_PROOF_MAGIC\s*=\s*'([^']+)'/);
  const incomingMagic = installer.match(/AMMAR_INCOMING_UNINS_PROOF_MAGIC\s*=\s*'([^']+)'/);
  assert.ok(priorMagic, "the prior proof magic must remain explicit");
  assert.ok(incomingMagic, "the incoming proof magic must be explicit");
  assert.notEqual(incomingMagic[1], priorMagic[1], "incoming and prior proof formats must remain distinct");
  assert.match(installer, /incoming-uninstaller-verified\.txt/);
  assert.match(installer, /incoming-uninstaller-verified\.sha256/);
  assert.match(installer, /function WriteIncomingUninstallerProof/);
  assert.match(installer, /function ValidateIncomingUninstallerProof/);

  const incomingProofWriter = installer.slice(
    installer.indexOf("function WriteIncomingUninstallerProof"),
    installer.indexOf("function WriteCommittedMarker"),
  );
  for (const binding of [
    "APPID|",
    "ROOT|",
    "TXID|",
    "STATE|",
    "COMMITTED|",
    "INCOMINGMANIFEST|",
    "INCOMINGHASHES|",
    "REGISTRATION|",
    "UNINSEXE|",
    "UNINSDAT|",
  ]) {
    assert.match(incomingProofWriter, new RegExp(binding.replace("|", "\\|")));
  }
  assert.match(incomingProofWriter, /state\.sha256/);
  assert.match(incomingProofWriter, /committed\.sha256/);
  assert.match(incomingProofWriter, /VerifyIncomingCommittedPayload/);
  assert.match(incomingProofWriter, /CurrentUninstallerMeta\('unins000\.exe'/);
  assert.match(incomingProofWriter, /CurrentUninstallerMeta\('unins000\.dat'/);
  assert.match(incomingProofWriter, /RegistrationDigestWithUninstallerMeta/);
  assert.match(incomingProofWriter, /AtomicWriteLines/);
  assert.match(incomingProofWriter, /AtomicWriteText/);
  assert.match(incomingProofWriter, /ValidateIncomingUninstallerProofEnvelope/);

  const markerWriter = installer.slice(
    installer.indexOf("function WriteCommittedMarker"),
    installer.indexOf("function ClassifyActiveTransaction"),
  );
  const validationSteps = [
    "TryParseState",
    "VerifyIncomingCommittedPayload",
    "CurrentUninstallerMeta('unins000.exe'",
    "CurrentUninstallerMeta('unins000.dat'",
    "RegistrationDigestWithUninstallerMeta",
    "AtomicWriteLines(RecoveryChild(RecoveryRoot, 'committed.txt')",
    "AtomicWriteText(RecoveryChild(RecoveryRoot, 'committed.sha256')",
    "WriteIncomingUninstallerProof",
  ].map((step) => markerWriter.indexOf(step));
  assert.ok(validationSteps.every((index) => index >= 0), "the committed proof pipeline must retain every validation and write step");
  assert.deepEqual(validationSteps, [...validationSteps].sort((a, b) => a - b), "the incoming proof must only be produced after live commit validation");
});

test("incoming proof is only a locked-uninstaller exception to live metadata validation", () => {
  assert.match(installer, /function RegistrationDigestWithUninstallerMeta/);
  const committedValidator = installer.slice(
    installer.indexOf("function ValidateCommittedMarker"),
    installer.indexOf("function WriteIncomingUninstallerProof"),
  );
  assert.match(committedValidator, /if InsideUninstaller then/);
  assert.match(committedValidator, /ValidateIncomingUninstallerProof/);
  assert.match(committedValidator, /RegistrationDigest\(RegistrationFound\)/);
  assert.match(committedValidator, /CurrentUninstallerMeta\('unins000\.dat'/);
  assert.match(acceptance, /Valid incoming proof bypassed live DAT validation outside uninstall/);
  assert.match(acceptance, /Valid incoming proof bypassed live registration validation outside uninstall/);
});

test("Task 9 rejects every invalid incoming proof before a valid incoming final uninstall", () => {
  assert.match(acceptance, /function Invoke-BlockedIncomingProofUninstallCase/);
  assert.match(acceptance, /\$Label incoming proof uninstall unexpectedly succeeded/);
  for (const label of [
    "Missing",
    "Malformed",
    "Corrupt-checksum",
    "Wrong-AppId",
    "Wrong-root",
    "Wrong-transaction",
    "Wrong-state",
    "Wrong-marker",
    "Wrong-manifest",
    "Wrong-hashes",
    "Wrong-registration",
    "Wrong-EXE",
    "Wrong-DAT",
    "Stale",
    "Unsafe-path",
    "Reparse",
  ]) {
    assert.match(acceptance, new RegExp(`-Label '${label}'`));
  }
  assert.match(acceptance, /Incoming committed transaction did not finalize before final uninstall/);
});

test("V3 snapshots finalized installer metadata before Inno mutation", () => {
  assert.match(installer, /AMMAR_STATE_MAGIC = 'AMMAR_TX_V3'/);
  assert.match(installer, /SnapshotPriorRegistration/);
  assert.match(installer, /prior-unins\.exe/);
  assert.match(installer, /prior-unins\.dat/);
  assert.match(installer, /ExtractTemporaryFile\('IncomingPayloadHashes\.txt'\)/);
  const prepare = installer.slice(installer.indexOf("function PrepareToInstall"), installer.indexOf("procedure CurStepChanged"));
  assert.match(prepare, /SnapshotProductPayload/);
  assert.match(installer, /RestorePriorRegistration/);
});

test("version rollback snapshots and restores Inno MajorVersion and MinorVersion DWORDs", () => {
  assert.match(installer, /SetArrayLength\(Names, 5\)/);
  assert.match(installer, /Names\[3\] := 'MajorVersion'/);
  assert.match(installer, /Names\[4\] := 'MinorVersion'/);
  assert.match(acceptance, /Get-ExactVersionDwordEvidence/);
  assert.match(acceptance, /Fault installer did not write exact 9\.9 MajorVersion and MinorVersion DWORDs/);
  assert.match(acceptance, /Pre-marker recovery did not restore exact prior version DWORD metadata/);
});

test("version rollback proves the exact production baseline before fault installation", () => {
  assert.match(acceptance, /priorDisplayVersion -cne '1\.0\.0'/);
  assert.match(acceptance, /priorVersionDwords\.MajorVersion -ne 1/);
  assert.match(acceptance, /priorVersionDwords\.MinorVersion -ne 0/);
  assert.match(acceptance, /Production baseline version metadata was not exact/);
});

test("only a transaction-bound ssDone marker can classify incoming", () => {
  assert.match(installer, /AMMAR_COMMIT_MAGIC/);
  assert.match(installer, /committed\.txt/);
  assert.match(installer, /function ValidateCommittedMarker/);
  assert.match(installer, /CurStep = ssDone/);
  assert.match(installer, /postmarkercrash/);
  assert.match(installer, /premarkercrash/);
  assert.match(installer, /function RemoveObsoleteProductPayload/);
  assert.match(build, /FaultProductVersion=9\.9\.9/);
  assert.match(acceptance, /Pre-marker recovery did not restore prior uninstall metadata/);
  assert.match(acceptance, /Post-marker recovery restored the prior payload/);
  assert.match(acceptance, /Successful upgrade retained an obsolete manifest-owned path/);
});

test("application launch happens only after durable commit cleanup", () => {
  const runSection = installer.slice(installer.indexOf("[Run]"), installer.indexOf("[Code]"));
  assert.doesNotMatch(runSection, /ProductExe/);
  assert.match(installer, /ExecAsOriginalUser/);
  assert.match(installer, /LaunchAfterCommit/);
  assert.match(acceptance, /Incoming-only path was not verified absent before uninstall/);
  assert.doesNotMatch(acceptance, /@\(\$launchedProcess\)\[0\]/);
});
