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
const deployedBundleName = deployedIndex.match(/src="\/assets\/([^"?]+\.js)"/)?.[1];
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
    configuredAccounts = payload.accounts.map((account) => ({
      AccountNumber: account.expectedMT4Login,
      BrokerName: discoveredAccounts.find((item) => item.DiscoveryId === account.discoveryId).BrokerName,
      Destination: payload.oneDriveRoot + "\\\\AmmarTrading\\\\Account_" + account.expectedMT4Login + "\\\\Baskets.csv",
      LocalPublished: true,
      TaskState: "Registered",
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

test("the UI source uses the canonical AmmarTrading product and destination names", () => {
  assert.match(appSource, /AmmarTrading Sync/);
  assert.doesNotMatch(appSource, /Money Machine|OneDrive \/ AmarTrading/);
  assert.match(appSource, /OneDrive \/ AmmarTrading/);
  assert.doesNotMatch(appSource, /Start-MoneyMachineSyncWizard\.cmd/);
});

test("the deployed WizardApp contains only canonical product-facing naming", () => {
  assert.match(deployedIndex, /AmmarTrading Sync/);
  assert.match(deployedBundle, /AmmarTrading Sync/);
  assert.match(deployedBundle, /OneDrive \/ AmmarTrading/);
  assert.doesNotMatch(`${deployedIndex}\n${deployedBundle}`, /Money Machine|AmarTrading|Start-MoneyMachineSyncWizard\.cmd/);
  assert.match(deployedLauncher, /AmmarTrading Sync/);
  assert.doesNotMatch(deployedLauncher, /Money Machine|AmarTrading/);
});

test("the complete wizard renders in English from left to right", async (t) => {
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
      resolveId(source, importer) {
        if (source === "virtual:english-localization-api") return testApiModuleId;
        return null;
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

  const assertEnglishScreen = async () => {
    const bodyText = await page.locator("body").innerText();
    assert.doesNotMatch(bodyText, arabicText);
  };

  assert.equal(await page.locator("html").getAttribute("lang"), "en");
  assert.equal(await page.locator("html").getAttribute("dir"), "ltr");
  assert.equal(await page.locator(".app-shell").getAttribute("dir"), "ltr");
  assert.equal(await page.title(), "AmmarTrading Sync — Report Sync Setup");
  await page.getByRole("heading", { name: "Check this VPS" }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Find MT4 accounts" }).click();
  await page.getByRole("heading", { name: "Select MT4 accounts" }).waitFor();
  await page.locator(".account-card").filter({ hasText: "7788451" }).click();
  await page.locator(".account-card").filter({ hasText: "9912044" }).click();
  assert.equal(await page.locator(".account-card.disabled input").isDisabled(), true);
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Choose OneDrive" }).click();
  await page.getByRole("heading", { name: "Choose the OneDrive folder" }).waitFor();
  await page.getByText("OneDrive / AmmarTrading / Account_7788451 / Baskets.csv", { exact: true }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Test selected accounts" }).click();
  await page.getByRole("heading", { name: "Selections are ready" }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Apply setup and run test sync" }).click();
  await page.getByRole("heading", { name: "Local synchronization is ready" }).waitFor();
  assert.equal(await page.getByText("Published locally", { exact: true }).count(), 2);
  await page.getByText("Publication is local only.", { exact: true }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "View Status", exact: true }).click();
  await page.getByRole("heading", { name: "MT4 account monitoring" }).waitFor();
  await assertEnglishScreen();
});
