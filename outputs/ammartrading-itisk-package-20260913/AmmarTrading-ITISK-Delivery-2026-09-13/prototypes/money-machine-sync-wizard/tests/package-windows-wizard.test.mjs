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
  const destination = path.join(root, "windows", "src", "AmmarTrading.Sync.App", "Assets", "Web");
  await mkdir(path.join(client, "assets"), { recursive: true });
  await mkdir(server, { recursive: true });
  await mkdir(destination, { recursive: true });
  await writeFile(
    path.join(client, "index.html"),
    '<main>packaged</main><script type="module" src="./assets/index-abc.js"></script>',
  );
  await writeFile(path.join(client, "assets", "index-abc.js"), "export default true");
  await writeFile(path.join(server, "index.js"), "must not be copied");
  await writeFile(path.join(destination, "stale.txt"), "remove me");

  const result = await packageWizard({ source: client, destination });

  const packagedIndex = await readFile(path.join(destination, "index.html"), "utf8");
  assert.match(packagedIndex, /src="\.\/assets\/index-abc\.js"/);
  assert.doesNotMatch(packagedIndex, /<script\b[^>]*\bsrc=["'](?:https?:)?\/\//i);
  assert.doesNotMatch(packagedIndex, /<(?:script|link)\b[^>]*(?:src|href)=["']\//i);
  assert.equal(await readFile(path.join(destination, "assets", "index-abc.js"), "utf8"), "export default true");
  await assert.rejects(() => readFile(path.join(destination, "stale.txt")), { code: "ENOENT" });
  await assert.rejects(() => readFile(path.join(destination, "index.js")), { code: "ENOENT" });
  assert.deepEqual(result, { files: 2, destination });
});

test("refuses every destination outside the exact normalized Windows Web asset suffix", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "money-machine-wizard-destination-"));
  t.after(async () => { await import("node:fs/promises").then(({ rm }) => rm(root, { recursive: true, force: true })); });
  const source = path.join(root, "source");
  await mkdir(source, { recursive: true });
  await writeFile(path.join(source, "index.html"), '<script type="module" src="./app.js"></script>');
  await writeFile(path.join(source, "app.js"), "export default true");

  const invalidDestinations = [
    path.join(root, "Assets", "Web"),
    path.join(root, "windows", "src", "Other.App", "Assets", "Web"),
    path.join(root, "windows", "src", "AmmarTrading.Sync.App", "Assets", "Web", "nested"),
    path.join(root, "windows", "src", "AmmarTrading.Sync.App", "Assets", "WizardApp"),
  ];

  for (const destination of invalidDestinations) {
    await assert.rejects(
      packageWizard({ source, destination }),
      /Refusing to replace a destination outside windows[\\/]src[\\/]AmmarTrading\.Sync\.App[\\/]Assets[\\/]Web/,
    );
  }
});

test("rejects non-local entry-point assets before replacing a valid package", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "money-machine-wizard-local-assets-"));
  t.after(async () => { await import("node:fs/promises").then(({ rm }) => rm(root, { recursive: true, force: true })); });
  const source = path.join(root, "source");
  const destination = path.join(root, "windows", "src", "AmmarTrading.Sync.App", "Assets", "Web");
  await mkdir(source, { recursive: true });
  await mkdir(destination, { recursive: true });
  await writeFile(path.join(source, "index.html"), '<script src="https://cdn.example.invalid/app.js"></script>');
  await writeFile(path.join(destination, "known-good.txt"), "keep when validation fails");

  await assert.rejects(
    packageWizard({ source, destination }),
    /only relative local assets/,
  );
  assert.equal(await readFile(path.join(destination, "known-good.txt"), "utf8"), "keep when validation fails");
});

test("rejects an unquoted external script URL even when a local module is present", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "money-machine-wizard-unquoted-url-"));
  t.after(async () => { await import("node:fs/promises").then(({ rm }) => rm(root, { recursive: true, force: true })); });
  const source = path.join(root, "source");
  const destination = path.join(root, "windows", "src", "AmmarTrading.Sync.App", "Assets", "Web");
  await mkdir(source, { recursive: true });
  await writeFile(
    path.join(source, "index.html"),
    '<script type="module" src="./app.js"></script><script src=https://cdn.example.invalid/app.js></script>',
  );
  await writeFile(path.join(source, "app.js"), "export default true");

  await assert.rejects(
    packageWizard({ source, destination }),
    /only relative local assets/,
  );
});

test("rejects a browser bundle containing the legacy HTTP test adapter", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "money-machine-wizard-native-only-"));
  t.after(async () => { await import("node:fs/promises").then(({ rm }) => rm(root, { recursive: true, force: true })); });
  const source = path.join(root, "source");
  const destination = path.join(root, "windows", "src", "AmmarTrading.Sync.App", "Assets", "Web");
  await mkdir(source, { recursive: true });
  await mkdir(destination, { recursive: true });
  await writeFile(path.join(source, "index.html"), '<script type="module" src="./app.js"></script>');
  await writeFile(path.join(source, "app.js"), 'fetch("/api/discovery")');
  await writeFile(path.join(destination, "known-good.txt"), "keep when validation fails");

  await assert.rejects(
    packageWizard({ source, destination }),
    /legacy HTTP test adapter/,
  );
  assert.equal(await readFile(path.join(destination, "known-good.txt"), "utf8"), "keep when validation fails");
});
