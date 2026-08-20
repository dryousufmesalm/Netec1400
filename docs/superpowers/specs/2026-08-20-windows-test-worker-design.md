# Windows Test Worker Design

**Status:** Approved in chat on 2026-08-20; written version awaiting final review  
**Date:** 2026-08-20  
**Related design:** `docs/superpowers/specs/2026-08-20-onedrive-csv-production-readiness-design.md`

## Goal

Keep the Git repository and all authoritative edits on the always-on Linux VPS while using a home Windows 11 computer as an on-demand worker for PowerShell, Task Scheduler, MetaEditor/MT4, OneDrive, and Excel acceptance tests.

## Selected architecture

```text
Phone
  |
  | Codex Remote
  v
Linux VPS / authoritative repository
  |
  | SSH to 127.0.0.1:22022 on the VPS
  | through a Windows-originated reverse tunnel
  v
Windows 11 / disposable test workspace
  |- PowerShell and Task Scheduler
  |- MetaEditor and MT4
  |- OneDrive receiver checks
  `- Excel interactive acceptance
```

Windows initiates an outbound SSH connection to the Linux VPS and requests a reverse forwarding endpoint bound only to `127.0.0.1:22022` on Linux. The Linux Codex session then connects to that loopback endpoint to reach Windows OpenSSH. A changing home IP, carrier-grade NAT, and router port forwarding are therefore irrelevant.

Cloudflare is not part of the required path. An existing Cloudflare Tunnel can be retained as a future fallback, but the worker must operate without Cloudflare tokens, browser authentication, or inbound Windows firewall exposure.

## Authority and data ownership

- The Linux checkout is the only authoritative repository.
- Windows never receives a Git clone, Git credentials, or a persistent working copy.
- Each run receives an allowlisted job bundle under `C:\CodexWorker\jobs\<JobId>`.
- Windows returns a result bundle containing JSON, logs, hashes, and explicitly requested build artifacts.
- Result bundles are stored under `audit/windows-worker/<JobId>` on Linux.
- The current Linux working tree, including selected uncommitted files, is the source of a job bundle. `git archive` alone is not used because it would omit relevant working-tree changes.
- A successful collection deletes the remote job only when the caller passes an explicit cleanup option. The default retains the latest three jobs for diagnosis.

## Identities and keys

Four identities or keys have distinct purposes:

1. **Linux operator:** the existing Codex process that invokes `ssh` and `scp`.
2. **Windows worker account:** a local standard account named `CodexWorker`. It has no administrator membership and owns only `C:\CodexWorker` plus explicitly granted test directories.
3. **Linux-to-Windows key:** an ED25519 key stored outside the repository on Linux. Its public key is the only key in `C:\Users\CodexWorker\.ssh\authorized_keys`.
4. **Windows-to-Linux tunnel key:** an ED25519 key generated on Windows and stored under `C:\ProgramData\CodexWindowsWorker`. Its public key is installed for a dedicated Linux account named `winworker-tunnel`.

The Linux tunnel account has no administrative privileges and no general shell use. Its authorized key permits only remote TCP forwarding and only the listener `127.0.0.1:22022`. `GatewayPorts no` keeps the listener inaccessible from the Internet and from other hosts.

The Windows scheduled tunnel runs as `SYSTEM` so it starts at boot without a user logon. Its private key and pinned Linux host key are readable only by `SYSTEM` and local Administrators. The inbound worker login remains the non-administrative `CodexWorker` account.

No private key, password, Cloudflare token, host-specific configuration, or OneDrive credential is committed to Git.

## Windows bootstrap

One idempotent elevated PowerShell script will:

1. Verify Windows 11 and PowerShell 5.1 or newer.
2. Install the built-in OpenSSH Client and Server capabilities when absent.
3. bind `sshd` to `127.0.0.1`, disable its automatically created public inbound firewall rule, set the service to automatic, and start it;
4. create the standard local `CodexWorker` account with a generated non-disclosed password;
5. create `C:\CodexWorker`, the account profile SSH directory, and `C:\ProgramData\CodexWindowsWorker` with narrow ACLs;
6. install the supplied Linux-to-Windows public key for `CodexWorker`;
7. generate the Windows-to-Linux tunnel key if absent;
8. pin the Linux ED25519 host key supplied as a parameter;
9. install a reconnecting reverse-tunnel script;
10. register `Codex-WindowsWorker-ReverseTunnel` as an at-startup `SYSTEM` task;
11. start the task and print only the safe Windows tunnel public key and diagnostic status.

The script does not open router ports. It disables the `OpenSSH-Server-In-TCP` inbound firewall rule created by the Windows capability because the server listens only on loopback. Windows OpenSSH remains reachable through loopback and the established reverse tunnel.

## Reverse-tunnel lifecycle

The Windows tunnel process uses the built-in `ssh.exe` with:

- batch-mode key authentication;
- strict pinned-host-key checking;
- `ExitOnForwardFailure=yes`;
- `ServerAliveInterval=30`;
- `ServerAliveCountMax=3`;
- remote forwarding from Linux `127.0.0.1:22022` to Windows `localhost:22`;
- no command, terminal, agent forwarding, or additional tunnels.

If the home connection drops, the wrapper waits ten seconds and reconnects. If Windows sleeps or powers off, the worker is simply unavailable. Linux detects that state within five seconds and reports `WorkerUnavailable`; it never treats an offline optional worker as a repository failure.

## Job protocol

The Linux orchestrator accepts a mode, an allowlisted manifest, and optional tool paths. It creates a unique sortable job ID, records SHA-256 hashes, packages only manifest entries, sends the bundle, invokes the Windows runner, collects the result, and verifies returned hashes.

Supported modes are:

- `smoke`: Windows version, PowerShell versions, account identity, OpenSSH status, filesystem permissions, and round-trip artifact test.
- `sync`: PowerShell CSV sync and scheduled-task contract tests.
- `mql`: MetaEditor command-line compilation plus compiler-log collection.
- `acceptance`: all non-GUI production-readiness checks.
- `collect`: retrieve an already completed job without rerunning it.

Every Windows run writes `result.json` with this stable shape:

```json
{
  "schemaVersion": 1,
  "jobId": "20260820T180000Z-abcdef12",
  "mode": "smoke",
  "startedAtUtc": "2026-08-20T18:00:00Z",
  "completedAtUtc": "2026-08-20T18:00:05Z",
  "status": "Passed",
  "exitCode": 0,
  "host": {
    "os": "Windows 11",
    "computerName": "redacted",
    "powershell": "5.1"
  },
  "checks": [
    {"name": "OpenSSH", "status": "Passed", "evidence": "sshd running"}
  ],
  "artifacts": [
    {"path": "logs/smoke.log", "sha256": "hex-digest"}
  ]
}
```

Computer name and local paths are redacted by default. Exit code `0` means every requested check passed, `1` means a check failed, `2` means invalid job input, and `3` means a required Windows dependency is unavailable.

## Windows command boundaries

The worker runner accepts only known modes and scripts present in the hash-verified job manifest. It does not accept an arbitrary command string from a job JSON file. The Linux operator can still use an interactive SSH shell for diagnosis, but routine automation uses the bounded runner and produces auditable results.

Administrative changes are excluded from routine jobs. Registering production tasks, changing OneDrive configuration, installing MetaTrader, or changing Excel settings requires an explicit user-approved elevated step on Windows.

## MetaEditor and MT4

MetaEditor compilation is a CLI job. The caller supplies a validated absolute `metaeditor.exe` path through the uncommitted local worker configuration. The runner copies the MQ4 source and required includes into the job directory, invokes MetaEditor, collects its log and generated EX4, and fails if the log contains compilation errors or the EX4 is absent.

Launching MT4 for an interactive Strategy Tester session is not treated as a headless SSH check. The Linux job prepares inputs and records the requested test, then the user opens the Windows host through Codex Remote to complete the UI step. The resulting report is collected through the same worker job.

## OneDrive and Excel

The `CodexWorker` account does not receive broad access to the primary user's profile. The user may grant it Modify access to one dedicated staging folder inside OneDrive for filesystem-level tests. Production OneDrive sign-in remains attached to the user's interactive Windows session.

Linux can remotely verify the OneDrive process, staging-folder files, hashes, timestamps, and receiver heartbeat. It cannot claim cloud delivery from a local write alone.

Excel visual refresh remains an interactive acceptance step because unattended Office automation is not a reliable production mechanism. The worker prepares the workbook and evidence directory; the user uses Codex Remote on the Windows host to refresh and inspect it, then the worker collects the saved workbook and acceptance evidence.

## Codex Remote role

The eight-character pairing flow connects a trusted phone or supported desktop app to the Windows ChatGPT/Codex host. It lets the user start or continue Windows-hosted chats, approve actions, inspect screenshots, and use Computer Use while Windows is awake, online, and unlocked.

Codex Remote is not treated as an agent-to-agent API and is not used for Linux-to-Windows shell automation. Its only role in this design is the occasional interactive MetaTrader, OneDrive, or Excel step.

## Repository files

The implementation will add:

- `automation/WindowsTestWorker/Invoke-WindowsWorker.sh` — Linux job packaging, transport, invocation, collection, and hash verification.
- `automation/WindowsTestWorker/Bootstrap-WindowsWorker.ps1` — idempotent elevated Windows setup.
- `automation/WindowsTestWorker/Run-ReverseTunnel.ps1` — reconnect loop installed by bootstrap.
- `automation/WindowsTestWorker/Run-WindowsJob.ps1` — bounded Windows job dispatcher and result writer.
- `automation/WindowsTestWorker/job-manifest.txt` — default allowlist for production-readiness tests.
- `automation/WindowsTestWorker/worker.local.psd1.example` — non-secret configuration schema.
- `tests/Test-WindowsWorkerPackaging.sh` — Linux-side packaging and result validation checks.
- `tests/Test-WindowsWorkerScripts.ps1` — Windows idempotency, input rejection, result schema, and smoke checks.
- `WINDOWS_TEST_WORKER_SETUP.md` — setup, use, troubleshooting, key rotation, and removal guide.

The implementation will add `automation/WindowsTestWorker/worker.local.psd1` and `audit/windows-worker/` to `.gitignore`. The audit directory may contain machine-specific evidence; selected redacted acceptance reports can be copied deliberately into a tracked delivery location after review.

## Rollout sequence

1. Implement and test Linux packaging locally without a live Windows host.
2. Implement and statically validate the Windows scripts.
3. Create the restricted Linux tunnel account and Linux-to-Windows key outside Git.
4. Run the one-time Windows bootstrap as Administrator.
5. Install the printed Windows tunnel public key for the restricted Linux account.
6. Start the reverse tunnel and verify the Linux loopback listener.
7. Run `smoke`, collect `result.json`, and verify hashes.
8. Run `sync`, then `mql`, then the complete non-GUI acceptance mode.
9. Pair Codex Remote with Windows for the remaining interactive checks.
10. Rotate the temporary bootstrap key into the durable worker key and record the key-removal procedure.

## Acceptance criteria

- The repository remains only on Linux; Windows contains no `.git` directory.
- Windows exposes no SSH port through the home router or a public firewall rule.
- The reverse listener is bound only to Linux `127.0.0.1:22022`.
- The tunnel key cannot obtain a Linux shell or create another listener.
- Linux logs into Windows only as the standard `CodexWorker` account.
- Disconnecting and reconnecting home Internet restores the tunnel automatically.
- An offline or sleeping Windows host is reported within five seconds.
- A smoke job transfers only allowlisted files and returns a verified result bundle.
- A malicious mode name, traversal path, or unexpected script is rejected with exit code `2`.
- MetaEditor compilation returns the compiler log and EX4 without creating a persistent Windows repository.
- Interactive OneDrive, Excel, and MT4 evidence can be completed through Codex Remote and collected into the same Linux audit tree.
- All keys, scheduled tasks, accounts, files, and Linux tunnel configuration have documented removal commands.

## External references

- OpenAI documents native Windows PowerShell support in the desktop app: <https://learn.chatgpt.com/docs/windows/windows-app>
- OpenAI documents that Remote uses the connected host's own files, tools, permissions, and Computer Use, and requires the host to remain awake and online: <https://learn.chatgpt.com/docs/remote-connections>
- Microsoft documents Windows 11 OpenSSH installation and key authentication: <https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse> and <https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement>
- Microsoft does not recommend unattended non-interactive Office automation: <https://support.microsoft.com/id-id/visio/considerations-for-server-side-automation-of-office>
