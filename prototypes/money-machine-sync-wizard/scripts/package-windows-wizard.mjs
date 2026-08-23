import { access, cp, mkdir, readdir, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

async function countFiles(root) {
  let count = 0;
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const child = path.join(root, entry.name);
    if (entry.isDirectory()) count += await countFiles(child);
    else if (entry.isFile()) count += 1;
  }
  return count;
}

export async function packageWizard({ source, destination }) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  if (path.basename(resolvedDestination) !== "WizardApp") {
    throw new Error(`Refusing to replace a destination not named WizardApp: ${resolvedDestination}`);
  }
  await access(path.join(resolvedSource, "index.html"));
  await rm(resolvedDestination, { recursive: true, force: true });
  await mkdir(resolvedDestination, { recursive: true });
  await cp(resolvedSource, resolvedDestination, { recursive: true, force: true });
  const files = await countFiles(resolvedDestination);
  return { files, destination };
}

const scriptPath = fileURLToPath(import.meta.url);
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const prototypeRoot = path.resolve(path.dirname(scriptPath), "..");
  const source = path.join(prototypeRoot, "dist", "client");
  const destination = path.resolve(prototypeRoot, "..", "..", "automation", "MoneyMachineCsvSync", "WizardApp");
  const result = await packageWizard({ source, destination });
  process.stdout.write(`Packaged ${result.files} browser files to ${result.destination}\n`);
}
