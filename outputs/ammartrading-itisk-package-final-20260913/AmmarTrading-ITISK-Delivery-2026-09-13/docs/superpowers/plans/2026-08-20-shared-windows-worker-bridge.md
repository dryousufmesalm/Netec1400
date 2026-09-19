# Shared Windows Worker Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one secure Windows 11 worker and one Linux `codex-win` client that any Linux project can use without cloning a repository to Windows.

**Architecture:** The tracked source distribution lives at `tools/codex-windows-worker`; installation copies it to `/opt/codex-windows-worker` and exposes `/usr/local/bin/codex-win`. Every calling project supplies its own `.codex/windows-job-manifest.txt`; the global client packages only those relative paths, sends a project-slugged temporary bundle through the existing reverse tunnel, and returns verified results into that same project.

**Tech Stack:** Bash, OpenSSH, PowerShell 5.1+, Windows Task Scheduler, SHA-256.

**Spec:** `docs/superpowers/specs/2026-08-20-windows-test-worker-design.md`

## Global Constraints

- Each project repository remains only on Linux; Windows receives no `.git` directory, Git credentials, or persistent checkout.
- The Windows OpenSSH server binds only to `127.0.0.1`; no Windows router port or public firewall rule is opened.
- The Linux reverse listener binds only to `127.0.0.1:22022`; the tunnel account cannot open a shell.
- Routine modes are exactly `smoke`, `sync`, `mql`, `acceptance`, and `collect`; no job accepts arbitrary command text.
- Each project opts in with `.codex/windows-job-manifest.txt`; all manifest paths are relative and cannot escape that project root.
- Windows workspaces are `C:\CodexWorker\jobs\<ProjectSlug>\<JobId>` and result bundles return to `<project>/audit/windows-worker/<JobId>`.
- No private key, password, host-specific configuration, OneDrive credential, or `worker.local.psd1` is committed.
- Result schema version is `1`; exit codes are `0` pass, `1` check failure, `2` invalid input, and `3` missing dependency.
- Excel refresh and MT4 Strategy Tester remain interactive Codex Remote checks.

---

### Task 1: Create the generic source distribution and contract tests

