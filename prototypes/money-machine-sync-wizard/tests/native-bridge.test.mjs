import assert from "node:assert/strict";
import test from "node:test";
import { createNativeWizardApi, WizardApiError } from "../src/api.js";

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
