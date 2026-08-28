import { useEffect, useState } from "react";
import {
  ArrowLeft,
  ArrowRight,
  Check,
  CheckCircle,
  CloudArrowUp,
  DesktopTower,
  FileCsv,
  FolderOpen,
  GearSix,
  HardDrives,
  Info,
  LockKey,
  MicrosoftExcelLogo,
  Plus,
  ShieldCheck,
  SpinnerGap,
} from "@phosphor-icons/react";
import { wizardApi } from "./api.js";

const seedAccounts = [
  { id: 1, name: "VPS London 01", account: "1024587", files: 18, updated: "2 minutes ago" },
  { id: 2, name: "VPS New York", account: "2048651", files: 12, updated: "5 minutes ago" },
  { id: 3, name: "VPS Frankfurt", account: "3097742", files: 9, updated: "8 minutes ago" },
];

const initialForm = {
  name: "",
  account: "",
  path: "",
  oneDriveRoot: "",
};

function mapApiAccount(item) {
  return {
    id: item.expectedMT4Login,
    name: item.vpsName || `VPS ${item.expectedMT4Login}`,
    account: item.expectedMT4Login,
    files: item.files ?? 0,
    updated: item.localPublished ? "Published locally" : item.enabled ? "Waiting for first publish" : "Paused",
    enabled: item.enabled,
  };
}

function formatSetupError(message = "") {
  if (/AccountNumber|ExpectedMT4Login|account number/i.test(message)) {
    return "The MT4 account number does not match the account in the CSV file. Check the number and try again.";
  }
  if (/OneDrive/i.test(message)) return "The OneDrive folder is not ready. Open OneDrive, confirm that you are signed in, and try again.";
  if (/Source CSV|\.csv|schema/i.test(message)) return "The MT4 report file is invalid or not ready. Select the correct AGOLD___Baskets.csv file.";
  if (/ScheduledTask|scheduled task/i.test(message)) return "The file was published, but automatic sync could not be enabled. Run the wizard as administrator or contact support.";
  return "Setup could not be completed. Review the details and try again. Contact support if the problem continues.";
}

function Brand() {
  return (
    <button className="brand" type="button" aria-label="Return to dashboard">
      <span className="brand-mark"><CloudArrowUp weight="fill" /></span>
      <span><strong>AmmarTrading Sync</strong><small>CSV synchronization</small></span>
    </button>
  );
}

function Header({ onHome }) {
  return (
    <header className="topbar">
      <div onClick={onHome}><Brand /></div>
      <div className="secure-pill"><ShieldCheck weight="fill" /> Secure connection</div>
    </header>
  );
}

function ServerIllustration() {
  return (
    <div className="sync-visual" aria-label="CSV files moving from VPS devices to OneDrive">
      <div className="server-stack">
        {["London 01", "New York", "Frankfurt"].map((label, index) => (
          <div className="mini-server" key={label} style={{ "--delay": `${index * 0.45}s` }}>
            <DesktopTower weight="duotone" />
            <span>{label}</span>
            <i />
          </div>
        ))}
      </div>
      <div className="flow-track"><span /><span /><span /></div>
      <div className="cloud-card">
        <CloudArrowUp weight="duotone" />
        <strong>OneDrive</strong>
        <span>AmmarTrading</span>
        <FileCsv className="csv-float" weight="fill" />
      </div>
    </div>
  );
}

