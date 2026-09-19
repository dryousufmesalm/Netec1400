import { chromium } from "playwright-core";
import path from "node:path";
import { pathToFileURL } from "node:url";

const browserPath = process.env.QA_BROWSER;
const projectRoot = path.resolve(process.env.QA_PROJECT ?? ".");
if (!browserPath) throw new Error("QA_BROWSER must point to the approved browser executable");

const browser = await chromium.launch({ executablePath: browserPath, headless: true });
try {
  const context = await browser.newContext({ viewport: { width: 3000, height: 1800 }, deviceScaleFactor: 1 });
  const page = await context.newPage();
  await page.goto(pathToFileURL(path.join(projectRoot, "qa-comparison", "index.html")).href);
  await page.waitForFunction(() => [...document.images].every((image) => image.complete && image.naturalWidth > 0));
  const sections = page.locator("section");
  const names = ["overview", "form", "check"];
  for (let index = 0; index < await sections.count(); index += 1) {
    await sections.nth(index).screenshot({ path: path.join(projectRoot, "qa-comparison", `comparison-${names[index]}.png`) });
  }
  process.stdout.write("three comparison boards captured\n");
  await context.close();
} finally {
  await browser.close();
}
