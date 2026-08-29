import { randomUUID } from "node:crypto";
import { access, cp, mkdir, readFile, readdir, rename, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const requiredDestinationSuffix = path.join(
  "windows",
  "src",
  "AmmarTrading.Sync.App",
  "Assets",
  "Web",
);

const forbiddenLegacyAdapterMarkers = [
  "/api/discovery",
  "/api/accounts",
  "/api/setup",
  "A fetch implementation is required",
];

async function listFiles(root, relativeRoot = "") {
  const files = [];
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const child = path.join(root, entry.name);
    const relativeChild = path.join(relativeRoot, entry.name);
    if (entry.isSymbolicLink()) {
      throw new Error(`Refusing to package a symbolic link: ${relativeChild}`);
    }
    if (entry.isDirectory()) files.push(...await listFiles(child, relativeChild));
    else if (entry.isFile()) files.push(relativeChild);
  }
  return files;
}

function isRelativeLocalAsset(reference) {
  const value = reference.trim();
  if (value.startsWith("data:") || value.startsWith("#")) return true;
  if (!value || value.startsWith("/") || value.startsWith("\\")) return false;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) return false;

  let decoded;
  try {
    decoded = decodeURIComponent(value);
  } catch {
    return false;
  }
  const assetPath = decoded.split(/[?#]/, 1)[0].replaceAll("\\", "/");
  return !assetPath.split("/").includes("..");
}

async function inspectBrowserPackage(root) {
  await access(path.join(root, "index.html"));
  const files = await listFiles(root);
  const index = await readFile(path.join(root, "index.html"), "utf8");
  const assetAttributes = [
    ...index.matchAll(
      /<(script|link)\b[^>]*?\b(?:src|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi,
    ),
  ];
  const scriptSources = assetAttributes.filter((match) => match[1].toLowerCase() === "script");
  if (scriptSources.length === 0 || assetAttributes.some((match) => {
    const reference = match[2] ?? match[3] ?? match[4];
    return !isRelativeLocalAsset(reference);
  })) {
    throw new Error("Packaged index.html may reference only relative local assets.");
  }

  for (const relativeFile of files.filter((file) => path.extname(file).toLowerCase() === ".js")) {
    const javascript = await readFile(path.join(root, relativeFile), "utf8");
    if (forbiddenLegacyAdapterMarkers.some((marker) => javascript.includes(marker))) {
      throw new Error("Refusing to package a browser bundle containing the legacy HTTP test adapter.");
    }
  }

  return files.length;
}

function hasRequiredDestinationSuffix(destination) {
  const normalized = path.normalize(destination);
  return normalized.endsWith(`${path.sep}${requiredDestinationSuffix}`);
}

export async function packageWizard({ source, destination }) {
  const resolvedSource = path.resolve(source);
  const resolvedDestination = path.resolve(destination);
  if (!hasRequiredDestinationSuffix(resolvedDestination)) {
    throw new Error(
      `Refusing to replace a destination outside ${requiredDestinationSuffix}: ${resolvedDestination}`,
    );
  }

  await inspectBrowserPackage(resolvedSource);
  const destinationParent = path.dirname(resolvedDestination);
  const stagingDestination = path.join(
    destinationParent,
    `.Web.package-${process.pid}-${randomUUID()}`,
  );
  await mkdir(destinationParent, { recursive: true });
  try {
    await cp(resolvedSource, stagingDestination, { recursive: true, force: true });
    const files = await inspectBrowserPackage(stagingDestination);
    await rm(resolvedDestination, { recursive: true, force: true });
    await rename(stagingDestination, resolvedDestination);
    return { files, destination };
  } finally {
    await rm(stagingDestination, { recursive: true, force: true });
  }
}

const scriptPath = fileURLToPath(import.meta.url);
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const prototypeRoot = path.resolve(path.dirname(scriptPath), "..");
  const source = path.join(prototypeRoot, "dist", "client");
  const destination = path.resolve(
    prototypeRoot,
    "..",
    "..",
    "windows",
    "src",
    "AmmarTrading.Sync.App",
    "Assets",
    "Web",
  );
  const result = await packageWizard({ source, destination });
  process.stdout.write(`Packaged ${result.files} browser files to ${result.destination}\n`);
}
