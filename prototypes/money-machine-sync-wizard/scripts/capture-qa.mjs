import { chromium } from "playwright-core";
import fs from "node:fs/promises";
import path from "node:path";

const browserPath = process.env.QA_BROWSER;
const baseUrl = process.env.QA_URL ?? "http://127.0.0.1:5173/";
const outputDir = path.resolve(process.env.QA_OUTPUT ?? "qa-captures");

if (!browserPath) throw new Error("QA_BROWSER must point to the approved browser executable");

await fs.mkdir(outputDir, { recursive: true });
const browser = await chromium.launch({ executablePath: browserPath, headless: true });
const consoleErrors = [];

async function captureDesktopFlow() {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1024 }, deviceScaleFactor: 1, locale: "ar-EG" });
  const page = await context.newPage();
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => consoleErrors.push(error.message));

  await page.goto(baseUrl, { waitUntil: "networkidle" });
  await page.screenshot({ path: path.join(outputDir, "01-overview-desktop.png") });

  await page.getByRole("button", { name: "إضافة VPS جديد" }).click();
  await page.screenshot({ path: path.join(outputDir, "02-form-desktop.png") });

  await page.getByPlaceholder("مثال: VPS لندن الرئيسي").fill("VPS Dubai 02");
  await page.getByPlaceholder("مثال: 1024587").fill("7788451");
  await page.getByRole("button", { name: "اختيار" }).click();
  await page.getByRole("button", { name: /متابعة للفحص/ }).click();
  await page.screenshot({ path: path.join(outputDir, "03-check-idle-desktop.png") });

  await page.getByRole("button", { name: /ابدأ الفحص/ }).click();
  await page.waitForTimeout(2100);
  await page.screenshot({ path: path.join(outputDir, "04-check-ready-desktop.png") });

  await page.getByRole("button", { name: /إعداد المزامنة الآن/ }).click();
  await page.screenshot({ path: path.join(outputDir, "05-success-desktop.png") });

  await page.getByRole("button", { name: /عرض كل الأجهزة/ }).click();
  await page.screenshot({ path: path.join(outputDir, "06-updated-overview-desktop.png") });
  await context.close();
}

async function captureMobile() {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, locale: "ar-EG" });
  const page = await context.newPage();
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => consoleErrors.push(error.message));
  await page.goto(baseUrl, { waitUntil: "networkidle" });
  await page.screenshot({ path: path.join(outputDir, "07-overview-mobile.png"), fullPage: true });
  await page.getByRole("button", { name: "إضافة VPS جديد" }).click();
  await page.screenshot({ path: path.join(outputDir, "08-form-mobile.png"), fullPage: true });
  await context.close();
}

try {
  await captureDesktopFlow();
  await captureMobile();
  await fs.writeFile(path.join(outputDir, "console-errors.json"), `${JSON.stringify(consoleErrors, null, 2)}\n`);
  process.stdout.write(`${JSON.stringify({ screenshots: 8, consoleErrors }, null, 2)}\n`);
} finally {
  await browser.close();
}
