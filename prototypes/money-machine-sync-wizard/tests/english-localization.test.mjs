import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { createServer } from "vite";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appSource = await readFile(path.join(projectRoot, "src", "App.jsx"), "utf8");
const deployedAppRoot = path.resolve(projectRoot, "..", "..", "automation", "MoneyMachineCsvSync", "WizardApp");
const deployedIndex = await readFile(path.join(deployedAppRoot, "index.html"), "utf8");
const deployedBundleName = deployedIndex.match(/src="(?:\.\/)?assets\/([^"?]+\.js)"/)?.[1];
if (!deployedBundleName) throw new Error("Deployed WizardApp index does not reference a JavaScript bundle.");
const deployedBundle = await readFile(path.join(deployedAppRoot, "assets", deployedBundleName), "utf8");
const deployedLauncher = await readFile(path.join(path.dirname(deployedAppRoot), "Start-MoneyMachineSyncWizard.cmd"), "utf8");
const arabicText = /[\u0600-\u06ff]/;
const testApiModuleId = "\0english-localization-api";
const testApiModule = `
const discoveredAccounts = [
  {
    DiscoveryId: "ready-1", AccountNumber: "7788451", BrokerName: "Ammar Markets",
    TerminalId: "TERMINAL-A", TerminalName: "MetaTrader 4 London",
    SourceCsv: "C:\\\\MT4-A\\\\MQL4\\\\Files\\\\AGOLD___Baskets.csv", SchemaVersion: "3",
    LastWriteUtc: "2026-08-29T09:15:00Z", Freshness: "Fresh", Eligibility: "Ready", ReasonCode: "Ready",
  },
  {
    DiscoveryId: "ready-2", AccountNumber: "9912044", BrokerName: "Northstar Broker",
    TerminalId: "TERMINAL-B", TerminalName: "MetaTrader 4 Frankfurt",
    SourceCsv: "C:\\\\MT4-B\\\\MQL4\\\\Files\\\\AGOLD___Baskets.csv", SchemaVersion: "3",
    LastWriteUtc: "2026-08-29T09:12:00Z", Freshness: "Fresh", Eligibility: "Ready", ReasonCode: "Ready",
  },
  {
    DiscoveryId: "blocked-1", AccountNumber: "4455667", BrokerName: "Legacy Broker",
    TerminalId: "TERMINAL-C", TerminalName: "MetaTrader 4 Legacy",
    SourceCsv: "C:\\\\MT4-C\\\\MQL4\\\\Files\\\\AGOLD___Baskets.csv", SchemaVersion: "2",
    LastWriteUtc: "2026-08-29T08:30:00Z", Freshness: "Stale", Eligibility: "Blocked", ReasonCode: "SchemaV2",
  },
];
let configuredAccounts = [];

export const wizardApi = {
  getSystemStatus: async () => ({ Ready: true, ComputerName: "VPS Dubai 02", Checks: [
    { Name: "Windows and PowerShell", Ready: true, Message: "Compatible Windows tools are available." },
    { Name: "MT4 terminal data", Ready: true, Message: "MT4 report locations can be checked securely." },
    { Name: "OneDrive", Ready: true, Message: "A signed-in OneDrive folder is available." },
    { Name: "Automatic sync", Ready: true, Message: "Windows Scheduled Tasks are available." },
  ] }),
  discoverMt4Accounts: async () => ({ Accounts: discoveredAccounts }),
  browseForCsv: async () => ({ Accounts: discoveredAccounts }),
  getOneDriveRoots: async () => ({ Roots: [{ Path: "C:\\\\OneDrive - AmmarTrading", Name: "OneDrive - AmmarTrading", IsActive: true }] }),
  getConfiguredAccounts: async () => ({ Accounts: configuredAccounts }),
  validateSelection: async (payload) => ({ Stages: [{ Code: "Validated", Status: "Success", Message: payload.accounts.length + " selected sources are valid." }] }),
  applySetup: async (payload) => {
    await new Promise((resolve) => setTimeout(resolve, 250));
    configuredAccounts = payload.accounts.map((account) => ({
      AccountNumber: account.expectedMT4Login,
      BrokerName: discoveredAccounts.find((item) => item.DiscoveryId === account.discoveryId).BrokerName,
      Destination: payload.oneDriveRoot + "\\\\AmarTrading\\\\Account_" + account.expectedMT4Login + "\\\\Baskets.csv",
      LocalPublished: true,
      TaskState: "Registered",
      Status: "Success",
    }));
    return {
      Status: "Success", Accounts: configuredAccounts, CloudDeliveryVerified: false,
      Stages: [
        { Code: "Validated", Status: "Success", Message: "Selected sources are valid." },
        { Code: "LocalPublished", Status: "Success", Message: "Local CSV snapshots were published." },
        { Code: "Automated", Status: "Success", Message: "Automatic sync is active." },
      ],
    };
  },
  runSyncNow: async () => ({ Status: "Success" }),
  openReportingFolder: async () => ({ Status: "Opened" }),
  exportSupportReport: async () => ({ Path: "C:\\\\Support\\\\AmmarTrading-Support.json" }),
};
`;

