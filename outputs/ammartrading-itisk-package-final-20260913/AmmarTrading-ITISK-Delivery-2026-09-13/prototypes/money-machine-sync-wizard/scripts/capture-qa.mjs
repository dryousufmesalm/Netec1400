import { chromium } from "playwright-core";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const browserPath = process.env.QA_BROWSER ?? "/usr/bin/google-chrome";
const outputDir = path.resolve(process.env.QA_OUTPUT ?? path.join(projectRoot, "qa-captures"));
const testApiModuleId = "\0capture-qa-api";
const captures = [];
const consoleErrors = [];

const testApiModule = `
const ready = (id, account, broker, terminal, minutes) => ({
  DiscoveryId: id, AccountNumber: account, BrokerName: broker, TerminalId: terminal.toUpperCase().replaceAll(" ", "-"),
  TerminalName: terminal, SourceCsv: "C:\\\\MT4\\\\" + id + "\\\\MQL4\\\\Files\\\\AGOLD___Baskets.csv",
  SchemaVersion: "3", LastWriteUtc: "2026-08-29T09:" + minutes + ":00Z", Freshness: "Fresh", Eligibility: "Ready", ReasonCode: "Ready",
});
const blocked = (id, account, reason, schema, terminal) => ({
  ...ready(id, account, reason === "HeaderOnly" ? "Broker pending" : "Ammar Markets", terminal, "02"),
  SchemaVersion: schema, Freshness: reason === "MalformedCsv" ? "Unknown" : "Stale", Eligibility: "Blocked", ReasonCode: reason,
});
const discoveredAccounts = [
  ready("ready-1", "7788451", "Ammar Markets", "MetaTrader 4 London", "15"),
  ready("ready-2", "9912044", "Northstar Broker", "MetaTrader 4 Frankfurt", "12"),
  blocked("header-1", "", "HeaderOnly", "3", "MetaTrader 4 Dubai"),
  blocked("v2-1", "4455667", "SchemaV2", "2", "MetaTrader 4 Legacy"),
  blocked("bad-1", "Account not identified", "MalformedCsv", "Unknown", "MetaTrader 4 Test"),
  blocked("duplicate-1", "7788451", "DuplicateAccount", "3", "MetaTrader 4 Backup"),
];
let configuredAccounts = [];
const delay = (value, milliseconds = 70) => new Promise((resolve) => setTimeout(() => resolve(value), milliseconds));

export const wizardApi = {
  getSystemStatus: async () => delay({ Ready: true, ComputerName: "VPS Dubai 02", Checks: [
    { Name: "Windows and PowerShell", Ready: true, Message: "Windows tools are compatible and available." },
    { Name: "MT4 terminal data", Ready: true, Message: "MT4 report locations can be checked securely." },
    { Name: "OneDrive", Ready: true, Message: "Two signed-in OneDrive folders were found." },
    { Name: "Automatic sync", Ready: true, Message: "Windows Scheduled Tasks are available." },
  ] }),
  discoverMt4Accounts: async () => delay({ Accounts: discoveredAccounts }),
  browseForCsv: async () => delay({ Accounts: discoveredAccounts }),
  getOneDriveRoots: async () => delay({ Roots: [
    { Path: "C:\\\\Users\\\\Trader\\\\OneDrive - AmmarTrading", Name: "OneDrive - AmmarTrading", IsActive: true },
    { Path: "C:\\\\Users\\\\Trader\\\\OneDrive - Archive", Name: "OneDrive - Archive" },
  ] }),
  getConfiguredAccounts: async () => delay({ Accounts: configuredAccounts }),
  validateSelection: async (payload) => delay({ Stages: [{ Code: "Validated", Status: "Success", Message: payload.accounts.length + " selected schema-v3 sources passed validation." }] }, 140),
  applySetup: async (payload) => {
    configuredAccounts = payload.accounts.map((account) => ({
      AccountNumber: account.expectedMT4Login,
      BrokerName: discoveredAccounts.find((item) => item.DiscoveryId === account.discoveryId).BrokerName,
      Destination: payload.oneDriveRoot + "\\\\AmmarTrading\\\\Account_" + account.expectedMT4Login + "\\\\Baskets.csv",
      LocalPublished: true, TaskState: "Registered",
    }));
    return delay({
      Status: "Success", Accounts: configuredAccounts, CloudDeliveryVerified: false,
      Stages: [
        { Code: "Validated", Status: "Success", Message: "Selected schema-v3 sources passed validation." },
        { Code: "LocalPublished", Status: "Success", Message: "Local CSV snapshots were published and verified." },
        { Code: "Automated", Status: "Success", Message: "Automatic daily and logon sync is active." },
      ],
    }, 180);
  },
  runSyncNow: async () => delay({ Status: "Success" }),
  openReportingFolder: async () => delay({ Status: "Opened" }),
  exportSupportReport: async () => delay({ Path: "C:\\\\Support\\\\AmmarTrading-Support.json" }),
};
`;

