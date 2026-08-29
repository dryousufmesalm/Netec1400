import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { createServer } from "vite";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

async function openInjectedApp(t, apiModule, testName) {
  const moduleId = `\0${testName}-api`;
  const server = await createServer({
    root: projectRoot,
    logLevel: "silent",
    server: { host: "127.0.0.1", port: 0 },
    plugins: [{
      name: `${testName}-api`,
      enforce: "pre",
      transform(code, id) {
        if (id.endsWith("/src/App.jsx")) return code.replace('from "./api.js"', `from "virtual:${testName}-api"`);
        return null;
      },
      resolveId(source) {
        return source === `virtual:${testName}-api` ? moduleId : null;
      },
      load(id) {
        return id === moduleId ? apiModule : null;
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
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const address = server.httpServer.address();
  await page.goto(`http://127.0.0.1:${address.port}/`, { waitUntil: "networkidle" });
  return page;
}

test("missing native host remains a blocking startup error", async (t) => {
  const page = await openInjectedApp(t, `
    const missing = Object.assign(new Error("AmmarTrading Sync must be opened from the installed Windows app because the WebView2 host is unavailable."), { code: "MissingHost" });
    export const wizardApi = {
      getSystemStatus: async () => { throw missing; },
      getConfiguredAccounts: async () => ({ Accounts: [] }),
    };
  `, "missing-host");

  await page.getByRole("heading", { name: "Check this VPS" }).waitFor();
  await page.getByRole("alert").getByText(/installed Windows app.*WebView2 host is unavailable/i).waitFor();
  await page.getByRole("heading", { name: "This VPS needs attention" }).waitFor();
  assert.equal(await page.locator(".check-item").count(), 0);
  assert.equal(await page.getByRole("button", { name: "Find MT4 accounts" }).isDisabled(), true);
});

test("monitor renders publication, automation, freshness, status, and failure evidence", async (t) => {
  const page = await openInjectedApp(t, `
    export const wizardApi = {
      getSystemStatus: async () => ({ Ready: true, ComputerName: "VPS Monitor", Checks: [{ Name: "Windows", Ready: true, Message: "Ready." }] }),
      getConfiguredAccounts: async () => ({ Accounts: [
        { AccountNumber: "7788451", BrokerName: "Ammar Markets", Destination: "C:\\\\OneDrive\\\\AmmarTrading\\\\Account_7788451\\\\Baskets.csv", LocalPublished: true, TaskState: "Registered", Freshness: "Fresh", Status: "Success" },
        { accountNumber: "9912044", localPublished: false, taskState: "Failed", freshness: "Stale", status: "Error", failureReason: "Scheduled task access was denied." },
        { AccountNumber: "1122334" },
      ] }),
      discoverMt4Accounts: async () => ({ Accounts: [] }),
    };
  `, "monitor-evidence");

  await page.getByRole("heading", { name: "MT4 account monitoring" }).waitFor();
  const rows = page.locator(".result-accounts article");
  assert.equal(await rows.count(), 3);
  await rows.nth(0).getByText("Published locally", { exact: true }).waitFor();
  await rows.nth(0).getByText("Automation Registered", { exact: true }).waitFor();
  await rows.nth(0).getByText("Freshness: Fresh", { exact: true }).waitFor();
  await rows.nth(1).getByText("Not published locally", { exact: true }).waitFor();
  await rows.nth(1).getByText("Automation Failed", { exact: true }).waitFor();
  await rows.nth(1).getByText("Scheduled task access was denied.", { exact: true }).waitFor();
  await rows.nth(2).getByText("Local publication unknown", { exact: true }).waitFor();
  await rows.nth(2).getByText("Automation unknown", { exact: true }).waitFor();
  assert.equal(await page.getByText("Published locally", { exact: true }).count(), 1);

  await page.getByRole("button", { name: "Add MT4 Account", exact: true }).click();
  const headerAction = page.getByRole("button", { name: "View status", exact: true });
  const box = await headerAction.boundingBox();
  assert.ok(box && box.height >= 44, `expected header action height >= 44px, received ${box?.height}`);
});