test("the UI source uses the canonical AmarTrading product and destination names", () => {
  assert.match(appSource, /AmarTrading Sync/);
  assert.doesNotMatch(appSource, /Money Machine|OneDrive \/ AmmarTrading/);
  assert.match(appSource, /default is amartrading/);
  assert.doesNotMatch(appSource, /Start-MoneyMachineSyncWizard\.cmd/);
  assert.match(appSource, /className="setup-live-region" aria-live="polite" aria-atomic="true"/);
});

test("the deployed WizardApp contains only canonical product-facing naming", () => {
  assert.match(deployedIndex, /AmarTrading Sync/);
  assert.match(deployedBundle, /AmarTrading Sync/);
  assert.match(deployedBundle, /OneDrive/);
  assert.doesNotMatch(`${deployedIndex}\n${deployedBundle}`, /Money Machine|AmmarTrading|Start-MoneyMachineSyncWizard\.cmd/);
  assert.match(deployedLauncher, /AmarTrading Sync/);
  assert.doesNotMatch(deployedLauncher, /Money Machine|AmmarTrading/);
});

test("first launch automatically configures ready accounts in English", async (t) => {
  const server = await createServer({
    root: projectRoot,
    logLevel: "silent",
    server: { host: "127.0.0.1", port: 0 },
    plugins: [{
      name: "english-localization-test-api",
      enforce: "pre",
      transform(code, id) {
        if (id.endsWith("/src/App.jsx")) return code.replace('from "./api.js"', 'from "virtual:english-localization-api"');
        return null;
      },
      resolveId(source) {
        return source === "virtual:english-localization-api" ? testApiModuleId : null;
      },
      load(id) {
        return id === testApiModuleId ? testApiModule : null;
      },
    }],
  });
  await server.listen();
  t.after(() => server.close());

  const browser = await chromium.launch({
    executablePath: process.env.QA_BROWSER || "/usr/bin/google-chrome",
    headless: true,
    args: ["--no-sandbox"],
  });
  t.after(() => browser.close());

  const page = await browser.newPage();
  const address = server.httpServer.address();
  await page.goto(`http://127.0.0.1:${address.port}/`, { waitUntil: "networkidle" });
  assert.equal(await page.locator("html").getAttribute("lang"), "en");
  assert.equal(await page.locator("html").getAttribute("dir"), "ltr");
  assert.equal(await page.locator(".app-shell").getAttribute("dir"), "ltr");
  assert.equal(await page.title(), "AmarTrading Sync — Report Sync Setup");
  await page.getByRole("heading", { name: "MT4 account monitoring" }).waitFor();
  assert.equal(await page.getByText("Published locally", { exact: true }).count(), 2);
  assert.doesNotMatch(await page.locator("body").innerText(), arabicText);
});
