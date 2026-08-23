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
  { id: 1, name: "VPS London 01", account: "1024587", files: 18, updated: "منذ دقيقتين" },
  { id: 2, name: "VPS New York", account: "2048651", files: 12, updated: "منذ 5 دقائق" },
  { id: 3, name: "VPS Frankfurt", account: "3097742", files: 9, updated: "منذ 8 دقائق" },
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
    updated: item.localPublished ? "تم النشر محليًا" : item.enabled ? "في انتظار أول نشر" : "متوقف",
    enabled: item.enabled,
  };
}

function formatSetupError(message = "") {
  if (/AccountNumber|ExpectedMT4Login|account number/i.test(message)) {
    return "رقم حساب MT4 لا يطابق رقم الحساب داخل ملف CSV. راجع الرقم وحاول مرة أخرى.";
  }
  if (/OneDrive/i.test(message)) return "مجلد OneDrive غير جاهز. افتح OneDrive وتأكد من تسجيل الدخول ثم حاول مرة أخرى.";
  if (/Source CSV|\.csv|schema/i.test(message)) return "ملف تقارير MT4 غير صالح أو غير جاهز. اختر ملف AGOLD___Baskets.csv الصحيح.";
  if (/ScheduledTask|scheduled task/i.test(message)) return "تم نشر الملف، لكن تعذر تشغيل المزامنة التلقائية. شغّل المعالج كمسؤول أو تواصل مع الدعم.";
  return "لم يكتمل الإعداد. راجع البيانات وحاول مرة أخرى، وإذا استمرت المشكلة تواصل مع الدعم.";
}

function Brand() {
  return (
    <button className="brand" type="button" aria-label="العودة للرئيسية">
      <span className="brand-mark"><CloudArrowUp weight="fill" /></span>
      <span><strong>Money Machine</strong><small>CSV Sync</small></span>
    </button>
  );
}

function Header({ onHome }) {
  return (
    <header className="topbar">
      <div onClick={onHome}><Brand /></div>
      <div className="secure-pill"><ShieldCheck weight="fill" /> اتصال آمن</div>
    </header>
  );
}