**Files:**
- Create: `tools/codex-windows-worker/codex-win`
- Create: `tools/codex-windows-worker/shared-manifest.txt`
- Create: `tools/codex-windows-worker/worker.local.psd1.example`
- Create: `tools/codex-windows-worker/tests/test-codex-win.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces executable `codex-win run --project-root <path> --mode <mode> [--dry-run]`.
- Produces a machine-local configuration at `/etc/codex-windows-worker/worker.local.psd1` created from the example.

- [ ] **Step 1: Write a failing Bash contract test**

```bash
assert_file "$tool_root/codex-win"
assert_file "$tool_root/shared-manifest.txt"
assert_file "$tool_root/worker.local.psd1.example"
assert_match '^\*\.local\.psd1$' "$repo_root/.gitignore"
assert_match '^audit/windows-worker/$' "$repo_root/.gitignore"
```

- [ ] **Step 2: Verify RED**

Run: `bash tools/codex-windows-worker/tests/test-codex-win.sh`

Expected: failure because the distribution is absent.

- [ ] **Step 3: Add the minimal source layout**

The manifest lists only `Run-WindowsJob.ps1`. The configuration example defines `WorkerHost = '127.0.0.1'`, `WorkerPort = 22022`, `WorkerUser = 'CodexWorker'`, `IdentityFile = '/etc/codex-windows-worker/id_ed25519'`, and `MetaEditorPath = ''`.

- [ ] **Step 4: Verify GREEN for the source contract**

Run: `bash tools/codex-windows-worker/tests/test-codex-win.sh`

Expected: test advances to the missing CLI behavior.

### Task 2: Build the project-agnostic Linux client with TDD

**Files:**
- Modify: `tools/codex-windows-worker/codex-win`
- Modify: `tools/codex-windows-worker/tests/test-codex-win.sh`

**Interfaces:**
- Consumes `run --project-root <absolute-path> --mode <known-mode> --manifest <project-relative-path> [--dry-run]`.
- Produces a `ProjectSlug` of `<basename>-<first8-sha256-of-canonical-project-root>`, a sortable JobId, tar bundle, SHA-256 manifest, and a project-local result directory.

- [ ] **Step 1: Add failing client behavior tests**

```bash
expect_failure "$client" run --project-root "$project" --mode evil --dry-run
expect_failure "$client" run --project-root "$project" --mode smoke --manifest ../outside.txt --dry-run
expect_failure "$client" run --project-root "$project" --mode smoke --manifest .codex/bad-manifest.txt --dry-run
expect_success "$client" run --project-root "$project" --mode smoke --dry-run
assert_match 'ProjectSlug: demo-project-' "$last_output"
assert_match 'JobId: [0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}' "$last_output"
assert_file "$project/audit/windows-worker/$last_job_id/bundle.sha256"
```

- [ ] **Step 2: Verify RED**

Run: `bash tools/codex-windows-worker/tests/test-codex-win.sh`

Expected: CLI behavior fails because `codex-win` has no implementation.

- [ ] **Step 3: Implement safe dry-run and transport behavior**

Use `set -euo pipefail`; accept only the five modes; canonicalize the project root; reject absolute, `..`, empty, duplicate, and missing manifest entries; create a temporary staging directory with `mktemp -d`; use `tar --exclude-vcs`; write hashes with `sha256sum`; and copy the shared runner plus caller allowlist only. In non-dry-run, load only `/etc/codex-windows-worker/worker.local.psd1`, call `scp`/`ssh` with `ConnectTimeout=5`, and invoke `Run-WindowsJob.ps1` with only JobId, ProjectSlug, and Mode.

- [ ] **Step 4: Verify GREEN**

Run: `bash tools/codex-windows-worker/tests/test-codex-win.sh`

Expected: all dry-run validation and isolation tests pass without Windows.

### Task 3: Build the bounded Windows dispatcher with TDD

**Files:**
- Create: `tools/codex-windows-worker/Run-WindowsJob.ps1`
- Create: `tools/codex-windows-worker/tests/Test-WindowsWorkerScripts.ps1`

**Interfaces:**
- Consumes `-JobId <id> -ProjectSlug <slug> -Mode <known-mode> -WorkspaceRoot 'C:\CodexWorker\jobs'`.
- Produces `result.json` inside `C:\CodexWorker\jobs\<ProjectSlug>\<JobId>` with schema version, project slug, checks, redacted host details, and hashes.

- [ ] **Step 1: Write failing runner tests**

```powershell
& $runner -JobId 'bad/../id' -ProjectSlug 'demo-a1b2c3d4' -Mode smoke -WorkspaceRoot $tempRoot
if($LASTEXITCODE -ne 2) { throw 'Traversal JobId must be exit code 2.' }
& $runner -JobId '20260820T180000Z-abcdef12' -ProjectSlug 'bad/../slug' -Mode smoke -WorkspaceRoot $tempRoot
if($LASTEXITCODE -ne 2) { throw 'Traversal ProjectSlug must be exit code 2.' }
& $runner -JobId '20260820T180000Z-abcdef12' -ProjectSlug 'demo-a1b2c3d4' -Mode evil -WorkspaceRoot $tempRoot
if($LASTEXITCODE -ne 2) { throw 'Unknown mode must be exit code 2.' }
```

- [ ] **Step 2: Verify RED on Windows**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\codex-windows-worker\tests\Test-WindowsWorkerScripts.ps1`

Expected: failure because runner is absent.

- [ ] **Step 3: Implement bounded modes and result schema**

Implement strict validation, `New-WorkerResult`, `Add-WorkerCheck`, artifact hash recording, and redaction. `smoke` checks Windows version, PowerShell, worker identity, sshd service, and creates a text artifact. `sync` executes only the packaged sync test; `mql` requires a valid explicit MetaEditor path and otherwise returns `3`; `acceptance` runs non-GUI checks; `collect` returns an existing valid JSON result only.

- [ ] **Step 4: Verify GREEN on Windows**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\codex-windows-worker\tests\Test-WindowsWorkerScripts.ps1`

Expected: mode rejection, result schema, and smoke tests pass.

### Task 4: Build and test Windows bootstrap and reverse tunnel

**Files:**
- Create: `tools/codex-windows-worker/Bootstrap-WindowsWorker.ps1`
- Create: `tools/codex-windows-worker/Run-ReverseTunnel.ps1`
- Modify: `tools/codex-windows-worker/tests/Test-WindowsWorkerScripts.ps1`

**Interfaces:**
- Bootstrap consumes `-LinuxHost`, `-LinuxHostKey`, and `-LinuxWorkerPublicKey`; it prints only the generated Windows tunnel public key and status.
- Tunnel opens exactly `-R 127.0.0.1:22022:localhost:22` as a `SYSTEM` startup task named `Codex-WindowsWorker-ReverseTunnel`.

- [ ] **Step 1: Add failing static security tests**

```powershell
Assert-Text $bootstrap 'ListenAddress 127.0.0.1'
Assert-Text $bootstrap 'OpenSSH-Server-In-TCP'
Assert-Text $tunnel '-R 127.0.0.1:22022:localhost:22'
Assert-Text $tunnel 'StrictHostKeyChecking=yes'
Assert-Text $tunnel 'ExitOnForwardFailure=yes'
Assert-Text $bootstrap 'Codex-WindowsWorker-ReverseTunnel'
```

- [ ] **Step 2: Verify RED**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\codex-windows-worker\tests\Test-WindowsWorkerScripts.ps1 -StaticOnly`

