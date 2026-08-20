# Windows Test Worker Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a secure, on-demand Windows 11 test worker that Linux can use over a Windows-originated reverse SSH tunnel without cloning the repository to Windows.

**Architecture:** Linux packages only allowlisted files into a hash manifest, invokes a bounded PowerShell job runner through a loopback-only reverse tunnel, then collects and verifies a result bundle. An elevated Windows bootstrap installs and confines OpenSSH, creates a standard worker account, and registers a SYSTEM-owned reconnecting tunnel task; normal jobs always run as the non-administrator worker account.

**Tech Stack:** Bash, OpenSSH, PowerShell 5.1+, Windows Task Scheduler, SHA-256, MetaEditor command line.

**Spec:** `docs/superpowers/specs/2026-08-20-windows-test-worker-design.md`

## Global Constraints

- Linux is the only authoritative Git checkout; Windows must never receive a `.git` directory, Git credentials, or a persistent repository copy.
- The Windows OpenSSH server must bind only to `127.0.0.1`; do not open a router port or a public inbound firewall rule.
- The Linux reverse listener must bind only to `127.0.0.1:22022` and the tunnel account must not provide a shell.
- Routine job modes are exactly `smoke`, `sync`, `mql`, `acceptance`, and `collect`; arbitrary command strings are forbidden.
- The Windows worker account is `CodexWorker`, is standard (not Administrator), and receives only its workspace plus deliberately granted staging folders.
- Do not commit passwords, private keys, Windows host data, OneDrive credentials, or `worker.local.psd1`.
- Result bundles use `result.json` schema version `1`; exit code `0` is pass, `1` a failed check, `2` invalid input, and `3` a missing dependency.
- Excel refresh and MT4 Strategy Tester remain interactive Codex Remote checks; no unattended Office automation is claimed.

---

### Task 1: Define the repository-side contract

**Files:**
- Create: `automation/WindowsTestWorker/job-manifest.txt`
- Create: `automation/WindowsTestWorker/worker.local.psd1.example`
- Modify: `.gitignore`
- Create: `tests/Test-WindowsWorkerPackaging.sh`

**Interfaces:**
- Produces an allowlist with relative repository paths and a local configuration schema consumed by `Invoke-WindowsWorker.sh`.
- Produces `tests/Test-WindowsWorkerPackaging.sh`, invoked as `bash tests/Test-WindowsWorkerPackaging.sh`.

- [ ] **Step 1: Write the failing packaging-contract test**

```bash
assert_file automation/WindowsTestWorker/job-manifest.txt
assert_file automation/WindowsTestWorker/worker.local.psd1.example
assert_file automation/WindowsTestWorker/Invoke-WindowsWorker.sh
assert_not_match '\\.git|\.\\.|^/' automation/WindowsTestWorker/job-manifest.txt
assert_match '^\*\.local\.psd1$' .gitignore
assert_match '^audit/windows-worker/$' .gitignore
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/Test-WindowsWorkerPackaging.sh`

Expected: failure because the worker files do not exist.

- [ ] **Step 3: Add the manifest, local-configuration template, and ignore rules**

Use a one-path-per-line manifest containing the CSV sync scripts, their fixture, `CLIENT_CSV_SCHEMA.md`, and the worker runner. The template must require `WorkerHost`, `WorkerPort`, `WorkerUser`, `IdentityFile`, and an optional `MetaEditorPath`.

- [ ] **Step 4: Run the test and verify the contract portions pass**

Run: `bash tests/Test-WindowsWorkerPackaging.sh`

Expected: it advances to the missing orchestrator behavior.

- [ ] **Step 5: Commit**

```bash
git add .gitignore automation/WindowsTestWorker/job-manifest.txt automation/WindowsTestWorker/worker.local.psd1.example tests/Test-WindowsWorkerPackaging.sh
git commit -m "feat: define Windows worker job contract"
```

### Task 2: Implement and test the Linux orchestrator

**Files:**
- Create: `automation/WindowsTestWorker/Invoke-WindowsWorker.sh`
- Modify: `tests/Test-WindowsWorkerPackaging.sh`

**Interfaces:**
- Consumes: `worker.local.psd1` values converted by the caller into command-line options, `job-manifest.txt`, a mode, and a repository root.
- Produces: `audit/windows-worker/<JobId>/result.json`, `bundle.tar.gz`, and `bundle.sha256` after a successful collection.
- Command: `bash automation/WindowsTestWorker/Invoke-WindowsWorker.sh --mode smoke --config automation/WindowsTestWorker/worker.local.psd1`.

- [ ] **Step 1: Add failing tests for input validation and deterministic package creation**

