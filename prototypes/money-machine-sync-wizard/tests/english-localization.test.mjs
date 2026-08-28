import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";
import { createServer } from "vite";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const arabicText = /[\u0600-\u06ff]/;

test("the complete wizard renders in English from left to right", async (t) => {
  const server = await createServer({
    root: projectRoot,
    logLevel: "silent",
    server: { host: "127.0.0.1", port: 0 },
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
  await page.route("**/api/**", async (route) => {
    const pathname = new URL(route.request().url()).pathname;
    const payload = pathname === "/api/setup"
      ? { ok: true, status: "Success", destination: "C:\\OneDrive\\AmarTrading\\Account_7788451\\Baskets.csv" }
      : { ok: true, accounts: [] };
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(payload) });
  });

  const address = server.httpServer.address();
  await page.goto(`http://127.0.0.1:${address.port}/?demo=1`, { waitUntil: "networkidle" });

  const assertEnglishScreen = async () => {
    const bodyText = await page.locator("body").innerText();
    assert.doesNotMatch(bodyText, arabicText);
  };

  assert.equal(await page.locator("html").getAttribute("lang"), "en");
  assert.equal(await page.locator("html").getAttribute("dir"), "ltr");
  assert.equal(await page.locator(".app-shell").getAttribute("dir"), "ltr");
  assert.equal(await page.title(), "Money Machine — Report Sync Setup");
  await page.getByRole("heading", { name: "All VPS reports in one place" }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Add a new VPS" }).click();
  await page.getByPlaceholder("Example: Main London VPS").fill("VPS Dubai 02");
  await page.getByPlaceholder("Example: 1024587").fill("7788451");
  await page.getByRole("button", { name: "Continue to readiness check" }).click();
    await page.getByRole("heading", { name: "Everything is ready" }).waitFor();
    await page.getByText("OneDrive / AmarTrading / 7788451", { exact: true }).waitFor();
  await assertEnglishScreen();

  await page.getByRole("button", { name: "Set up sync now" }).click();
  await page.getByRole("heading", { name: "Sync is now running" }).waitFor();
  await page.getByText("Published locally").waitFor();
  await assertEnglishScreen();
});