const server = await createServer({
  root: projectRoot,
  logLevel: "silent",
  server: { host: "127.0.0.1", port: 0 },
  plugins: [{
    name: "capture-qa-native-api",
    enforce: "pre",
    transform(code, id) {
      if (id.endsWith("/src/App.jsx")) return code.replace('from "./api.js"', 'from "virtual:capture-qa-api"');
      return null;
    },
    resolveId(source) {
      if (source === "virtual:capture-qa-api") return testApiModuleId;
      return null;
    },
    load(id) {
      return id === testApiModuleId ? testApiModule : null;
    },
  }],
});

await fs.mkdir(outputDir, { recursive: true });
await server.listen();
const address = server.httpServer.address();
const baseUrl = `http://127.0.0.1:${address.port}/`;
const browser = await chromium.launch({ executablePath: browserPath, headless: true, args: ["--no-sandbox"] });

async function capture(page, filename, heading) {
  await page.getByRole("heading", { name: heading }).waitFor();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForFunction(() => window.scrollX === 0 && window.scrollY === 0);
  const metrics = await page.evaluate(() => {
    const rect = (selector) => {
      const element = document.querySelector(selector);
      if (!element) return null;
      const bounds = element.getBoundingClientRect();
      return { top: bounds.top, bottom: bounds.bottom, height: bounds.height };
    };
    const topbar = rect(".topbar");
    const page = rect("main.page");
    const footer = rect("footer");
    const headerAction = rect(".header-action");
    const viewportHeight = window.innerHeight;
    const documentHeight = document.documentElement.scrollHeight;
    return {
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      horizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      verticalOverflow: documentHeight > viewportHeight + 1,
      viewportWidth: window.innerWidth,
      viewportHeight,
      documentWidth: document.documentElement.scrollWidth,
      documentHeight,
      topbar,
      page,
      footer,
      topbarVisible: Boolean(topbar && topbar.top >= 0 && topbar.bottom <= viewportHeight),
      pageVerticallyClipped: Boolean(page && (page.top < 0 || page.bottom > viewportHeight)),
      footerVisible: Boolean(footer && footer.top >= 0 && footer.bottom <= viewportHeight),
      headerActionHeight: headerAction?.height ?? null,
      headerActionMeetsMinimum: headerAction === null || headerAction.height >= 44,
      hasArabic: /[\u0600-\u06ff]/.test(document.body.innerText),
      direction: getComputedStyle(document.documentElement).direction,
      language: document.documentElement.lang,
    };
  });
  await page.screenshot({ path: path.join(outputDir, filename) });
  captures.push({ filename, heading, ...metrics });
}

try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, locale: "en-GB" });
  const page = await context.newPage();
  page.on("console", (message) => { if (message.type() === "error") consoleErrors.push(message.text()); });
  page.on("pageerror", (error) => consoleErrors.push(error.message));

  await page.goto(baseUrl, { waitUntil: "networkidle" });
  await capture(page, "01-system-desktop.png", "Check this VPS");

  await page.getByRole("button", { name: "Find MT4 accounts" }).click();
  await page.getByText(/6 MT4 reports found/).waitFor();
  await page.locator(".account-card").filter({ hasText: "7788451" }).first().click();
  await page.locator(".account-card").filter({ hasText: "9912044" }).click();
  await capture(page, "02-accounts-desktop.png", "Select MT4 accounts");

  await page.getByRole("button", { name: "Choose OneDrive" }).click();
  await capture(page, "03-onedrive-desktop.png", "Choose the OneDrive folder");

  await page.getByRole("button", { name: "Test selected accounts" }).click();
  await capture(page, "04-test-desktop.png", "Selections are ready");

  await page.getByRole("button", { name: "Apply setup and run test sync" }).click();
  await capture(page, "05-finish-desktop.png", "Local synchronization is ready");

  await page.getByRole("button", { name: "View Status", exact: true }).click();
  await capture(page, "06-monitor-desktop.png", "MT4 account monitoring");
  await context.close();

  const qaResult = { viewport: "1440x900", screenshots: captures.length, captures, consoleErrors };
  await fs.writeFile(path.join(outputDir, "qa-results.json"), `${JSON.stringify(qaResult, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify(qaResult, null, 2)}\n`);
  if (consoleErrors.length || captures.some((item) => (
    item.scrollX !== 0
    || item.scrollY !== 0
    || item.horizontalOverflow
    || item.verticalOverflow
    || !item.topbarVisible
    || item.pageVerticallyClipped
    || !item.footerVisible
    || !item.headerActionMeetsMinimum
    || item.hasArabic
    || item.direction !== "ltr"
    || item.language !== "en"
  ))) process.exitCode = 1;
} finally {
  await browser.close();
  await server.close();
}