function EmptyIntro({ accounts, onAdd }) {
  const totalFiles = accounts.reduce((sum, account) => sum + account.files, 0);
  return (
    <main className="page overview-page">
      <section className="hero-grid">
        <div className="hero-copy">
          <span className="eyebrow"><CloudArrowUp weight="fill" /> Automatic and secure sync</span>
          <h1>All VPS reports<br /><em>in one place</em></h1>
          <p>Add a new VPS in minutes. Its CSV reports will automatically appear in OneDrive on your reporting PC.</p>
          <div className="hero-actions">
            <button className="primary large" type="button" onClick={onAdd}>
              <Plus weight="bold" /> Add a new VPS
            </button>
            <span className="helper"><CheckCircle weight="fill" /> No complicated technical setup</span>
          </div>
        </div>
        <ServerIllustration />
      </section>

      <section className="dashboard-section">
        <div className="section-heading">
          <div><h2>Connected devices</h2><p>Latest synchronization status for every account</p></div>
          <button className="secondary" type="button" onClick={onAdd}><Plus weight="bold" /> Add device</button>
        </div>
        <div className="stats-row">
          <div className="stat"><HardDrives weight="duotone" /><span><b>{accounts.length}</b> connected devices</span></div>
          <div className="stat"><FileCsv weight="duotone" /><span><b>{totalFiles}</b> CSV files</span></div>
          <div className="stat"><CheckCircle weight="fill" /><span><b>Active</b> all sync jobs</span></div>
        </div>
        <div className="account-list">
          {accounts.length === 0 && <div className="empty-accounts"><DesktopTower weight="duotone" /><b>No VPS has been added yet</b><span>Select Add a new VPS and the wizard will handle the rest.</span></div>}
          {accounts.map((item) => (
            <article className="account-row" key={item.id}>
              <div className="account-main"><span className="device-icon"><DesktopTower weight="duotone" /></span><div><h3>{item.name}</h3><p>MT4 account {item.account}</p></div></div>
              <div className="file-count"><FileCsv /> {item.files} files</div>
              <div className="update-time">Last sync<br /><b>{item.updated}</b></div>
              <span className={`status ${item.enabled === false ? "paused" : "success"}`}><i /> {item.enabled === false ? "Paused" : "Active"}</span>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}

function Stepper({ current }) {
  const steps = ["VPS details", "Readiness check", "Setup complete"];
  return (
    <div className="stepper" aria-label={`Step ${current} of 3`}>
      {steps.map((label, index) => {
        const number = index + 1;
        const complete = number < current;
        const active = number === current;
        return (
          <div className={`step ${active ? "active" : ""} ${complete ? "complete" : ""}`} key={label}>
            <span>{complete ? <Check weight="bold" /> : number}</span>
            <b>{label}</b>
          </div>
        );
      })}
    </div>
  );
}

function FormScreen({ form, setForm, errors, sources, roots, serviceError, onBack, onNext }) {
  return (
    <main className="page wizard-page">
      <Stepper current={1} />
      <section className="wizard-card split-card">
        <div className="card-copy">
          <span className="eyebrow">Step one</span>
          <h1>Add VPS details</h1>
          <p>Enter a clear device name and the MT4 account number running on this VPS.</p>
          <div className="privacy-note"><LockKey weight="duotone" /><span><b>Your credentials stay private</b><small>We will never ask for your trading account password.</small></span></div>
        </div>
        <form className="setup-form" onSubmit={(event) => { event.preventDefault(); onNext(); }}>
          <label>Device name <small>For identification only</small>
            <div className={`input-wrap ${errors.name ? "invalid" : ""}`}><DesktopTower /><input autoFocus value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Example: Main London VPS" /></div>
            {errors.name && <span className="error">Enter a device name</span>}
          </label>
          <label>MT4 account number
            <div className={`input-wrap ${errors.account ? "invalid" : ""}`}><MicrosoftExcelLogo /><input inputMode="numeric" value={form.account} onChange={(e) => setForm({ ...form, account: e.target.value.replace(/\D/g, "") })} placeholder="Example: 1024587" /></div>
            {errors.account && <span className="error">Enter the account number</span>}
          </label>
          <label>CSV report file on this VPS
            <div className={`input-wrap path-input ${errors.path ? "invalid" : ""}`}><FolderOpen /><input dir="ltr" list="csv-sources" value={form.path} onChange={(e) => setForm({ ...form, path: e.target.value })} placeholder="Select the detected report file" /><button type="button" disabled={sources.length === 0} onClick={() => sources[0] && setForm({ ...form, path: sources[0].Path })}>Select</button></div>
            <datalist id="csv-sources">{sources.map((source) => <option value={source.Path} key={source.Path}>{source.TerminalId}</option>)}</datalist>
            <span className="field-help"><Info /> {sources.length ? `${sources.length} report file${sources.length === 1 ? " was" : "s were"} found on this VPS.` : "No report file was found. Confirm that MT4 has created it first."}</span>
            {errors.path && <span className="error">Select the CSV file for this account</span>}
          </label>
          <label>OneDrive folder for reports
            <div className={`input-wrap ${errors.oneDriveRoot ? "invalid" : ""}`}><CloudArrowUp /><select dir="ltr" value={form.oneDriveRoot} onChange={(e) => setForm({ ...form, oneDriveRoot: e.target.value })}><option value="">Select a OneDrive folder</option>{roots.map((root) => <option value={root.Path} key={root.Path}>{root.Name || root.Path}</option>)}</select></div>
            <span className="field-help"><ShieldCheck /> Sign in to the dedicated OneDrive uploader account before continuing.</span>
            {errors.oneDriveRoot && <span className="error">Select a OneDrive folder</span>}
          </label>
          {serviceError && <div className="inline-alert error-alert"><Info weight="fill" /><span>{serviceError}</span></div>}
          <div className="form-actions"><button className="text-button" type="button" onClick={onBack}><ArrowLeft /> Back</button><button className="primary" type="submit">Continue to readiness check <ArrowRight weight="bold" /></button></div>
        </form>
      </section>
    </main>
  );
}

const checks = [
  { key: "device", label: "VPS connection", detail: "This VPS is available and ready for setup", Icon: DesktopTower },
  { key: "folder", label: "CSV report file", detail: "The report file was found successfully", Icon: FolderOpen },
  { key: "drive", label: "OneDrive folder", detail: "AmmarTrading is ready to receive files", Icon: CloudArrowUp },
  { key: "security", label: "Secure permissions", detail: "Access is limited to the reporting folder", Icon: ShieldCheck },
];

function CheckScreen({ form, phase, setupError, onStart, onBack }) {
  const activeCount = phase === "checking" ? 2 : phase === "ready" ? 4 : 0;
  return (
    <main className="page wizard-page">
      <Stepper current={2} />
      <section className="wizard-card check-card">
        <div className="check-heading"><span className="eyebrow">Step two</span><h1>{phase === "ready" ? "Everything is ready" : "Checking VPS readiness"}</h1><p>{phase === "ready" ? "Review the details, then complete setup with one click." : "The wizard checks everything automatically. You will not need to open technical settings."}</p></div>
        <div className="device-summary"><span className="device-icon"><DesktopTower weight="duotone" /></span><div><b>{form.name}</b><span>Account {form.account}</span></div><button type="button" onClick={onBack}>Edit</button></div>
        <div className="checks-list">
          {checks.map(({ key, label, detail, Icon }, index) => {
            const done = index < activeCount;
            const loading = phase === "checking" && index === activeCount;
            return <div className={`check-row ${done ? "done" : ""}`} key={key}><span className="check-icon"><Icon weight="duotone" /></span><div><b>{label}</b><small>{done ? detail : loading ? "Checking now..." : "Waiting for check"}</small></div><span className="check-result">{done ? <CheckCircle weight="fill" /> : loading ? <SpinnerGap className="spin" /> : <span />}</span></div>;
          })}
        </div>
        <div className="destination"><FolderOpen weight="duotone" /><div><span>Files will appear on your reporting PC in</span><b dir="ltr">OneDrive / AmmarTrading / {form.account}</b></div></div>
        {setupError && <div className="inline-alert error-alert"><Info weight="fill" /><span>{setupError}</span></div>}
        <div className="form-actions"><button className="text-button" type="button" onClick={onBack} disabled={phase === "checking"}><ArrowLeft /> Back</button><button className="primary" type="button" onClick={onStart} disabled={phase === "checking"}>{phase === "checking" ? <><SpinnerGap className="spin" /> Setting up...</> : phase === "ready" ? <><GearSix weight="fill" /> Set up sync now</> : <>Start check <ArrowRight /></>}</button></div>
      </section>
    </main>
  );
}

function SuccessScreen({ form, result, onDashboard, onAddAnother }) {
  return (
    <main className="page wizard-page success-page">
      <Stepper current={3} />
      <section className="wizard-card success-card">
        <div className="success-badge"><Check weight="bold" /></div>
        <span className="eyebrow">Setup complete</span>
        <h1>Sync is now running</h1>
        <p><b>{form.name}</b> was added and local publishing is active. OneDrive will deliver the files to your reporting PC.</p>
        <div className="success-route">
          <span><DesktopTower weight="duotone" /><b>{form.name}</b></span><div className="route-line"><i /><i /><i /></div><span><CloudArrowUp weight="duotone" /><b>OneDrive</b></span>
        </div>
        <div className="destination success-destination"><FolderOpen weight="duotone" /><div><span>Local file location</span><b dir="ltr">{result?.destination || `OneDrive / AmmarTrading / ${form.account}`}</b></div><CheckCircle weight="fill" /></div>
        <div className="cloud-proof-note"><Info weight="fill" /><span><b>Published locally</b> — cloud delivery is confirmed from the reporting PC after OneDrive finishes syncing.</span></div>
        <div className="success-actions"><button className="primary large" type="button" onClick={onDashboard}>View all devices <ArrowRight /></button><button className="secondary" type="button" onClick={onAddAnother}><Plus /> Add another VPS</button></div>
      </section>
    </main>
  );
}

export function App() {
  const [screen, setScreen] = useState("overview");
  const [form, setForm] = useState(initialForm);
  const [errors, setErrors] = useState({});
  const [phase, setPhase] = useState("idle");
  const [accounts, setAccounts] = useState([]);
  const [sources, setSources] = useState([]);
  const [roots, setRoots] = useState([]);
  const [loading, setLoading] = useState(true);
  const [serviceError, setServiceError] = useState("");
  const [setupError, setSetupError] = useState("");
  const [setupResult, setSetupResult] = useState(null);

  useEffect(() => { window.scrollTo({ top: 0, behavior: "smooth" }); }, [screen]);
  useEffect(() => {
    let cancelled = false;
    const demo = new URLSearchParams(window.location.search).get("demo") === "1";
    if (demo) {
      setAccounts(seedAccounts);
      setSources([{ Path: "C:\\MT4\\MQL4\\Files\\AGOLD___Baskets.csv", TerminalId: "DEMO" }]);
      setRoots([{ Path: "C:\\Users\\Trader\\OneDrive - AmmarTrading", Name: "OneDrive - AmmarTrading" }]);
      setLoading(false);
      return () => { cancelled = true; };
    }
    Promise.all([wizardApi.getDiscovery(), wizardApi.getAccounts()])
      .then(([discovery, accountResponse]) => {
        if (cancelled) return;
        setSources(discovery.sources ?? []);
        setRoots(discovery.oneDriveRoots ?? []);
        setAccounts((accountResponse.accounts ?? []).map(mapApiAccount));
      })
      .catch((error) => { if (!cancelled) setServiceError(error.message); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, []);

  const startAdd = () => {
    setForm({ ...initialForm, path: sources[0]?.Path ?? "", oneDriveRoot: roots[0]?.Path ?? "" });
    setErrors({});
    setSetupError("");
    setSetupResult(null);
    setPhase("idle");
    setScreen("form");
  };
  const validate = () => {
    const nextErrors = { name: !form.name.trim(), account: form.account.length < 4, path: !form.path.trim(), oneDriveRoot: !form.oneDriveRoot.trim() };
    setErrors(nextErrors);
    if (!Object.values(nextErrors).some(Boolean)) { setPhase("ready"); setScreen("check"); }
  };
  const startSetup = async () => {
    if (phase !== "ready") return;
    setPhase("checking");
    setSetupError("");
    try {
      const result = await wizardApi.runSetup({
        vpsName: form.name.trim(),
        expectedMT4Login: form.account,
        sourceCsv: form.path,
        oneDriveRoot: form.oneDriveRoot,
      });
      setSetupResult(result);
      const refreshed = await wizardApi.getAccounts();
      setAccounts((refreshed.accounts ?? []).map(mapApiAccount));
      setScreen("success");
    } catch (error) {
      setSetupError(formatSetupError(error.message));
      setPhase("ready");
    }
  };

  return (
    <div className="app-shell" dir="ltr">
      <Header onHome={() => setScreen("overview")} />
      {loading && <main className="page service-state"><SpinnerGap className="spin" /><h2>Checking this VPS...</h2><p>Looking for MT4 and OneDrive automatically.</p></main>}
      {!loading && serviceError && screen === "overview" && <main className="page service-state error-state"><Info weight="fill" /><h2>Open the wizard from its launcher</h2><p>{serviceError}</p><small>Run Start-MoneyMachineSyncWizard.cmd on the Windows VPS.</small></main>}
      {!loading && !serviceError && screen === "overview" && <EmptyIntro accounts={accounts} onAdd={startAdd} />}
      {!loading && screen === "form" && <FormScreen form={form} setForm={setForm} errors={errors} sources={sources} roots={roots} serviceError={serviceError} onBack={() => setScreen("overview")} onNext={validate} />}
      {!loading && screen === "check" && <CheckScreen form={form} phase={phase} setupError={setupError} onStart={startSetup} onBack={() => { setPhase("idle"); setScreen("form"); }} />}
      {!loading && screen === "success" && <SuccessScreen form={form} result={setupResult} onDashboard={() => setScreen("overview")} onAddAnother={startAdd} />}
      <footer><span>AmmarTrading Sync</span><span><LockKey /> Encrypted and secure connection</span></footer>
    </div>
  );
}
