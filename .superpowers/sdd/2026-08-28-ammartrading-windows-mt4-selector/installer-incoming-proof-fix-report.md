# Installer incoming-proof bounded fix report

## Result

The locked-`unins000.dat` final-uninstall defect is fixed and the exact full Task 9 lifecycle passes. A committed/incoming transaction now has its own versioned, checksummed durable proof, produced outside the uninstaller only after the live state, marker, payload, registry, and uninstaller metadata boundaries pass. During the running uninstaller only, the classifier uses the proof-bound DAT metadata while continuing to validate the exact recovery root, state and marker checksums, incoming payload, current EXE metadata, DAT path safety, and current registry strings.

The PRIOR proof remains a separate format and contract. Normal setup classification still reads and hashes the live DAT and cannot use the incoming proof as a shortcut.

Source/test commit:

```text
cfb2cda57e296d51b441b3df3a9fb41d916219ef fix: validate committed uninstall with incoming proof
```

The base was approved head `a3bab426e3f17942e9615a3539466556f840845d`. This report is committed separately; its commit hash is reported in the handoff because a commit cannot stably contain its own hash.

## RED evidence

Before editing product source, the focused contracts were added and run with:

```text
node --test windows/tests/installer-contract.test.mjs
```

Result: **21 total, 18 passed, 3 failed, 0 skipped**. The three expected failures were the absent distinct incoming-proof writer/validator contract, the absent metadata-aware uninstaller-only registration exception, and the absent full incoming-proof acceptance matrix.

The first implementation produced a second runtime RED in a full Task 9 run, acceptance ID `fabb28f1570f4cf8b8323b407b185b6f`. The unchanged 45-second `postmarker-ready` bound expired. Read-only inspection proved that neither readiness nor either proof file existed and `post-marker-crash.log` ended during a third redundant full durable-state parse. The implementation was corrected rather than extending the acceptance timeout: proof creation now consumes the already fully validated commit context, rechecks the exact state/phase/marker/checksums, live EXE/DAT metadata, registry strings and incoming payload once, atomically writes each proof file, and validates the written envelope without another full state/backup traversal.

## GREEN and acceptance evidence

Focused Linux contract command:

```text
node --test windows/tests/installer-contract.test.mjs
```

Result: **21 passed, 0 failed, 0 skipped**.

The same command in the final fresh Windows staging tree also returned **21 passed, 0 failed, 0 skipped**. Windows PowerShell 5.1 parsed both `Build-AmmarTradingSync.ps1` and `Test-AmmarTradingSyncAcceptance.ps1` with **0 parser errors each**.

Canonical build command in the final staging repository:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows\scripts\Build-AmmarTradingSync.ps1 -Configuration Release
```

Result:

- React/Node UI: **37 passed, 0 failed, 0 skipped**.
- .NET Core: **31 passed, 0 failed, 0 skipped**.
- .NET Windows App: **52 passed, 0 failed, 0 skipped**.
- Self-contained `win-x64` publish: passed.
- Production Inno Setup 6.7.3 compile: passed.
- Compile-time-only 9.9.9 fault Inno Setup 6.7.3 compile: passed.

Exact full lifecycle command:

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File windows\scripts\Test-AmmarTradingSyncAcceptance.ps1 -Installer "artifacts\windows\AmmarTrading Sync Setup.exe"
```

Acceptance ID `73706ebaf2c6461dab2f1a695b0dc8ae` exited **0** with:

```text
AmmarTrading Sync install, failed-upgrade rollback, successful upgrade, and uninstall acceptance passed.
```

This is one complete lifecycle invocation: **1 passed, 0 failed, 0 skipped**. The harness does not expose a framework assertion total, so the exact new case counts are reported separately:

- Incoming proof rejection cases: **16/16 blocked with ACTIVE state, payload, and registration preserved** — missing, malformed, corrupt checksum, wrong AppId, wrong root, wrong transaction, wrong state, wrong marker, wrong manifest, wrong hashes, wrong registration, wrong EXE, wrong DAT, genuine stale proof, unsafe path, and proof reparse point.
- Normal/non-uninstaller live-boundary cases: **2/2 blocked** with an otherwise valid proof — live DAT tamper and live registration tamper.
- Valid committed/incoming locked-DAT final uninstall: **1/1 passed**, and its uninstall log contained `Durable incoming uninstaller proof accepted.`