```bash
expect_failure --mode evil
expect_failure --manifest /tmp/outside-manifest.txt
expect_failure --mode smoke --dry-run --manifest tests/fixtures/bad-worker-manifest.txt
expect_success --mode smoke --dry-run --manifest automation/WindowsTestWorker/job-manifest.txt
assert_match 'JobId:' "$last_output"
assert_match 'SHA256:' "$last_output"
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `bash tests/Test-WindowsWorkerPackaging.sh`

Expected: failure because the orchestrator is absent.

- [ ] **Step 3: Implement the minimum safe orchestration path**

Implement `set -euo pipefail`, option parsing, mode allowlisting, path-normalized manifest validation, `tar --exclude-vcs`, SHA-256 manifest generation, sortable `YYYYmmddTHHMMSSZ-<8hex>` job IDs, `--dry-run`, a five-second SSH connect timeout, and collection-only cleanup when `--cleanup` is explicitly passed. The non-dry-run path uses `scp` and `ssh` only with the configured loopback host/port and invokes only `Run-WindowsJob.ps1 -JobId <id> -Mode <mode>`.

- [ ] **Step 4: Run the tests and verify GREEN**

Run: `bash tests/Test-WindowsWorkerPackaging.sh`

Expected: all local packaging tests pass without a Windows host.

- [ ] **Step 5: Commit**

```bash
git add automation/WindowsTestWorker/Invoke-WindowsWorker.sh tests/Test-WindowsWorkerPackaging.sh
git commit -m "feat: add Linux Windows-worker orchestrator"
```

### Task 3: Implement and test the bounded Windows job runner

**Files:**
- Create: `automation/WindowsTestWorker/Run-WindowsJob.ps1`
- Create: `tests/Test-WindowsWorkerScripts.ps1`

**Interfaces:**
- Consumes: `-JobId <sortable-id> -Mode <smoke|sync|mql|acceptance|collect> -WorkspaceRoot C:\CodexWorker\jobs`.
- Produces: `C:\CodexWorker\jobs\<JobId>\result.json` and hashed files underneath `artifacts`.

- [ ] **Step 1: Write failing PowerShell contract tests**

```powershell
& $runner -JobId 'bad/../id' -Mode smoke -WorkspaceRoot $tempRoot
if($LASTEXITCODE -ne 2) { throw 'Traversal job IDs must be rejected with exit code 2.' }
& $runner -JobId '20260820T180000Z-abcdef12' -Mode evil -WorkspaceRoot $tempRoot
if($LASTEXITCODE -ne 2) { throw 'Unknown modes must be rejected with exit code 2.' }
```

- [ ] **Step 2: Run the tests and verify RED**

Run on Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-WindowsWorkerScripts.ps1`

Expected: failure because the runner is absent.

- [ ] **Step 3: Implement the dispatcher and result schema**

Implement strict job-ID validation, known-mode selection, `New-WorkerResult`, `Add-WorkerCheck`, SHA-256 artifact recording, redaction of computer name and local paths, and JSON output using `ConvertTo-Json -Depth 8`. `smoke` must check Windows/PowerShell identity, current user, sshd service, and create a round-trip text artifact. `sync` executes only the packaged test script. `mql` requires an explicit MetaEditor path and returns exit code `3` when absent. `acceptance` combines non-GUI checks only. `collect` returns an existing valid result without executing a command.

- [ ] **Step 4: Run the tests and verify GREEN**

Run on Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-WindowsWorkerScripts.ps1`

Expected: input rejection and result-schema tests pass.

- [ ] **Step 5: Commit**

```bash
git add automation/WindowsTestWorker/Run-WindowsJob.ps1 tests/Test-WindowsWorkerScripts.ps1
git commit -m "feat: add bounded Windows worker runner"
```

### Task 4: Implement the secure Windows bootstrap and reconnecting tunnel

**Files:**
- Create: `automation/WindowsTestWorker/Run-ReverseTunnel.ps1`
- Create: `automation/WindowsTestWorker/Bootstrap-WindowsWorker.ps1`
- Modify: `tests/Test-WindowsWorkerScripts.ps1`

**Interfaces:**
- `Bootstrap-WindowsWorker.ps1` consumes `-LinuxHost`, `-LinuxHostKey`, and `-LinuxWorkerPublicKey`; it prints the generated tunnel public key.
- `Run-ReverseTunnel.ps1` consumes the installed tunnel private key and connects `-R 127.0.0.1:22022:localhost:22`.
- Produces scheduled task `Codex-WindowsWorker-ReverseTunnel` running as `SYSTEM`.

- [ ] **Step 1: Add failing static security tests**

```powershell
Assert-Text $bootstrap 'ListenAddress 127.0.0.1'
Assert-Text $bootstrap 'OpenSSH-Server-In-TCP'
Assert-Text $tunnel '-R 127.0.0.1:22022:localhost:22'
Assert-Text $tunnel 'StrictHostKeyChecking=yes'
Assert-Text $tunnel 'ExitOnForwardFailure=yes'
Assert-Text $bootstrap 'Codex-WindowsWorker-ReverseTunnel'
```

- [ ] **Step 2: Run static tests and verify RED**

Run on Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-WindowsWorkerScripts.ps1 -StaticOnly`

