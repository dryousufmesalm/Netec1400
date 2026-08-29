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
  assert.match(installer, /AMMAR_STATE_MAGIC = 'AMMAR_TX_V1'/);
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
