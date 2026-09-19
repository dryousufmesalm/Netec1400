import assert from "node:assert/strict";
import test from "node:test";
import {
  buildSetupPayload,
  canContinueFromAccounts,
  configuredAccountView,
  initialWizardState,
  mapSetupStages,
  reduceWizard,
  screens,
} from "../src/wizardState.js";

const readyOne = {
  DiscoveryId: "ready-1",
  AccountNumber: "7788451",
  BrokerName: "Ammar Markets",
  TerminalId: "TERMINAL-A",
  TerminalName: "MetaTrader 4 London",
  SourceCsv: "C:\\MT4-A\\MQL4\\Files\\AGOLD___Baskets.csv",
  SchemaVersion: "3",
  LastWriteUtc: "2026-08-29T09:15:00Z",
  Freshness: "Fresh",
  Eligibility: "Ready",
  ReasonCode: "Ready",
};

const readyTwo = {
  ...readyOne,
  DiscoveryId: "ready-2",
  AccountNumber: "9912044",
  BrokerName: "Northstar Broker",
  TerminalId: "TERMINAL-B",
  TerminalName: "MetaTrader 4 Frankfurt",
  SourceCsv: "C:\\MT4-B\\MQL4\\Files\\AGOLD___Baskets.csv",
};

const blocked = {
  ...readyOne,
  DiscoveryId: "blocked-1",
  AccountNumber: "4455667",
  Eligibility: "Blocked",
  ReasonCode: "SchemaV2",
  SchemaVersion: "2",
};

