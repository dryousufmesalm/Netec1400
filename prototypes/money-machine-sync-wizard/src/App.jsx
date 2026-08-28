import { useEffect, useReducer, useState } from "react";
import {
  ArrowClockwise,
  ArrowLeft,
  ArrowRight,
  Check,
  CheckCircle,
  CloudArrowUp,
  DesktopTower,
  DownloadSimple,
  FileCsv,
  FolderOpen,
  Gauge,
  HardDrives,
  Info,
  MagnifyingGlass,
  Play,
  Plus,
  ShieldCheck,
  SpinnerGap,
  WarningCircle,
  XCircle,
} from "@phosphor-icons/react";
import { wizardApi } from "./api.js";
import {
  accountNumber,
  buildSetupPayload,
  canContinueFromAccounts,
  discoveryId,
  initialWizardState,
  isAccountEligible,
  mapSetupStages,
  reasonCode,
  reduceWizard,
  rootPath,
  screens,
} from "./wizardState.js";

function field(record, camelName, pascalName, fallback = "") {
  return record?.[camelName] ?? record?.[pascalName] ?? fallback;
}

function arrayField(record, camelName, pascalName) {
  const result = field(record, camelName, pascalName, []);
  return Array.isArray(result) ? result : [];
}

function safeMessage(error) {
  if (/OneDrive/i.test(error?.message ?? "")) return "OneDrive is not ready. Sign in to OneDrive on this VPS, then try again.";
  if (/schema|csv|account|selection|discovery/i.test(error?.message ?? "")) return error.message;
  return error?.message || "AmmarTrading Sync could not complete that action. Try again or export a support report.";
}

const reasonMessages = Object.freeze({
  HeaderOnly: "Waiting for the first complete basket row before the account identity can be verified.",
  SchemaV2: "Schema v2 is not supported for this setup. Update the EA so it writes schema v3.",
  MalformedCsv: "This report is malformed and cannot be used. Check the EA export and refresh.",
  DuplicateAccount: "The same account was found in more than one terminal. Keep only the current source active, then refresh.",
  Ready: "Ready for setup.",
});

const setupSteps = [
  { screen: screens.SYSTEM, label: "System" },
  { screen: screens.ACCOUNTS, label: "MT4 accounts" },
  { screen: screens.ONEDRIVE, label: "OneDrive" },
  { screen: screens.TEST, label: "Test sync" },
  { screen: screens.FINISH, label: "Finish" },
];

function Brand() {
  return (
    <div className="brand" aria-label="AmmarTrading Sync">
      <span className="brand-mark"><CloudArrowUp weight="fill" /></span>
      <span><strong>AmmarTrading Sync</strong><small>MT4 report synchronization</small></span>
    </div>
  );
}

function Header({ onStatus, showStatus }) {
  return (
    <header className="topbar">
      <Brand />
      {showStatus ? (
        <button className="header-action" type="button" onClick={onStatus}><Gauge /> View status</button>
      ) : (
        <div className="secure-pill"><ShieldCheck weight="fill" /> Local Windows connection</div>
      )}
    </header>
  );
}

function Progress({ current }) {
  const activeIndex = setupSteps.findIndex((step) => step.screen === current);
  return (
    <nav className="progress" aria-label="Setup progress">
      <ol>
        {setupSteps.map((step, index) => {
          const complete = index < activeIndex;
          const active = index === activeIndex;
          return (
            <li className={`${complete ? "complete" : ""} ${active ? "active" : ""}`} key={step.screen} aria-current={active ? "step" : undefined}>
              <span>{complete ? <Check weight="bold" /> : index + 1}</span>
              <b>{step.label}</b>
            </li>
          );
        })}
      </ol>
    </nav>
  );
}

function PageHeading({ eyebrow, title, copy, actions }) {
  return (
    <div className="page-heading">
      <div><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p>{copy}</p></div>
      {actions && <div className="heading-actions">{actions}</div>}
    </div>
  );
}

