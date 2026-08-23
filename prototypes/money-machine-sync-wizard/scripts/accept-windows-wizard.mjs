import { chromium } from "playwright-core";
import fs from "node:fs/promises";
import path from "node:path";

const browserPath = process.env.QA_BROWSER;
const baseUrl = process.env.QA_URL;
const evidenceRoot = path.resolve(process.env.QA_OUTPUT ?? "qa-real");
if (!browserPath || !baseUrl) throw new Error("QA_BROWSER and QA_URL are required");

await fs.mkdir(evidenceRoot, { recursive: true });
const browser = await chromium.launch({ executablePath: browserPath, headless: true });
const consoleErrors = [];
let expectedValidationResponses = 0;

try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1024 }, deviceScaleFactor: 1, locale: "ar-EG" });
  const page = await context.newPage();
  page.on("response", (response) => { if (response.status() === 422 && response.url().endsWith("/api/setup")) expectedValidationResponses += 1; });
  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("status of 422 (Unprocessable Entity)")) consoleErrors.push(message.text());
  });
  page.on("pageerror", (error) => consoleErrors.push(error.message));

  await page.goto(baseUrl, { waitUntil: "networkidle" });
  await page.getByRole("heading", { name: "كل تقارير الـVPS في مكان واحد" }).waitFor();
  await page.screenshot({ path: path.join(evidenceRoot, "01-real-overview-empty.png") });

  await page.getByRole("button", { name: "إضافة VPS جديد" }).click();
  await page.screenshot({ path: path.join(evidenceRoot, "02-real-form.png") });
  const nameInput = page.getByPlaceholder("مثال: VPS لندن الرئيسي");
  const accountInput = page.getByPlaceholder("مثال: 1024587");
  await nameInput.fill("VPS Acceptance 01");
  await accountInput.fill("9999");
  await page.getByRole("button", { name: /متابعة للفحص/ }).click();
  await page.getByRole("heading", { name: "كل شيء جاهز" }).waitFor();
  await page.getByRole("button", { name: /إعداد المزامنة الآن/ }).click();
  await page.getByText(/رقم حساب MT4 لا يطابق رقم الحساب داخل ملف CSV/).waitFor({ timeout: 15000 });
  await page.screenshot({ path: path.join(evidenceRoot, "03-real-account-error.png") });

  await page.getByRole("button", { name: /رجوع/ }).click();
  await accountInput.fill("892522910");
  await page.getByRole("button", { name: /متابعة للفحص/ }).click();
  await page.getByRole("button", { name: /إعداد المزامنة الآن/ }).click();
  await page.getByRole("heading", { name: "المزامنة تعمل الآن" }).waitFor({ timeout: 20000 });
  await page.getByText(/تم النشر محليًا/).waitFor();
  const destinationCard = await page.locator(".success-destination").boundingBox();
  const destinationText = await page.locator(".success-destination b").boundingBox();
  if (!destinationCard || !destinationText || destinationText.x < destinationCard.x || destinationText.x + destinationText.width > destinationCard.x + destinationCard.width) {
    throw new Error("Success destination path must remain inside its card");
  }
  await page.screenshot({ path: path.join(evidenceRoot, "04-real-success.png") });

  await page.getByRole("button", { name: /عرض كل الأجهزة/ }).click();
  await page.getByText("VPS Acceptance 01", { exact: true }).waitFor();
  await page.screenshot({ path: path.join(evidenceRoot, "05-real-updated-overview.png") });
  await context.close();

  const mobileContext = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, locale: "ar-EG" });
  const mobilePage = await mobileContext.newPage();
  mobilePage.on("console", (message) => { if (message.type() === "error") consoleErrors.push(message.text()); });
  mobilePage.on("pageerror", (error) => consoleErrors.push(error.message));
  await mobilePage.goto(baseUrl, { waitUntil: "networkidle" });
  await mobilePage.getByText("VPS Acceptance 01", { exact: true }).waitFor();
  await mobilePage.screenshot({ path: path.join(evidenceRoot, "06-real-overview-mobile.png"), fullPage: true });
  await mobileContext.close();

  if (expectedValidationResponses !== 1) throw new Error(`Expected exactly one rejected account validation, got ${expectedValidationResponses}`);
  await fs.writeFile(path.join(evidenceRoot, "console-errors.json"), `${JSON.stringify(consoleErrors, null, 2)}\n`);
  if (consoleErrors.length) throw new Error(`Browser console errors: ${consoleErrors.join(" | ")}`);
  process.stdout.write(`${JSON.stringify({ status: "Pass", screenshots: 6, consoleErrors: 0 }, null, 2)}\n`);
} finally {
  await browser.close();
}