test("selects multiple eligible discoveries and requires at least one selection", () => {
  const loaded = reduceWizard(initialWizardState, {
    type: "DISCOVERY_LOADED",
    accounts: [readyOne, readyTwo, blocked],
  });

  assert.equal(canContinueFromAccounts(loaded), false);
  const oneSelected = reduceWizard(loaded, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-1" });
  assert.deepEqual(oneSelected.selectedDiscoveryIds, ["ready-1"]);
  assert.equal(canContinueFromAccounts(oneSelected), true);

  const twoSelected = reduceWizard(oneSelected, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-2" });
  assert.deepEqual(twoSelected.selectedDiscoveryIds, ["ready-1", "ready-2"]);
});

test("blocks ineligible and duplicate discoveries from selection", () => {
  const duplicate = { ...blocked, DiscoveryId: "duplicate-1", ReasonCode: "DuplicateAccount" };
  const loaded = reduceWizard(initialWizardState, {
    type: "DISCOVERY_LOADED",
    accounts: [blocked, duplicate],
  });

  assert.throws(
    () => reduceWizard(loaded, { type: "ACCOUNT_TOGGLED", discoveryId: "blocked-1" }),
    /not eligible.*SchemaV2/i,
  );
  assert.throws(
    () => reduceWizard(loaded, { type: "ACCOUNT_TOGGLED", discoveryId: "duplicate-1" }),
    /not eligible.*DuplicateAccount/i,
  );
});

test("refresh preserves only selections that still exist and remain eligible", () => {
  let state = reduceWizard(initialWizardState, {
    type: "DISCOVERY_LOADED",
    accounts: [readyOne, readyTwo],
  });
  state = reduceWizard(state, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-1" });
  state = reduceWizard(state, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-2" });

  const refreshed = reduceWizard(state, {
    type: "DISCOVERY_LOADED",
    accounts: [{ ...readyOne, Freshness: "Stale" }, { ...readyTwo, Eligibility: "Blocked", ReasonCode: "DuplicateAccount" }],
  });

  assert.deepEqual(refreshed.selectedDiscoveryIds, ["ready-1"]);
});

test("OneDrive discovery recommends an active root and keeps a valid explicit choice", () => {
  const roots = [
    { Path: "C:\\OneDrive - Archive", Name: "OneDrive - Archive" },
    { Path: "C:\\OneDrive - AmmarTrading", Name: "OneDrive - AmmarTrading", IsActive: true },
  ];
  const loaded = reduceWizard(initialWizardState, { type: "ROOTS_LOADED", roots });
  assert.equal(loaded.oneDriveRoot, "C:\\OneDrive - AmmarTrading");

  const chosen = reduceWizard(loaded, { type: "ROOT_SELECTED", oneDriveRoot: "C:\\OneDrive - Archive" });
  const refreshed = reduceWizard(chosen, { type: "ROOTS_LOADED", roots: [...roots].reverse() });
  assert.equal(refreshed.oneDriveRoot, "C:\\OneDrive - Archive");
});

test("maps host stage results into stable validation, publication, and automation rows", () => {
  const rows = mapSetupStages([
    { Code: "Validated", Status: "Success", Message: "Two sources are valid." },
    { Code: "LocalPublished", Status: "Success", Message: "Two local snapshots were published." },
    { Code: "Automated", Status: "Error", Message: "Task registration needs attention." },
  ]);

  assert.deepEqual(rows, [
    { id: "validation", label: "Source validation", status: "success", message: "Two sources are valid." },
    { id: "publication", label: "Local OneDrive publication", status: "success", message: "Two local snapshots were published." },
    { id: "automation", label: "Automatic sync", status: "error", message: "Task registration needs attention." },
  ]);
});

test("builds the exact multi-account setup payload from selected discovery records", () => {
  let state = reduceWizard(initialWizardState, {
    type: "DISCOVERY_LOADED",
    accounts: [readyOne, blocked, readyTwo],
  });
  state = reduceWizard(state, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-1" });
  state = reduceWizard(state, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-2" });
  state = reduceWizard(state, { type: "ROOTS_LOADED", roots: [{ Path: "C:\\OneDrive - AmmarTrading" }] });
  state = reduceWizard(state, { type: "VPS_NAME_CHANGED", vpsName: "VPS Dubai 02" });

  assert.deepEqual(buildSetupPayload(state), {
    vpsName: "VPS Dubai 02",
    oneDriveRoot: "C:\\OneDrive - AmmarTrading",
    destinationFolder: "C:\\OneDrive - AmmarTrading\\amartrading",
    accounts: [
      {
        discoveryId: "ready-1",
        expectedMT4Login: "7788451",
        sourceCsv: "C:\\MT4-A\\MQL4\\Files\\AGOLD___Baskets.csv",
      },
      {
        discoveryId: "ready-2",
        expectedMT4Login: "9912044",
        sourceCsv: "C:\\MT4-B\\MQL4\\Files\\AGOLD___Baskets.csv",
      },
    ],
  });
});

test("keeps a selected OneDrive destination folder in the setup payload", () => {
  let state = reduceWizard(initialWizardState, {
    type: "DISCOVERY_LOADED",
    accounts: [readyOne],
  });
  state = reduceWizard(state, { type: "ACCOUNT_TOGGLED", discoveryId: "ready-1" });
  state = reduceWizard(state, { type: "ROOTS_LOADED", roots: [{ Path: "C:\\OneDrive" }] });
  state = reduceWizard(state, { type: "DESTINATION_FOLDER_SELECTED", destinationFolder: "C:\\OneDrive\\Reports" });
  assert.equal(buildSetupPayload(state).destinationFolder, "C:\\OneDrive\\Reports");
});

test("uses stable screen enum values for the five setup screens and monitor", () => {
  assert.deepEqual(screens, {
    SYSTEM: "system",
    ACCOUNTS: "accounts",
    ONEDRIVE: "onedrive",
    TEST: "test",
    FINISH: "finish",
    MONITOR: "monitor",
  });
});

test("configured account loading does not clear a fatal startup error", () => {
  const failed = reduceWizard(initialWizardState, {
    type: "ERROR_SET",
    error: "AmarTrading Sync must be opened from the installed Windows app.",
  });
  const loaded = reduceWizard(failed, { type: "CONFIGURED_LOADED", accounts: [] });

  assert.equal(loaded.error, "AmarTrading Sync must be opened from the installed Windows app.");
  assert.equal(loaded.systemStatus, null);
});

test("normalizes configured account evidence without inventing success", () => {
  assert.deepEqual(configuredAccountView({
    AccountNumber: "7788451",
    BrokerName: "Ammar Markets",
    Destination: "C:\\OneDrive\\AmarTrading\\Account_7788451\\Baskets.csv",
    LocalPublished: true,
    TaskState: "Registered",
    Freshness: "Fresh",
    Status: "Success",
  }), {
    accountNumber: "7788451",
    brokerName: "Ammar Markets",
    destination: "C:\\OneDrive\\AmarTrading\\Account_7788451\\Baskets.csv",
    publication: { tone: "success", label: "Published locally" },
    automation: { tone: "success", label: "Automation Registered" },
    freshness: "Fresh",
    status: "Success",
    failure: "",
  });

  assert.deepEqual(configuredAccountView({
    accountNumber: "9912044",
    localPublished: false,
    taskState: "Failed",
    freshness: "Stale",
    status: "Error",
    failureReason: "Scheduled task access was denied.",
  }), {
    accountNumber: "9912044",
    brokerName: "Broker unknown",
    destination: "Local destination unavailable",
    publication: { tone: "error", label: "Not published locally" },
    automation: { tone: "error", label: "Automation Failed" },
    freshness: "Stale",
    status: "Error",
    failure: "Scheduled task access was denied.",
  });

  assert.deepEqual(configuredAccountView({ AccountNumber: "1122334" }), {
    accountNumber: "1122334",
    brokerName: "Broker unknown",
    destination: "Local destination unavailable",
    publication: { tone: "neutral", label: "Local publication unknown" },
    automation: { tone: "neutral", label: "Automation unknown" },
    freshness: "Freshness unknown",
    status: "Status unknown",
    failure: "",
  });
});
