import assert from "node:assert/strict";
import test from "node:test";
import { createBrowserWizardApi, createProductionWizardApi, WizardApiError } from "../src/api.js";

test("browser transport sends a versioned command envelope and returns data", async () => {
  const calls = [];
  const api = createBrowserWizardApi(async (url, options) => {
    calls.push({ url, options });
    const request = JSON.parse(options.body);
    return new Response(JSON.stringify({
      version: 1,
      id: request.id,
      ok: true,
      code: "Success",
      data: { accounts: [] },
    }), { status: 200, headers: { "content-type": "application/json" } });
  }, { idFactory: () => "browser-request-1" });

  assert.deepEqual(await api.discoverMt4Accounts(), { accounts: [] });
  assert.equal(calls[0].url, "/api/command");
  assert.equal(calls[0].options.method, "POST");
  assert.equal(calls[0].options.credentials, "same-origin");
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    version: 1,
    id: "browser-request-1",
    command: "discoverMt4Accounts",
    payload: {},
  });
});

test("browser transport exposes server errors as WizardApiError", async () => {
  const api = createBrowserWizardApi(async () => new Response(JSON.stringify({
    version: 1,
    id: "browser-request-1",
    ok: false,
    code: "InvalidSelection",
    data: null,
    message: "Choose at least one MT4 account.",
  }), { status: 422, headers: { "content-type": "application/json" } }), {
    idFactory: () => "browser-request-1",
  });

  await assert.rejects(api.applySetup({ accounts: [] }), (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.status, 422);
    assert.equal(error.code, "InvalidSelection");
    assert.equal(error.message, "Choose at least one MT4 account.");
    return true;
  });
});

test("browser transport rejects malformed replies", async () => {
  const api = createBrowserWizardApi(async () => new Response(JSON.stringify({
    version: 1,
    id: "browser-request-1",
    ok: true,
    code: "Success",
  }), { status: 200, headers: { "content-type": "application/json" } }), {
    idFactory: () => "browser-request-1",
  });

  await assert.rejects(api.getSystemStatus(), (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.code, "InvalidResponse");
    return true;
  });
});

test("browser transport normalizes network failures", async () => {
  const api = createBrowserWizardApi(async () => {
    throw new Error("socket closed");
  }, { idFactory: () => "browser-request-1" });

  await assert.rejects(api.getSystemStatus(), (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.code, "HostUnavailable");
    assert.equal(error.message, "The local Windows setup service is unavailable.");
    return true;
  });
});

test("production transport selects the browser bridge on the loopback host", async () => {
  const originalWindow = globalThis.window;
  const calls = [];
  globalThis.window = {
    location: { hostname: "127.0.0.1", port: "8765" },
    fetch: async (url, options) => {
      calls.push({ url, options });
      const request = JSON.parse(options.body);
      return new Response(JSON.stringify({ version: 1, id: request.id, ok: true, code: "Success", data: { ready: true } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  };
  try {
    const api = createProductionWizardApi();
    assert.deepEqual(await api.getSystemStatus(), { ready: true });
    assert.equal(calls[0].url, "/api/command");
  } finally {
    if (originalWindow === undefined) delete globalThis.window;
    else globalThis.window = originalWindow;
  }
});
