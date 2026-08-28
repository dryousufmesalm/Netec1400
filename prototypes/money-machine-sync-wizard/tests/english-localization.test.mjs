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
import { createWizardApi } from "/src/api.js";

const fetchImpl = async (url) => {
  const payload = url.endsWith("/api/setup")
    ? { ok: true, status: "Success", destination: "C:\\\\OneDrive\\\\AmmarTrading\\\\Account_7788451\\\\Baskets.csv" }
    : url.endsWith("/api/discovery")
      ? {
        ok: true,
        sources: [{ Path: "C:\\\\MT4\\\\MQL4\\\\Files\\\\AGOLD___Baskets.csv", TerminalId: "TEST" }],
        oneDriveRoots: [{ Path: "C:\\\\OneDrive - AmmarTrading", Name: "OneDrive - AmmarTrading" }],
      }
      : { ok: true, accounts: [] };
  return new Response(JSON.stringify(payload), { status: 200, headers: { "content-type": "application/json" } });
};

export const wizardApi = createWizardApi(fetchImpl);
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
  await page.getByRole("heading", { name: "All VPS reports in one place" }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Add a new VPS" }).click();
  await page.getByPlaceholder("Example: Main London VPS").fill("VPS Dubai 02");
  await page.getByPlaceholder("Example: 1024587").fill("7788451");
  await page.getByRole("button", { name: "Continue to readiness check" }).click();
    await page.getByRole("heading", { name: "Everything is ready" }).waitFor();
    await page.getByText("OneDrive / AmmarTrading / 7788451", { exact: true }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Set up sync now" }).click();
  await page.getByRole("heading", { name: "Sync is now running" }).waitFor();
  await page.getByText("Published locally").waitFor();
  await assertEnglishScreen();
});