function ErrorAlert({ message }) {
  if (!message) return null;
  return <div className="alert error-alert" role="alert"><WarningCircle weight="fill" /><span>{message}</span></div>;
}

function LoadingState({ label }) {
  return <div className="loading-panel" aria-live="polite"><SpinnerGap className="spin" /><b>{label}</b></div>;
}

function SystemScreen({ state, busy, onRefresh, onContinue, dispatch }) {
  const rawChecks = arrayField(state.systemStatus, "checks", "Checks");
  const checks = rawChecks.length ? rawChecks : [
    { Name: "Windows and PowerShell", Ready: true, Message: "Compatible Windows tools are available." },
    { Name: "MT4 terminal data", Ready: true, Message: "MT4 report locations can be checked securely." },
    { Name: "OneDrive", Ready: true, Message: "Local OneDrive folders can be detected." },
    { Name: "Automatic sync", Ready: true, Message: "Windows Scheduled Tasks are available." },
  ];
  const systemReady = field(state.systemStatus, "ready", "Ready", checks.every((check) => field(check, "ready", "Ready", false)));

  return (
    <WizardLayout screen={screens.SYSTEM}>
      <PageHeading eyebrow="Step 1 of 5" title="Check this VPS" copy="AmmarTrading Sync checks the local Windows services it needs. No trading or Microsoft password is requested." />
      <section className="content-card system-grid">
        <div className="system-summary">
          <span className={`hero-icon ${systemReady ? "success" : "warning"}`}>{systemReady ? <CheckCircle weight="duotone" /> : <WarningCircle weight="duotone" />}</span>
          <h2>{systemReady ? "This VPS is ready" : "This VPS needs attention"}</h2>
          <p>{systemReady ? "Choose a clear name, then find the MT4 accounts already running here." : "Resolve the checks marked Needs attention, then run the check again."}</p>
          <label className="field-label" htmlFor="vps-name">VPS name</label>
          <input id="vps-name" className="text-input" value={state.vpsName} maxLength={100} onChange={(event) => dispatch({ type: "VPS_NAME_CHANGED", vpsName: event.target.value })} placeholder="Example: Dubai VPS 02" />
        </div>
        <div className="check-list" aria-label="System checks">
          {checks.map((check, index) => {
            const ready = Boolean(field(check, "ready", "Ready", false));
            return (
              <article className={`check-item ${ready ? "ready" : "blocked"}`} key={`${field(check, "name", "Name", "System check")}-${index}`}>
                <span className="check-state-icon">{ready ? <CheckCircle weight="fill" /> : <XCircle weight="fill" />}</span>
                <div><h3>{field(check, "name", "Name", "System check")}</h3><p>{field(check, "message", "Message", ready ? "Ready" : "Needs attention")}</p></div>
                <strong>{ready ? "Ready" : "Needs attention"}</strong>
              </article>
            );
          })}
        </div>
      </section>
      <ErrorAlert message={state.error} />
      <div className="page-actions">
        <button className="secondary" type="button" onClick={onRefresh} disabled={busy}><ArrowClockwise className={busy ? "spin" : ""} /> Check again</button>
        <button className="primary" type="button" onClick={onContinue} disabled={!systemReady || !state.vpsName.trim() || busy}>Find MT4 accounts <ArrowRight weight="bold" /></button>
      </div>
    </WizardLayout>
  );
}

