import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { packageWizard } from "../scripts/package-windows-wizard.mjs";

test("packages only browser assets and removes stale generated files", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "money-machine-wizard-package-"));
  t.after(async () => { await import("node:fs/promises").then(({ rm }) => rm(root, { recursive: true, force: true })); });
  const client = path.join(root, "dist", "client");
  const server = path.join(root, "dist", "server");
  const destination = path.join(root, "automation", "WizardApp");
  await mkdir(path.join(client, "assets"), { recursive: true });
  await mkdir(server, { recursive: true });
  await mkdir(destination, { recursive: true });
  await writeFile(path.join(client, "index.html"), "<main>packaged</main>");
  await writeFile(path.join(client, "assets", "index-abc.js"), "export default true");
  await writeFile(path.join(server, "index.js"), "must not be copied");
  await writeFile(path.join(destination, "stale.txt"), "remove me");

  const result = await packageWizard({ source: client, destination });

  assert.equal(await readFile(path.join(destination, "index.html"), "utf8"), "<main>packaged</main>");
  assert.equal(await readFile(path.join(destination, "assets", "index-abc.js"), "utf8"), "export default true");
  await assert.rejects(() => readFile(path.join(destination, "stale.txt")), { code: "ENOENT" });
  await assert.rejects(() => readFile(path.join(destination, "index.js")), { code: "ENOENT" });
  assert.deepEqual(result, { files: 2, destination });
});