Expected: failure because bootstrap and tunnel scripts are absent.

- [ ] **Step 3: Implement idempotent bootstrap and tunnel scripts**

Bootstrap must require elevation, install OpenSSH capabilities only when missing, create/repair a standard `CodexWorker` account, restrict ACLs, write the Linux public key to that account, configure loopback-only `sshd`, disable the public OpenSSH firewall rule, generate the tunnel key under `C:\ProgramData\CodexWindowsWorker`, pin the supplied Linux host key, copy the tunnel script, create the startup SYSTEM scheduled task, and print only status plus the tunnel public key. The reconnect script uses `ssh.exe -N -T`, batch mode, pinned strict host checking, server-alive options, exit-on-forward-failure, and ten-second retry delay.

- [ ] **Step 4: Run static tests and verify GREEN**

Run on Windows: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-WindowsWorkerScripts.ps1 -StaticOnly`

Expected: the source contains all required confinement controls.

- [ ] **Step 5: Commit**

```bash
git add automation/WindowsTestWorker/Bootstrap-WindowsWorker.ps1 automation/WindowsTestWorker/Run-ReverseTunnel.ps1 tests/Test-WindowsWorkerScripts.ps1
git commit -m "feat: bootstrap secure Windows worker tunnel"
```

### Task 5: Document setup, operations, rotation, and removal

**Files:**
- Create: `WINDOWS_TEST_WORKER_SETUP.md`
- Modify: `README.md`

**Interfaces:**
- Documents the one-time Linux key/account setup, the exact elevated Windows bootstrap command, the public-key handoff, smoke invocation, GUI acceptance workflow, key rotation, and removal commands.

- [ ] **Step 1: Write a failing documentation-contract check**

Add assertions that the setup guide contains `127.0.0.1:22022`, `Codex-WindowsWorker-ReverseTunnel`, `ssh-keygen`, `userdel`, `Unregister-ScheduledTask`, and an explicit statement that no Windows router port is opened.

- [ ] **Step 2: Run the packaging test and verify RED**

Run: `bash tests/Test-WindowsWorkerPackaging.sh`

Expected: failure because the setup guide is absent.

- [ ] **Step 3: Write the operations guide**

Include only public-key exchange in chat, never private keys or passwords; explain the Windows host must remain awake for use; explain Codex Remote is GUI-only; include exact removal sequence for Windows task/account/files and Linux tunnel account/key; link the OneDrive production-readiness design.

- [ ] **Step 4: Run local tests and verify GREEN**

Run: `bash tests/Test-WindowsWorkerPackaging.sh`

Expected: all documentation and packaging tests pass.

- [ ] **Step 5: Commit**

```bash
git add WINDOWS_TEST_WORKER_SETUP.md README.md tests/Test-WindowsWorkerPackaging.sh
git commit -m "docs: add Windows worker setup guide"
```

### Task 6: Verify, deploy, and perform the live smoke test

**Files:**
- Verify: all files from Tasks 1–5

**Interfaces:**
- Consumes the committed scripts, a Windows-generated tunnel public key, and a user-approved live Windows bootstrap.
- Produces a verified `audit/windows-worker/<JobId>/result.json` from a Windows `smoke` job.

- [ ] **Step 1: Run Linux static and packaging verification**

```bash
bash tests/Test-WindowsWorkerPackaging.sh
git diff --check
git status --short
```

- [ ] **Step 2: Create the restricted Linux tunnel account and install only the Windows tunnel public key**

Create `winworker-tunnel` with `/usr/sbin/nologin`; install the public key in a dedicated `authorized_keys` file with `restrict`, `no-pty`, `no-agent-forwarding`, `no-X11-forwarding`, and `permitlisten="127.0.0.1:22022"`. Verify it cannot execute a shell and does not expose the listener publicly.

- [ ] **Step 3: Run the one-time elevated Windows bootstrap**

Use the documented command with the Linux host, pinned ED25519 host key, and Linux-to-Windows public key. Copy back only the printed Windows tunnel public key.

- [ ] **Step 4: Install the Windows tunnel public key and confirm loopback connectivity**

Install it for `winworker-tunnel`; wait for `ss -ltn` to show `127.0.0.1:22022`; run `ssh -p 22022 CodexWorker@127.0.0.1 whoami` from Linux and expect the standard worker identity.

- [ ] **Step 5: Run and inspect a smoke job**

```bash
bash automation/WindowsTestWorker/Invoke-WindowsWorker.sh --mode smoke --config automation/WindowsTestWorker/worker.local.psd1
```

Expected: a hash-verified `result.json` with status `Passed`; failure when the Windows machine is asleep must report `WorkerUnavailable` within five seconds.

- [ ] **Step 6: Commit any final non-secret corrections**

```bash
git add <only-reviewed-source-files>
git commit -m "test: verify Windows worker smoke bridge"
```
