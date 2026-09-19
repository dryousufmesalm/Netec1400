import assert from "node:assert/strict";
import test from "node:test";
import {
  automaticOneDriveRoot,
  buildAutomaticSetupPayload,
  configuredAccountsReady,
  duplicateAccountNumbers,
  eligibleAutomaticAccounts,
} from "../src/firstRunSetup.js";

const ready = (number, id = `id-${number}`) => ({
  DiscoveryId: id,
  AccountNumber: number,
  SourceCsv: `C:\\MT4-${number}\\MQL4\\Files\\AGOLD___Baskets.csv`,
  Eligibility: "Ready",
});

test("automatic setup selects every unique ready MT4 account", () => {
  const accounts = [ready("892525830"), ready("892525831")];
  assert.deepEqual(eligibleAutomaticAccounts(accounts).map((account) => account.AccountNumber), ["892525830", "892525831"]);
});

test("automatic setup chooses the only writable OneDrive root", () => {
  assert.equal(automaticOneDriveRoot([{ Path: "C:\\Users\\Trader\\OneDrive" }]), "C:\\Users\\Trader\\OneDrive");
});

test("automatic setup refuses duplicate account sources instead of choosing one", () => {
  const accounts = [ready("892525830"), ready("892525830", "second")];
  assert.deepEqual(duplicateAccountNumbers(accounts), ["892525830"]);
  assert.deepEqual(eligibleAutomaticAccounts(accounts), []);
});

test("automatic setup requires successful local publication and task evidence", () => {
  const base = { AccountNumber: "892525830", LocalPublished: true, TaskState: "Registered", Status: "Success" };
  assert.equal(configuredAccountsReady([base], ["892525830"]), true);
  assert.equal(configuredAccountsReady([{ ...base, Status: "Error" }], ["892525830"]), false);
  assert.equal(configuredAccountsReady([], ["892525830"]), false);
});

test("automatic setup requires a choice when multiple OneDrive roots exist", () => {
  assert.equal(automaticOneDriveRoot([{ Path: "C:\\OneDrive-A" }, { Path: "C:\\OneDrive-B" }]), "");
  assert.equal(automaticOneDriveRoot([{ Path: "C:\\OneDrive-A" }, { Path: "C:\\OneDrive-B" }], "C:\\OneDrive-B"), "C:\\OneDrive-B");
});

test("automatic setup builds the same strict payload as the manual wizard", () => {
  assert.deepEqual(buildAutomaticSetupPayload({
    vpsName: "VPS-01",
    oneDriveRoot: "C:\\Users\\Trader\\OneDrive",
    accounts: [ready("892525830")],
  }), {
    vpsName: "VPS-01",
    oneDriveRoot: "C:\\Users\\Trader\\OneDrive",
    accounts: [{
      discoveryId: "id-892525830",
      expectedMT4Login: "892525830",
      sourceCsv: "C:\\MT4-892525830\\MQL4\\Files\\AGOLD___Baskets.csv",
    }],
  });
});