The same invocation retained all existing Task 9 coverage: WebView preflight failure without mutation, initial install and limited-token launch, distinguishable collision rollback, injected restore failure, killed copy crash, corrupt-state zero-mutation block, pre-marker recovery, post-marker finalization, obsolete-path removal, production upgrade, PRIOR no-proof and corrupt-proof uninstall blocks, valid PRIOR recovery-before-uninstall, and preservation of the task-scoped runtime, OneDrive, and Scheduled Task sentinels.

Final `git diff --check` passed. The focused Linux contracts were rerun immediately before the source/test commit and again returned **21/21**.

## Artifact

The verified canonical artifact remains on the configured Windows worker at:

```text
C:\CodexWorker\AmmarTrading-IncomingProofFix-deb2a8243c234cedb1917c0001fb8741\repo\artifacts\windows\AmmarTrading Sync Setup.exe
```

- Size: **51,233,731 bytes**.
- SHA-256: **`cfc74b46f50909be3890c5c9dea8fc19bd7eff45363e793a988a2cb7ba54e941`**.
- Product version: **1.0.0**.
- Product name: **AmmarTrading Sync**.
- File description: **AmmarTrading Sync Windows Installer**.
- Authenticode: **NotSigned**, signer **NONE**.
- `SHA256SUMS.txt` exact line: `cfc74b46f50909be3890c5c9dea8fc19bd7eff45363e793a988a2cb7ba54e941 *AmmarTrading Sync Setup.exe`.

No generated installer, fault installer, publish output, or build output was committed.

## Cleanup audit

After the passing run for exact acceptance ID `73706ebaf2c6461dab2f1a695b0dc8ae`:

- Exact AppId registrations: **0**.
- Product processes: **0**.
- Task 9 acceptance Scheduled Tasks: **0**.
- Exact Program Files acceptance root: absent.
- Exact worker acceptance root: absent.
- Exact runtime sentinel: absent.
- Start Menu and Public Desktop product shortcuts: absent.
- Canonical `.build-*` staging roots: **0**.

A broader worker-root inventory still showed two earlier evidence directories, acceptance IDs `8ba079e56fed4b74b127ce1e2997c092` and `9a69043c823c4ddd8ee4d29f4f7a52fc`. Neither is the passing run or the failed implementation run created by this fix. The first is the intentionally retained root-cause diagnostic evidence; ownership of the second is outside this task. Both were left untouched. The exact passing and failed-run worker roots owned by this fix were verified absent.

The earlier implementation-timing RED was also cleaned by running the exact task-scoped fault installer in `recoveryonly` mode (expected exit `7`), then the exact registered uninstaller (exit `0`). Its AppId, installation root, worker root, Scheduled Task, runtime sentinel, processes, and shortcuts were all verified absent. The superseded Windows implementation staging root `AmmarTrading-IncomingProofFix-756b2f7b5d7749b59aa47e6baf7cc2dd`, the final transfer tar, and the matching local temporary tar were removed and verified absent. The final staging repository is retained only to deliver the verified canonical artifact above.

Before acceptance, two stale global shortcuts from diagnostic acceptance ID `8ba079e56fed4b74b127ce1e2997c092` were handled under explicit authorization. Immediately before deletion, both targets were rechecked as pointing into that deleted diagnostic acceptance root, while its exact AppId registration, processes, Scheduled Tasks, and install root were absent. Exactly those two shortcut paths were deleted and both were verified absent; nothing else was removed in that operation.

No VPS, credentials, customer data, live OneDrive root, or live OneDrive file was read or changed. The only OneDrive-shaped data used by acceptance was beneath its fresh task-owned worker root and was removed with that root.

## Concerns

- The installer is technically accepted but remains unsigned. Production Authenticode signing is still a release prerequisite.
- The canonical binary is retained on Windows and was not copied into the repository or claimed as a Linux artifact.
- The incoming proof is deliberately accepted only in Inno's running uninstaller. All normal setup/recovery classification continues to require live DAT and live registration validation.
