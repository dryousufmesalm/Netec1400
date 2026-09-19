import assert from "node:assert/strict";
import test from "node:test";
import { createNativeWizardApi, createProductionWizardApi, WizardApiError } from "../src/api.js";

function createFakeWebView() {
  const handlers = new Set();
  return {
    sent: [],
    addEventListener(type, handler) {
      assert.equal(type, "message");
      handlers.add(handler);
    },
    postMessage(message) {
      this.sent.push(message);
    },
    reply(data) {
      for (const handler of handlers) handler({ data });
    },
    get listenerCount() {
      return handlers.size;
    },
  };
}

test("correlates a version-one native request with its reply", async () => {
  const webview = createFakeWebView();
  const api = createNativeWizardApi(webview, { idFactory: () => "req-1", timeoutMs: 50 });

  const pending = api.discoverMt4Accounts();

  assert.deepEqual(webview.sent[0], {
    version: 1,
    id: "req-1",
    command: "discoverMt4Accounts",
    payload: {},
  });
  webview.reply({ version: 1, id: "req-1", ok: true, code: "Success", data: { accounts: [] } });
  assert.deepEqual(await pending, { accounts: [] });
});

test("uses one native listener while correlating concurrent replies", async () => {
  const webview = createFakeWebView();
  let nextId = 0;
  const api = createNativeWizardApi(webview, { idFactory: () => `req-${++nextId}`, timeoutMs: 50 });

  const status = api.getSystemStatus();
  const roots = api.getOneDriveRoots();

  assert.equal(webview.listenerCount, 1);
  webview.reply({ version: 1, id: "req-2", ok: true, code: "Success", data: { roots: ["C:\\OneDrive"] } });
  webview.reply({ version: 1, id: "req-1", ok: true, code: "Success", data: { ready: true } });
  assert.deepEqual(await status, { ready: true });
  assert.deepEqual(await roots, { roots: ["C:\\OneDrive"] });
});

test("maps a native failure reply to WizardApiError", async () => {
  const webview = createFakeWebView();
  const api = createNativeWizardApi(webview, { idFactory: () => "req-1", timeoutMs: 50 });

  const pending = api.applySetup({ accounts: [] });
  webview.reply({ version: 1, id: "req-1", ok: false, code: "InvalidSelection", message: "Choose at least one MT4 account.", data: null });

  await assert.rejects(pending, (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.status, 0);
    assert.equal(error.code, "InvalidSelection");
    assert.equal(error.message, "Choose at least one MT4 account.");
    return true;
  });
});

test("ignores replies for unknown request IDs", async () => {
  const webview = createFakeWebView();
  const api = createNativeWizardApi(webview, { idFactory: () => "req-1", timeoutMs: 50 });

  const pending = api.exportSupportReport();
  webview.reply({ version: 1, id: "other-request", ok: false, code: "RequestFailed", message: "Wrong request" });
  webview.reply({ version: 1, id: "req-1", ok: true, code: "Success", data: { path: "C:\\report.json" } });

  assert.deepEqual(await pending, { path: "C:\\report.json" });
});

test("rejects duplicate generated request IDs without posting a second request", async () => {
  const webview = createFakeWebView();
  const api = createNativeWizardApi(webview, { idFactory: () => "req-1", timeoutMs: 50 });

  const first = api.getSystemStatus();
  await assert.rejects(api.getConfiguredAccounts(), (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.code, "DuplicateRequestId");
    return true;
  });
  assert.equal(webview.sent.length, 1);

  webview.reply({ version: 1, id: "req-1", ok: true, code: "Success", data: {} });
  await first;
});

test("rejects malformed replies for the correlated request", async () => {
  const webview = createFakeWebView();
  const api = createNativeWizardApi(webview, { idFactory: () => "req-1", timeoutMs: 50 });

  const pending = api.browseForCsv();
  webview.reply({ version: 2, id: "req-1", ok: true, code: "Success", data: {} });

  await assert.rejects(pending, (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.code, "InvalidResponse");
    return true;
  });
});

test("rejects timed out requests and clears their timer", async () => {
  const webview = createFakeWebView();
  const api = createNativeWizardApi(webview, { idFactory: () => "req-1", timeoutMs: 5 });

  await assert.rejects(api.runSyncNow({}), (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.code, "RequestTimedOut");
    return true;
  });

  webview.reply({ version: 1, id: "req-1", ok: true, code: "Success", data: {} });
});

