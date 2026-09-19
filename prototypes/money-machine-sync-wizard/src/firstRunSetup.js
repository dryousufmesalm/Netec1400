import { accountNumber, defaultDestinationFolder, discoveryId, isAccountEligible, rootPath, sourceCsv } from "./wizardState.js";

export function eligibleAutomaticAccounts(accounts = []) {
  const duplicateNumbers = new Set(duplicateAccountNumbers(accounts));
  const seenNumbers = new Set();
  return accounts.filter((account) => {
    const number = accountNumber(account);
    if (!isAccountEligible(account) || !number || duplicateNumbers.has(number) || seenNumbers.has(number)) return false;
    seenNumbers.add(number);
    return Boolean(discoveryId(account) && sourceCsv(account));
  });
}

export function duplicateAccountNumbers(accounts = []) {
  const counts = new Map();
  for (const account of accounts) {
    const number = accountNumber(account);
    if (number) counts.set(number, (counts.get(number) ?? 0) + 1);
  }
  return [...counts.entries()].filter(([, count]) => count > 1).map(([number]) => number);
}

export function configuredAccountsReady(accounts = [], expectedNumbers = []) {
  const expected = new Set(expectedNumbers.map(String));
  const readyStates = new Set(["registered", "ready", "running", "active", "success"]);
  const ready = accounts.filter((account) => {
    const number = accountNumber(account);
    const status = String(account.Status ?? account.status ?? "").toLowerCase();
    const taskState = String(account.TaskState ?? account.taskState ?? "").toLowerCase();
    const published = account.LocalPublished ?? account.localPublished;
    return expected.has(number) && published === true && status === "success" && readyStates.has(taskState);
  });
  return ready.length === expected.size && expected.size > 0;
}

export function automaticOneDriveRoot(roots = [], existingRoot = "") {
  const normalizedExisting = String(existingRoot ?? "").trim();
  if (normalizedExisting && roots.some((root) => rootPath(root) === normalizedExisting)) return normalizedExisting;
  if (roots.length !== 1) return "";
  return rootPath(roots[0]);
}

export function buildAutomaticSetupPayload({ vpsName, accounts, oneDriveRoot, destinationFolder }) {
  return {
    vpsName: String(vpsName ?? "").trim(),
    oneDriveRoot: String(oneDriveRoot ?? "").trim(),
    destinationFolder: String(destinationFolder ?? defaultDestinationFolder(oneDriveRoot)).trim(),
    accounts: eligibleAutomaticAccounts(accounts).map((account) => ({
      discoveryId: discoveryId(account),
      expectedMT4Login: accountNumber(account),
      sourceCsv: sourceCsv(account),
    })),
  };
}