function ServerIllustration() {
  return (
    <div className="sync-visual" aria-label="انتقال ملفات CSV من أجهزة VPS إلى OneDrive">
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
        <span>MoneyMachine</span>
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
          <span className="eyebrow"><CloudArrowUp weight="fill" /> مزامنة تلقائية وآمنة</span>
          <h1>كل تقارير الـVPS<br /><em>في مكان واحد</em></h1>
          <p>أضف أي جهاز جديد في دقائق، وستظهر ملفات CSV تلقائيًا داخل OneDrive على جهازك.</p>
          <div className="hero-actions">
            <button className="primary large" type="button" onClick={onAdd}>
              <Plus weight="bold" /> إضافة VPS جديد
            </button>
            <span className="helper"><CheckCircle weight="fill" /> بدون إعدادات تقنية معقدة</span>
          </div>
        </div>
        <ServerIllustration />
      </section>

      <section className="dashboard-section">
        <div className="section-heading">
          <div><h2>الأجهزة المتصلة</h2><p>آخر حالة لمزامنة جميع الحسابات</p></div>
          <button className="secondary" type="button" onClick={onAdd}><Plus weight="bold" /> إضافة جهاز</button>
        </div>
        <div className="stats-row">
          <div className="stat"><HardDrives weight="duotone" /><span><b>{accounts.length}</b> أجهزة متصلة</span></div>
          <div className="stat"><FileCsv weight="duotone" /><span><b>{totalFiles}</b> ملف CSV</span></div>
          <div className="stat"><CheckCircle weight="fill" /><span><b>تعمل</b> كل المزامنات</span></div>
        </div>
        <div className="account-list">
          {accounts.length === 0 && <div className="empty-accounts"><DesktopTower weight="duotone" /><b>لم تتم إضافة أي VPS بعد</b><span>اضغط «إضافة VPS جديد» وسيقوم المعالج بالباقي.</span></div>}
          {accounts.map((item) => (
            <article className="account-row" key={item.id}>
              <div className="account-main"><span className="device-icon"><DesktopTower weight="duotone" /></span><div><h3>{item.name}</h3><p>حساب MT4 رقم {item.account}</p></div></div>
              <div className="file-count"><FileCsv /> {item.files} ملف</div>
              <div className="update-time">آخر مزامنة<br /><b>{item.updated}</b></div>
              <span className={`status ${item.enabled === false ? "paused" : "success"}`}><i /> {item.enabled === false ? "متوقف" : "يعمل"}</span>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}

function Stepper({ current }) {
  const steps = ["بيانات الجهاز", "فحص الجاهزية", "تم الإعداد"];
  return (
    <div className="stepper" aria-label={`الخطوة ${current} من 3`}>
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
          <span className="eyebrow">الخطوة الأولى</span>
          <h1>أضف بيانات الجهاز</h1>
          <p>اكتب اسمًا سهلًا للتعرف عليه، ثم بيانات حساب التداول الموجود على الـVPS.</p>
          <div className="privacy-note"><LockKey weight="duotone" /><span><b>بياناتك آمنة</b><small>لن نطلب كلمة مرور حساب التداول.</small></span></div>
        </div>
        <form className="setup-form" onSubmit={(event) => { event.preventDefault(); onNext(); }}>
          <label>اسم الجهاز <small>للتعرف عليه فقط</small>
            <div className={`input-wrap ${errors.name ? "invalid" : ""}`}><DesktopTower /><input autoFocus value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="مثال: VPS لندن الرئيسي" /></div>
            {errors.name && <span className="error">اكتب اسم الجهاز</span>}
          </label>
          <label>رقم حساب MT4
            <div className={`input-wrap ${errors.account ? "invalid" : ""}`}><MicrosoftExcelLogo /><input inputMode="numeric" value={form.account} onChange={(e) => setForm({ ...form, account: e.target.value.replace(/\D/g, "") })} placeholder="مثال: 1024587" /></div>
            {errors.account && <span className="error">اكتب رقم الحساب</span>}
          </label>
          <label>مجلد ملفات CSV على الجهاز
            <div className={`input-wrap path-input ${errors.path ? "invalid" : ""}`}><FolderOpen /><input dir="ltr" list="csv-sources" value={form.path} onChange={(e) => setForm({ ...form, path: e.target.value })} placeholder="اختر الملف الذي تم اكتشافه" /><button type="button" disabled={sources.length === 0} onClick={() => sources[0] && setForm({ ...form, path: sources[0].Path })}>اختيار</button></div>
            <datalist id="csv-sources">{sources.map((source) => <option value={source.Path} key={source.Path}>{source.TerminalId}</option>)}</datalist>
            <span className="field-help"><Info /> {sources.length ? `تم العثور على ${sources.length} ملف تقارير على هذا الجهاز.` : "لم نعثر على ملف التقارير؛ تأكد أن MT4 أنشأ الملف أولًا."}</span>
            {errors.path && <span className="error">اختر ملف CSV الخاص بالحساب</span>}
          </label>
          <label>مجلد OneDrive المخصص للتقارير
            <div className={`input-wrap ${errors.oneDriveRoot ? "invalid" : ""}`}><CloudArrowUp /><select dir="ltr" value={form.oneDriveRoot} onChange={(e) => setForm({ ...form, oneDriveRoot: e.target.value })}><option value="">اختر مجلد OneDrive</option>{roots.map((root) => <option value={root.Path} key={root.Path}>{root.Name || root.Path}</option>)}</select></div>
            <span className="field-help"><ShieldCheck /> يجب تسجيل الدخول مسبقًا بحساب OneDrive المخصص للرفع.</span>
            {errors.oneDriveRoot && <span className="error">اختر مجلد OneDrive</span>}
          </label>
          {serviceError && <div className="inline-alert error-alert"><Info weight="fill" /><span>{serviceError}</span></div>}
          <div className="form-actions"><button className="text-button" type="button" onClick={onBack}><ArrowRight /> رجوع</button><button className="primary" type="submit">متابعة للفحص <ArrowLeft weight="bold" /></button></div>
        </form>
      </section>
    </main>
  );
}

const checks = [
  { key: "device", label: "الاتصال بالـVPS", detail: "الجهاز متاح وجاهز للإعداد", Icon: DesktopTower },
  { key: "folder", label: "مجلد ملفات CSV", detail: "تم العثور على المجلد بنجاح", Icon: FolderOpen },
  { key: "drive", label: "مجلد OneDrive", detail: "MoneyMachine جاهز لاستقبال الملفات", Icon: CloudArrowUp },
  { key: "security", label: "صلاحيات آمنة", detail: "الوصول محدود لمجلد التقارير فقط", Icon: ShieldCheck },
];

function CheckScreen({ form, phase, setupError, onStart, onBack }) {
  const activeCount = phase === "checking" ? 2 : phase === "ready" ? 4 : 0;
  return (
    <main className="page wizard-page">
      <Stepper current={2} />
      <section className="wizard-card check-card">
        <div className="check-heading"><span className="eyebrow">الخطوة الثانية</span><h1>{phase === "ready" ? "كل شيء جاهز" : "نتأكد من جاهزية الجهاز"}</h1><p>{phase === "ready" ? "راجع البيانات، ثم ابدأ الإعداد بضغطة واحدة." : "سنفحص المطلوب تلقائيًا. لن تحتاج لفتح أي إعدادات تقنية."}</p></div>
        <div className="device-summary"><span className="device-icon"><DesktopTower weight="duotone" /></span><div><b>{form.name}</b><span>حساب {form.account}</span></div><button type="button" onClick={onBack}>تعديل</button></div>
        <div className="checks-list">
          {checks.map(({ key, label, detail, Icon }, index) => {
            const done = index < activeCount;
            const loading = phase === "checking" && index === activeCount;
            return <div className={`check-row ${done ? "done" : ""}`} key={key}><span className="check-icon"><Icon weight="duotone" /></span><div><b>{label}</b><small>{done ? detail : loading ? "جاري الفحص الآن..." : "في انتظار الفحص"}</small></div><span className="check-result">{done ? <CheckCircle weight="fill" /> : loading ? <SpinnerGap className="spin" /> : <span />}</span></div>;
          })}
        </div>
        <div className="destination"><FolderOpen weight="duotone" /><div><span>ستظهر الملفات على جهازك داخل</span><b dir="ltr">OneDrive / MoneyMachine / {form.account}</b></div></div>
        {setupError && <div className="inline-alert error-alert"><Info weight="fill" /><span>{setupError}</span></div>}
        <div className="form-actions"><button className="text-button" type="button" onClick={onBack} disabled={phase === "checking"}><ArrowRight /> رجوع</button><button className="primary" type="button" onClick={onStart} disabled={phase === "checking"}>{phase === "checking" ? <><SpinnerGap className="spin" /> جاري الإعداد...</> : phase === "ready" ? <><GearSix weight="fill" /> إعداد المزامنة الآن</> : <>ابدأ الفحص <ArrowLeft /></>}</button></div>
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
        <span className="eyebrow">تم بنجاح</span>
        <h1>المزامنة تعمل الآن</h1>
        <p>تمت إضافة <b>{form.name}</b> وتشغيل المزامنة المحلية. سيكمل تطبيق OneDrive رفع الملفات إلى جهاز التقارير.</p>
        <div className="success-route">
          <span><DesktopTower weight="duotone" /><b>{form.name}</b></span><div className="route-line"><i /><i /><i /></div><span><CloudArrowUp weight="duotone" /><b>OneDrive</b></span>
        </div>
        <div className="destination success-destination"><FolderOpen weight="duotone" /><div><span>مكان الملف المحلي</span><b dir="ltr">{result?.destination || `OneDrive / MoneyMachine / ${form.account}`}</b></div><CheckCircle weight="fill" /></div>
        <div className="cloud-proof-note"><Info weight="fill" /><span><b>تم النشر محليًا</b> — تأكيد وصوله عبر السحابة يتم من جهاز التقارير بعد اكتمال OneDrive.</span></div>
        <div className="success-actions"><button className="primary large" type="button" onClick={onDashboard}>عرض كل الأجهزة <ArrowLeft /></button><button className="secondary" type="button" onClick={onAddAnother}><Plus /> إضافة VPS آخر</button></div>
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
      setRoots([{ Path: "C:\\Users\\Trader\\OneDrive - Money Machine", Name: "OneDrive - Money Machine" }]);
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
    <div className="app-shell" dir="rtl">
      <Header onHome={() => setScreen("overview")} />
      {loading && <main className="page service-state"><SpinnerGap className="spin" /><h2>جاري فحص الجهاز...</h2><p>نبحث عن MT4 وOneDrive تلقائيًا.</p></main>}
      {!loading && serviceError && screen === "overview" && <main className="page service-state error-state"><Info weight="fill" /><h2>افتح المعالج من ملف التشغيل</h2><p>{serviceError}</p><small>استخدم Start-MoneyMachineSyncWizard.cmd على جهاز Windows.</small></main>}
      {!loading && !serviceError && screen === "overview" && <EmptyIntro accounts={accounts} onAdd={startAdd} />}
      {!loading && screen === "form" && <FormScreen form={form} setForm={setForm} errors={errors} sources={sources} roots={roots} serviceError={serviceError} onBack={() => setScreen("overview")} onNext={validate} />}
      {!loading && screen === "check" && <CheckScreen form={form} phase={phase} setupError={setupError} onStart={startSetup} onBack={() => { setPhase("idle"); setScreen("form"); }} />}
      {!loading && screen === "success" && <SuccessScreen form={form} result={setupResult} onDashboard={() => setScreen("overview")} onAddAnother={startAdd} />}
      <footer><span>Money Machine CSV Sync</span><span><LockKey /> اتصال مشفّر وآمن</span></footer>
    </div>
  );
}