test("uses deadlines beyond native execution limits without timing out the user file picker", async (t) => {
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  const scheduled = [];
  const cleared = [];
  globalThis.setTimeout = (callback, delay) => {
    const handle = { callback, delay };
    scheduled.push(handle);
    return handle;
  };
  globalThis.clearTimeout = (handle) => cleared.push(handle);
  t.after(() => {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  });

  const webview = createFakeWebView();
  let nextId = 0;
  const api = createNativeWizardApi(webview, {
    idFactory: () => `deadline-${++nextId}`,
  });
  const cases = [
    ["getSystemStatus", () => api.getSystemStatus(), 60_000],
    ["discoverMt4Accounts", () => api.discoverMt4Accounts(), 60_000],
    ["browseForCsv", () => api.browseForCsv(), null],
    ["getOneDriveRoots", () => api.getOneDriveRoots(), 60_000],
    ["getConfiguredAccounts", () => api.getConfiguredAccounts(), 60_000],
    ["validateSelection", () => api.validateSelection({ accounts: [] }), 150_000],
    ["applySetup", () => api.applySetup({ accounts: [] }), 150_000],
    ["runSyncNow", () => api.runSyncNow({}), 150_000],
    ["openReportingFolder", () => api.openReportingFolder({}), 60_000],
    ["exportSupportReport", () => api.exportSupportReport(), 180_000],
  ];

  for (const [command, invoke, expectedDelay] of cases) {
    const timersBeforeRequest = scheduled.length;
    const pending = invoke();
    const request = webview.sent.at(-1);
    assert.equal(request.command, command);
    if (expectedDelay === null) {
      assert.equal(scheduled.length, timersBeforeRequest, `${command} must not schedule a client deadline`);
    } else {
      assert.equal(scheduled.length, timersBeforeRequest + 1);
      assert.equal(scheduled.at(-1).delay, expectedDelay, `${command} scheduled an unsafe deadline`);
    }

    webview.reply({
      version: 1,
      id: request.id,
      ok: true,
      code: "Success",
      data: {},
    });
    await pending;
  }

  assert.equal(cleared.length, 9);
});

test("production transport selects WebView2 when it is present", async () => {
  const webview = createFakeWebView();
  const api = createProductionWizardApi(webview);

  const pending = api.getSystemStatus();
  assert.deepEqual(webview.sent, [{ version: 1, id: webview.sent[0].id, command: "getSystemStatus", payload: {} }]);
  webview.reply({ version: 1, id: webview.sent[0].id, ok: true, code: "Success", data: { ready: true } });

  assert.deepEqual(await pending, { ready: true });
});

test("production transport rejects a missing WebView2 host even when a demo query is present", async () => {
  const originalWindow = globalThis.window;
  globalThis.window = { location: { search: "?demo=1" } };
  try {
    const api = createProductionWizardApi();
    await assert.rejects(api.getSystemStatus(), (error) => {
      assert.ok(error instanceof WizardApiError);
      assert.equal(error.code, "MissingHost");
      assert.match(error.message, /installed Windows app/i);
      return true;
    });
  } finally {
    if (originalWindow === undefined) delete globalThis.window;
    else globalThis.window = originalWindow;
  }
});

test("uses a fixed safe host error when postMessage throws and clears the pending request", async () => {
  const webview = createFakeWebView();
  let postShouldThrow = true;
  webview.postMessage = (message) => {
    if (postShouldThrow) throw new Error("C:\\Users\\Trader\\secret-path");
    webview.sent.push(message);
  };
  let nextId = 0;
  const api = createNativeWizardApi(webview, { idFactory: () => `req-${++nextId}`, timeoutMs: 50 });

  await assert.rejects(api.getSystemStatus(), (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.code, "HostUnavailable");
    assert.equal(error.message, "The Windows host is unavailable. Close and reopen AmarTrading Sync, then try again.");
    assert.doesNotMatch(error.message, /secret-path/);
    return true;
  });

  postShouldThrow = false;
  const pending = api.getSystemStatus();
  webview.reply({ version: 1, id: "req-2", ok: true, code: "Success", data: { ready: true } });
  assert.deepEqual(await pending, { ready: true });
});
