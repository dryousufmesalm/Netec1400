import assert from "node:assert/strict";
import test from "node:test";
import { createWizardApi, WizardApiError } from "../src/api.js";

test("the explicitly injected HTTP test adapter uses same-origin credentials", async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify(url.endsWith("discovery")
      ? { ok: true, sources: [{ Path: "C:\\source.csv" }], oneDriveRoots: [{ Path: "C:\\OneDrive" }] }
      : { ok: true, accounts: [] }), { status: 200, headers: { "content-type": "application/json" } });
  };
  const api = createWizardApi(fetchImpl);

  const discovery = await api.getDiscovery();
  const accounts = await api.getAccounts();

  assert.equal(discovery.sources[0].Path, "C:\\source.csv");
  assert.deepEqual(accounts.accounts, []);
  assert.deepEqual(calls.map(({ url, options }) => ({ url, credentials: options.credentials, method: options.method })), [
    { url: "/api/discovery", credentials: "same-origin", method: "GET" },
    { url: "/api/accounts", credentials: "same-origin", method: "GET" },
  ]);
});

test("setup sends the exact backend payload", async () => {
  const calls = [];
  const api = createWizardApi(async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify({ ok: true, status: "Success", destination: "C:\\OneDrive\\AmarTrading\\Account_7788451\\Baskets.csv" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  });
  const request = {
    vpsName: "VPS Dubai 02",
    expectedMT4Login: "7788451",
    sourceCsv: "C:\\MT4\\MQL4\\Files\\AGOLD___Baskets.csv",
    oneDriveRoot: "C:\\OneDrive - Money Machine",
  };

  await api.runSetup(request);

  assert.equal(calls[0].url, "/api/setup");
  assert.equal(calls[0].options.method, "POST");
  assert.equal(calls[0].options.credentials, "same-origin");
  assert.equal(calls[0].options.headers["Content-Type"], "application/json");
  assert.deepEqual(JSON.parse(calls[0].options.body), request);
});

test("non-success responses expose the server message", async () => {
  const api = createWizardApi(async () => new Response(JSON.stringify({ ok: false, code: "RequestFailed", message: "The account number does not match the CSV file" }), {
    status: 422,
    headers: { "content-type": "application/json" },
  }));

  await assert.rejects(() => api.runSetup({}), (error) => {
    assert.ok(error instanceof WizardApiError);
    assert.equal(error.status, 422);
    assert.equal(error.code, "RequestFailed");
    assert.equal(error.message, "The account number does not match the CSV file");
    return true;
  });
});