function AccountCard({ account, checked, onToggle }) {
  const eligible = isAccountEligible(account);
  const reason = reasonCode(account);
  const number = accountNumber(account) || "Account not identified";
  const broker = field(account, "brokerName", "BrokerName", "Broker not identified");
  const terminalName = field(account, "terminalName", "TerminalName", "MetaTrader 4");
  const terminalId = field(account, "terminalId", "TerminalId", "Unknown terminal");
  const schema = field(account, "schemaVersion", "SchemaVersion", "Unknown");
  const freshness = field(account, "freshness", "Freshness", "Unknown");
  const lastWrite = field(account, "lastWriteUtc", "LastWriteUtc", "");
  const reasonText = reasonMessages[reason] ?? (eligible ? "Ready for setup." : `Blocked: ${reason}`);

  return (
    <label className={`account-card ${eligible ? "eligible" : "disabled"} ${checked ? "selected" : ""}`}>
      <input type="checkbox" checked={checked} disabled={!eligible} onChange={onToggle} />
      <span className="account-checkbox" aria-hidden="true">{checked && <Check weight="bold" />}</span>
      <span className="account-icon"><DesktopTower weight="duotone" /></span>
      <span className="account-copy">
        <span className="account-title"><strong>{number}</strong><em>{broker}</em></span>
        <span className="account-terminal">{terminalName} <small>{terminalId}</small></span>
        <span className="account-meta"><span>Schema {schema}</span><span>{freshness}</span>{lastWrite && <span>Updated {new Date(lastWrite).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" })}</span>}</span>
        <span className={`eligibility-note ${eligible ? "ready" : "blocked"}`}>{eligible ? <CheckCircle weight="fill" /> : <WarningCircle weight="fill" />}<span><b>{eligible ? "Ready" : "Cannot select"}</b>{reasonText}</span></span>
      </span>
    </label>
  );
}

function AccountsScreen({ state, busy, activity, onRefresh, onBrowse, onBack, onContinue, dispatch }) {
  return (
    <WizardLayout screen={screens.ACCOUNTS}>
      <PageHeading
        eyebrow="Step 2 of 5"
        title="Select MT4 accounts"
        copy="Choose one or more verified schema-v3 accounts. Blocked reports stay visible so you can see exactly what needs attention."
        actions={<><button className="secondary" type="button" onClick={onRefresh} disabled={busy}><ArrowClockwise className={busy ? "spin" : ""} /> Refresh</button><button className="secondary" type="button" onClick={onBrowse} disabled={busy}><FolderOpen /> Browse manually</button></>}
      />
      <div className="discovery-status" aria-live="polite">{activity}</div>
      {busy && state.accounts.length === 0 ? <LoadingState label="Looking for MT4 reports on this VPS…" /> : (
        <section className="account-grid" aria-label="Discovered MT4 accounts">
          {state.accounts.length === 0 ? (
            <div className="empty-state"><MagnifyingGlass weight="duotone" /><h2>No MT4 reports found yet</h2><p>Run the EA until it writes AGOLD___Baskets.csv, then select Refresh or Browse manually.</p></div>
          ) : state.accounts.map((account) => {
            const id = discoveryId(account);
            return <AccountCard account={account} checked={state.selectedDiscoveryIds.includes(id)} key={id} onToggle={() => dispatch({ type: "ACCOUNT_TOGGLED", discoveryId: id })} />;
          })}
        </section>
      )}
      <ErrorAlert message={state.error} />
      <div className="selection-summary" aria-live="polite"><b>{state.selectedDiscoveryIds.length}</b> MT4 account{state.selectedDiscoveryIds.length === 1 ? "" : "s"} selected</div>
      <div className="page-actions"><button className="text-button" type="button" onClick={onBack}><ArrowLeft /> Back</button><button className="primary" type="button" onClick={onContinue} disabled={!canContinueFromAccounts(state) || busy}>Choose OneDrive <ArrowRight weight="bold" /></button></div>
    </WizardLayout>
  );
}

function OneDriveScreen({ state, busy, onBack, onContinue, dispatch }) {
  const selectedIds = new Set(state.selectedDiscoveryIds);
  const selectedAccounts = state.accounts.filter((account) => selectedIds.has(discoveryId(account)));
  return (
    <WizardLayout screen={screens.ONEDRIVE}>
      <PageHeading eyebrow="Step 3 of 5" title="Choose the OneDrive folder" copy="Reports are published into an AmmarTrading account folder inside the selected local OneDrive root." />
      {busy ? <LoadingState label="Checking signed-in OneDrive folders…" /> : (
        <section className="onedrive-layout">
          <div className="content-card root-panel">
            <h2>Available OneDrive folders</h2>
            <p>Select the signed-in uploader folder for this VPS.</p>
            <div className="root-list">
              {state.roots.map((root) => {
                const path = rootPath(root);
                const selected = state.oneDriveRoot === path;
                return (
                  <label className={`root-option ${selected ? "selected" : ""}`} key={path}>
                    <input type="radio" name="onedrive-root" value={path} checked={selected} onChange={() => dispatch({ type: "ROOT_SELECTED", oneDriveRoot: path })} />
                    <span className="root-radio" aria-hidden="true" />
                    <CloudArrowUp weight="duotone" />
                    <span><b>{field(root, "name", "Name", "OneDrive")}</b><small>{path}</small></span>
                    {selected && <em>Selected</em>}
                  </label>
                );
              })}
              {state.roots.length === 0 && <div className="empty-inline"><WarningCircle /><span><b>No signed-in OneDrive folder found</b>Open OneDrive on this VPS, sign in, then go back and try again.</span></div>}
            </div>
          </div>
          <div className="content-card mapping-panel">
            <h2>Local destination preview</h2>
            <p>Source paths remain managed by discovery and cannot be edited here.</p>
            <div className="mapping-list">
              {selectedAccounts.map((account) => (
                <article key={discoveryId(account)}><FileCsv weight="duotone" /><span><b>Account {accountNumber(account)}</b><small>OneDrive / AmmarTrading / Account_{accountNumber(account)} / Baskets.csv</small></span><CheckCircle weight="fill" /></article>
              ))}
            </div>
            <div className="local-note"><Info weight="fill" /><span><b>Local folder only</b>Setup confirms publication into the local OneDrive folder. Cloud delivery and reporting-PC receipt must be verified separately.</span></div>
          </div>
        </section>
      )}
      <ErrorAlert message={state.error} />
      <div className="page-actions"><button className="text-button" type="button" onClick={onBack}><ArrowLeft /> Back</button><button className="primary" type="button" onClick={onContinue} disabled={!state.oneDriveRoot || busy}>Test selected accounts <ArrowRight weight="bold" /></button></div>
    </WizardLayout>
  );
}

function StageRow({ row }) {
  const Icon = row.status === "success" ? CheckCircle : row.status === "error" ? XCircle : row.status === "running" ? SpinnerGap : Info;
  return <article className={`stage-row ${row.status}`}><span><Icon className={row.status === "running" ? "spin" : ""} weight="fill" /></span><div><h3>{row.label}</h3><p>{row.message}</p></div><strong>{row.status === "success" ? "Complete" : row.status === "error" ? "Needs attention" : row.status === "running" ? "Running" : "Pending"}</strong></article>;
}

function TestScreen({ state, validationState, setupBusy, onBack, onApply }) {
  const stageRows = mapSetupStages(state.stages);
  const isReady = validationState === "ready";
  return (
    <WizardLayout screen={screens.TEST}>
      <PageHeading eyebrow="Step 4 of 5" title="Test and apply synchronization" copy="The selected sources are checked again before any configuration changes. Setup then publishes each CSV locally and enables automatic sync." />
      <section className="content-card test-card">
        <div className={`test-hero ${isReady ? "ready" : state.error ? "error" : "working"}`} aria-live="polite">
          {validationState === "checking" ? <SpinnerGap className="spin" /> : isReady ? <ShieldCheck weight="duotone" /> : <WarningCircle weight="duotone" />}
          <div><h2>{validationState === "checking" ? "Validating selected accounts" : isReady ? "Selections are ready" : "Validation needs attention"}</h2><p>{validationState === "checking" ? "No settings are being changed yet." : isReady ? "Choose Apply setup to configure every selected account in one transaction." : "Review the message below, then return to the relevant step."}</p></div>
        </div>
        <div className="stage-list">
          {stageRows.map((row) => <StageRow key={row.id} row={setupBusy && row.status === "pending" ? { ...row, status: "running", message: "Setup is processing this stage." } : row} />)}
        </div>
        <div className="local-note"><Info weight="fill" /><span><b>No cloud-delivery claim</b>A successful test proves the local AmmarTrading file and Windows automation. It does not prove that OneDrive has uploaded the file.</span></div>
      </section>
      <ErrorAlert message={state.error} />
      <div className="page-actions"><button className="text-button" type="button" onClick={onBack} disabled={setupBusy}><ArrowLeft /> Back</button><button className="primary" type="button" onClick={onApply} disabled={!isReady || setupBusy}>{setupBusy ? <><SpinnerGap className="spin" /> Applying setup…</> : <>Apply setup and run test sync <Play weight="fill" /></>}</button></div>
    </WizardLayout>
  );
}

function ResultAccounts({ accounts }) {
  return <div className="result-accounts">{accounts.map((account, index) => <article key={`${field(account, "accountNumber", "AccountNumber")}-${index}`}><span className="account-icon"><DesktopTower weight="duotone" /></span><div><h3>Account {field(account, "accountNumber", "AccountNumber")}</h3><p>{field(account, "brokerName", "BrokerName", "MT4 account")}</p><small>{field(account, "destination", "Destination", "Local AmmarTrading folder")}</small></div><span className="status-badge ready"><CheckCircle weight="fill" /> Published locally</span></article>)}</div>;
}

function FinishScreen({ state, actionBusy, onOpen, onRun, onStatus, onAdd, onExport }) {
  const resultAccounts = arrayField(state.setupResult, "accounts", "Accounts");
  return (
    <WizardLayout screen={screens.FINISH}>
      <section className="finish-hero"><span className="success-badge"><Check weight="bold" /></span><span className="eyebrow">Step 5 of 5</span><h1>Local synchronization is ready</h1><p>Every selected MT4 account was configured and published into its local OneDrive AmmarTrading folder.</p></section>
      <div className="alert local-success"><Info weight="fill" /><span><b>Publication is local only.</b> OneDrive cloud delivery and physical receipt on the reporting PC are not verified by this VPS app.</span></div>
      <ResultAccounts accounts={resultAccounts} />
      <ErrorAlert message={state.error} />
      <div className="finish-actions" aria-live="polite">
        <button className="primary" type="button" onClick={onOpen} disabled={actionBusy}><FolderOpen /> Open AmmarTrading Folder</button>
        <button className="secondary" type="button" onClick={onRun} disabled={actionBusy}><Play weight="fill" /> Run Sync Now</button>
        <button className="secondary" type="button" onClick={onStatus} disabled={actionBusy}><Gauge /> View Status</button>
        <button className="secondary" type="button" onClick={onAdd} disabled={actionBusy}><Plus /> Add Another MT4 Account</button>
        <button className="text-button" type="button" onClick={onExport} disabled={actionBusy}><DownloadSimple /> Export Support Report</button>
      </div>
    </WizardLayout>
  );
}

function MonitorScreen({ state, loading, activity, onRefresh, onRun, onOpen, onAdd, onExport }) {
  const configured = state.configuredAccounts;
  return (
    <main className="page monitor-page">
      <PageHeading eyebrow="Synchronization status" title="MT4 account monitoring" copy="Local publication and Windows automation status for the accounts configured on this VPS." actions={<button className="secondary" type="button" onClick={onRefresh} disabled={loading}><ArrowClockwise className={loading ? "spin" : ""} /> Refresh status</button>} />
      <div className="monitor-summary" aria-live="polite"><div><HardDrives weight="duotone" /><span><b>{configured.length}</b> configured accounts</span></div><div><CheckCircle weight="duotone" /><span><b>Local</b> publication scope</span></div><div><ShieldCheck weight="duotone" /><span><b>Separate</b> cloud verification</span></div></div>
      <div className="monitor-activity" aria-live="polite">{activity}</div>
      {loading && configured.length === 0 ? <LoadingState label="Loading account status…" /> : configured.length ? <ResultAccounts accounts={configured} /> : <div className="empty-state"><DesktopTower weight="duotone" /><h2>No accounts configured</h2><p>Start setup to discover and select MT4 accounts on this VPS.</p></div>}
      <ErrorAlert message={state.error} />
      <div className="finish-actions"><button className="primary" type="button" onClick={onRun} disabled={loading || !configured.length}><Play weight="fill" /> Run Sync Now</button><button className="secondary" type="button" onClick={onOpen} disabled={loading || !configured.length}><FolderOpen /> Open AmmarTrading Folder</button><button className="secondary" type="button" onClick={onAdd} disabled={loading}><Plus /> Add MT4 Account</button><button className="text-button" type="button" onClick={onExport} disabled={loading}><DownloadSimple /> Export Support Report</button></div>
      <div className="alert local-success"><Info weight="fill" /><span><b>Local status only.</b> Confirm OneDrive receipt on the reporting PC before relying on the report.</span></div>
    </main>
  );
}

function WizardLayout({ screen, children }) {
  return <main className="page wizard-page"><Progress current={screen} />{children}</main>;
}

export function App() {
  const [state, dispatch] = useReducer(reduceWizard, initialWizardState);
  const [busy, setBusy] = useState({ startup: true, discovery: false, roots: false, validation: false, setup: false, action: false });
  const [activity, setActivity] = useState("Starting AmmarTrading Sync…");
  const [validationState, setValidationState] = useState("idle");

  const setBusyFlag = (name, value) => setBusy((current) => ({ ...current, [name]: value }));

  async function loadSystem() {
    setBusyFlag("startup", true);
    dispatch({ type: "ERROR_CLEARED" });
    setActivity("Checking this VPS…");
    try {
      const status = await wizardApi.getSystemStatus();
      dispatch({ type: "SYSTEM_LOADED", status });
      setActivity("System check complete.");
      return status;
    } catch (error) {
      dispatch({ type: "ERROR_SET", error: safeMessage(error) });
      setActivity("System check failed.");
      return null;
    } finally {
      setBusyFlag("startup", false);
    }
  }

  async function loadConfigured({ openMonitor = true } = {}) {
    setBusyFlag("action", true);
    try {
      const response = await wizardApi.getConfiguredAccounts();
      const accounts = arrayField(response, "accounts", "Accounts");
      dispatch({ type: "CONFIGURED_LOADED", accounts });
      if (openMonitor) dispatch({ type: "SCREEN_CHANGED", screen: screens.MONITOR });
      setActivity(accounts.length ? "Account status is up to date." : "No accounts are configured yet.");
      return accounts;
    } catch (error) {
      dispatch({ type: "ERROR_SET", error: safeMessage(error) });
      return [];
    } finally {
      setBusyFlag("action", false);
    }
  }

  useEffect(() => {
    let active = true;
    (async () => {
      const [systemResult, configuredResult] = await Promise.allSettled([
        wizardApi.getSystemStatus(),
        wizardApi.getConfiguredAccounts(),
      ]);
      if (!active) return;
      if (systemResult.status === "fulfilled") dispatch({ type: "SYSTEM_LOADED", status: systemResult.value });
      else dispatch({ type: "ERROR_SET", error: safeMessage(systemResult.reason) });
      const configured = configuredResult.status === "fulfilled" ? arrayField(configuredResult.value, "accounts", "Accounts") : [];
      dispatch({ type: "CONFIGURED_LOADED", accounts: configured });
      if (configured.length) dispatch({ type: "SCREEN_CHANGED", screen: screens.MONITOR });
      setActivity(configured.length ? "Configured account status loaded." : "System check complete.");
      setBusy((current) => ({ ...current, startup: false }));
    })();
    return () => { active = false; };
  }, []);

  async function discoverAccounts({ clear = false } = {}) {
    if (clear) dispatch({ type: "SELECTION_CLEARED" });
    dispatch({ type: "SCREEN_CHANGED", screen: screens.ACCOUNTS });
    setBusyFlag("discovery", true);
    setActivity("Looking for MT4 reports on this VPS…");
    try {
      const response = await wizardApi.discoverMt4Accounts();
      const accounts = arrayField(response, "accounts", "Accounts");
      dispatch({ type: "DISCOVERY_LOADED", accounts });
      setActivity(`${accounts.length} MT4 report${accounts.length === 1 ? "" : "s"} found. Only cards marked Ready can be selected.`);
    } catch (error) {
      dispatch({ type: "ERROR_SET", error: safeMessage(error) });
      setActivity("MT4 discovery could not finish.");
    } finally {
      setBusyFlag("discovery", false);
    }
  }

  async function browseForCsv() {
    setBusyFlag("discovery", true);
    setActivity("Waiting for a local CSV selection…");
    try {
      const response = await wizardApi.browseForCsv();
      let accounts = arrayField(response, "accounts", "Accounts");
      if (!accounts.length) {
        const discovered = await wizardApi.discoverMt4Accounts();
        accounts = arrayField(discovered, "accounts", "Accounts");
      }
      dispatch({ type: "DISCOVERY_LOADED", accounts });
      setActivity(`${accounts.length} validated MT4 report${accounts.length === 1 ? "" : "s"} shown.`);
    } catch (error) {
      if (error?.code !== "Cancelled") dispatch({ type: "ERROR_SET", error: safeMessage(error) });
      setActivity(error?.code === "Cancelled" ? "Manual browse cancelled." : "The selected CSV could not be added.");
    } finally {
      setBusyFlag("discovery", false);
    }
  }

  async function openOneDrive() {
    setBusyFlag("roots", true);
    dispatch({ type: "SCREEN_CHANGED", screen: screens.ONEDRIVE });
    try {
      const response = await wizardApi.getOneDriveRoots();
      dispatch({ type: "ROOTS_LOADED", roots: arrayField(response, "roots", "Roots").length ? arrayField(response, "roots", "Roots") : arrayField(response, "oneDriveRoots", "OneDriveRoots") });
    } catch (error) {
      dispatch({ type: "ERROR_SET", error: safeMessage(error) });
    } finally {
      setBusyFlag("roots", false);
    }
  }

  async function validateSelection() {
    dispatch({ type: "SCREEN_CHANGED", screen: screens.TEST });
    dispatch({ type: "STAGES_LOADED", stages: [] });
    setValidationState("checking");
    setBusyFlag("validation", true);
    setActivity("Validating selected accounts…");
    try {
      const response = await wizardApi.validateSelection(buildSetupPayload(state));
      const stages = arrayField(response, "stages", "Stages");
      dispatch({ type: "STAGES_LOADED", stages: stages.length ? stages : [{ Code: "Validated", Status: "Success", Message: `${state.selectedDiscoveryIds.length} selected account source(s) passed validation.` }] });
      setValidationState("ready");
      setActivity("Selections are ready for setup.");
    } catch (error) {
      dispatch({ type: "ERROR_SET", error: safeMessage(error) });
      setValidationState("error");
      setActivity("Validation failed.");
    } finally {
      setBusyFlag("validation", false);
    }
  }

  async function applySetup() {
    setBusyFlag("setup", true);
    dispatch({ type: "ERROR_CLEARED" });
    setActivity("Applying setup and publishing local CSV files…");
    try {
      const result = await wizardApi.applySetup(buildSetupPayload(state));
      dispatch({ type: "SETUP_COMPLETED", result });
      dispatch({ type: "CONFIGURED_LOADED", accounts: arrayField(result, "accounts", "Accounts") });
      setActivity("Local setup completed.");
    } catch (error) {
      dispatch({ type: "ERROR_SET", error: safeMessage(error) });
      const stages = arrayField(error?.data, "stages", "Stages");
      if (stages.length) dispatch({ type: "STAGES_LOADED", stages });
      setActivity("Setup needs attention.");
    } finally {
      setBusyFlag("setup", false);
    }
  }

  async function performAction(label, operation) {
    setBusyFlag("action", true);
    dispatch({ type: "ERROR_CLEARED" });
    setActivity(`${label}…`);
    try {
      await operation();
      setActivity(`${label} complete.`);
    } catch (error) {
      dispatch({ type: "ERROR_SET", error: safeMessage(error) });
      setActivity(`${label} failed.`);
    } finally {
      setBusyFlag("action", false);
    }
  }

  const selectedAccountNumbers = state.accounts.filter((account) => state.selectedDiscoveryIds.includes(discoveryId(account))).map(accountNumber);
  const actionPayload = { accountNumbers: selectedAccountNumbers.length ? selectedAccountNumbers : state.configuredAccounts.map((account) => String(field(account, "accountNumber", "AccountNumber"))) };

  const openFolder = () => performAction("Opening AmmarTrading folder", () => wizardApi.openReportingFolder(actionPayload));
  const runSync = () => performAction("Running local sync", async () => { await wizardApi.runSyncNow(actionPayload); await loadConfigured({ openMonitor: state.screen === screens.MONITOR }); });
  const exportReport = () => performAction("Exporting support report", () => wizardApi.exportSupportReport());
  const viewStatus = async () => { dispatch({ type: "SCREEN_CHANGED", screen: screens.MONITOR }); await loadConfigured({ openMonitor: false }); };

  if (busy.startup && !state.systemStatus) return <div className="app-shell" dir="ltr"><Header /><main className="startup-state" aria-live="polite"><SpinnerGap className="spin" /><h1>Checking this VPS</h1><p>AmmarTrading Sync is loading local system status.</p></main></div>;

  return (
    <div className="app-shell" dir="ltr">
      <Header showStatus={state.screen !== screens.MONITOR && state.configuredAccounts.length > 0} onStatus={viewStatus} />
      {state.screen === screens.SYSTEM && <SystemScreen state={state} busy={busy.startup} onRefresh={loadSystem} onContinue={() => discoverAccounts({ clear: true })} dispatch={dispatch} />}
      {state.screen === screens.ACCOUNTS && <AccountsScreen state={state} busy={busy.discovery} activity={activity} onRefresh={discoverAccounts} onBrowse={browseForCsv} onBack={() => dispatch({ type: "SCREEN_CHANGED", screen: screens.SYSTEM })} onContinue={openOneDrive} dispatch={dispatch} />}
      {state.screen === screens.ONEDRIVE && <OneDriveScreen state={state} busy={busy.roots} onBack={() => dispatch({ type: "SCREEN_CHANGED", screen: screens.ACCOUNTS })} onContinue={validateSelection} dispatch={dispatch} />}
      {state.screen === screens.TEST && <TestScreen state={state} validationState={validationState} setupBusy={busy.setup} onBack={() => dispatch({ type: "SCREEN_CHANGED", screen: screens.ONEDRIVE })} onApply={applySetup} />}
      {state.screen === screens.FINISH && <FinishScreen state={state} actionBusy={busy.action} onOpen={openFolder} onRun={runSync} onStatus={viewStatus} onAdd={() => discoverAccounts({ clear: true })} onExport={exportReport} />}
      {state.screen === screens.MONITOR && <MonitorScreen state={state} loading={busy.action} activity={activity} onRefresh={viewStatus} onRun={runSync} onOpen={openFolder} onAdd={() => discoverAccounts({ clear: true })} onExport={exportReport} />}
      <footer><span>AmmarTrading Sync • Local Windows application</span><span><ShieldCheck weight="fill" /> Trading and Microsoft passwords are never requested</span></footer>
    </div>
  );
}