Expected: failure because bootstrap/tunnel scripts are absent.

- [ ] **Step 3: Implement idempotent machine setup**

Require elevation; install OpenSSH only if missing; configure `sshd` loopback-only and automatic; disable its public firewall rule; create a standard local `CodexWorker`; restrict workspace and key ACLs; write Linux's public worker key; generate SYSTEM-readable tunnel key under `C:\ProgramData\CodexWindowsWorker`; pin the Linux host key; and register the startup SYSTEM task. The reconnect wrapper must use batch mode, strict pinned host verification, `ExitOnForwardFailure=yes`, server-alive options, and ten-second reconnects.

- [ ] **Step 4: Verify GREEN**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\codex-windows-worker\tests\Test-WindowsWorkerScripts.ps1 -StaticOnly`

Expected: all confinement controls are asserted.

### Task 5: Add installation, any-project onboarding, and removal documentation

**Files:**
- Create: `tools/codex-windows-worker/WINDOWS_TEST_WORKER_SETUP.md`
- Create: `tools/codex-windows-worker/install-linux.sh`
- Modify: `tools/codex-windows-worker/tests/test-codex-win.sh`

**Interfaces:**
- `install-linux.sh` installs source to `/opt/codex-windows-worker`, links `/usr/local/bin/codex-win`, and creates `/etc/codex-windows-worker` with mode `0700`.
- The guide defines a project onboarding command and teardown steps for both hosts.

- [ ] **Step 1: Write failing installation/documentation checks**

```bash
assert_file "$tool_root/install-linux.sh"
assert_file "$tool_root/WINDOWS_TEST_WORKER_SETUP.md"
assert_match '/opt/codex-windows-worker' "$tool_root/install-linux.sh"
assert_match '127.0.0.1:22022' "$tool_root/WINDOWS_TEST_WORKER_SETUP.md"
assert_match 'no Windows router port' "$tool_root/WINDOWS_TEST_WORKER_SETUP.md"
assert_match '.codex/windows-job-manifest.txt' "$tool_root/WINDOWS_TEST_WORKER_SETUP.md"
```

- [ ] **Step 2: Verify RED**

Run: `bash tools/codex-windows-worker/tests/test-codex-win.sh`

Expected: failure because installer and guide are absent.

- [ ] **Step 3: Implement installer and guide**

Document the Linux restricted `winworker-tunnel` account/key authorization, one elevated Windows bootstrap, the safe public-key exchange, pair-once Codex Remote GUI use, creation of project manifests, sample `codex-win run`, tunnel key rotation, and explicit removal commands. State that no private key, password, or pairing code is sent in chat.

- [ ] **Step 4: Verify GREEN**

Run: `bash tools/codex-windows-worker/tests/test-codex-win.sh && git diff --check`

Expected: all Linux source, installation, and documentation checks pass.

### Task 6: Install and validate against the real Windows host

**Files:**
- Verify: `tools/codex-windows-worker/**`

**Interfaces:**
- Consumes the committed tool, a Windows-generated tunnel public key, and one user-approved elevated Windows bootstrap execution.
- Produces `/usr/local/bin/codex-win`, a loopback-only Windows tunnel, and a verified smoke result in a project audit directory.

- [ ] **Step 1: Install the shared client on Linux**

Run: `sudo tools/codex-windows-worker/install-linux.sh`

Expected: `/usr/local/bin/codex-win --help` succeeds and configuration remains outside all project repositories.

- [ ] **Step 2: Create restricted Linux tunnel access**

Create `winworker-tunnel` with `/usr/sbin/nologin`; authorize only the Windows tunnel public key with `restrict,no-pty,no-agent-forwarding,no-X11-forwarding,permitlisten="127.0.0.1:22022"`; verify it cannot run a shell.

- [ ] **Step 3: Bootstrap Windows once and install its public tunnel key**

Run the documented elevated command; copy back only the printed Windows tunnel public key; install it for `winworker-tunnel`; verify Linux sees `127.0.0.1:22022` and `ssh -p 22022 CodexWorker@127.0.0.1 whoami` returns the standard account.

- [ ] **Step 4: Onboard and smoke-test the first project**

```bash
mkdir -p .codex
printf '%s\n' 'README.md' > .codex/windows-job-manifest.txt
codex-win run --project-root "$PWD" --mode smoke
```

Expected: `audit/windows-worker/<JobId>/result.json` is hash-verified and reports `Passed`; an offline Windows host returns `WorkerUnavailable` within five seconds.
