const BRIDGE_VERSION = 1;
const NATIVE_COMMAND_TIMEOUT_MS = Object.freeze({
  getSystemStatus: 60_000,
  discoverMt4Accounts: 60_000,
  browseForCsv: null,
  getOneDriveRoots: 60_000,
  getConfiguredAccounts: 60_000,
  validateSelection: 150_000,
  applySetup: 150_000,
  runSyncNow: 150_000,
  openReportingFolder: 60_000,
  exportSupportReport: 180_000,
});
const HOST_UNAVAILABLE_MESSAGE = "The Windows host is unavailable. Close and reopen AmarTrading Sync, then try again.";
const MISSING_HOST_MESSAGE = "AmarTrading Sync must be opened from the installed Windows app because the WebView2 host is unavailable.";
const nativeCommands = Object.freeze([
  "getSystemStatus",
  "discoverMt4Accounts",
  "browseForCsv",
  "getOneDriveRoots",
  "getConfiguredAccounts",
  "validateSelection",
  "applySetup",
  "runSyncNow",
  "openReportingFolder",
  "exportSupportReport",
]);

export class WizardApiError extends Error {
  constructor(message, { status = 0, code = "RequestFailed" } = {}) {
    super(message);
    this.name = "WizardApiError";
    this.status = status;
    this.code = code;
  }
}

function createDefaultId() {
  if (typeof globalThis.crypto?.randomUUID === "function") return globalThis.crypto.randomUUID();
  return `req-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

function nativeResponseError(message = "The Windows host returned an invalid response.") {
  return new WizardApiError(message, { code: "InvalidResponse" });
}

function isValidNativeReply(reply) {
  return reply
    && typeof reply === "object"
    && reply.version === BRIDGE_VERSION
    && typeof reply.id === "string"
    && typeof reply.ok === "boolean"
    && typeof reply.code === "string"
    && reply.code.length > 0
    && (reply.ok || typeof reply.message === "string");
}

export function createNativeWizardApi(webview, { timeoutMs, idFactory = createDefaultId } = {}) {
  if (!webview || typeof webview.postMessage !== "function" || typeof webview.addEventListener !== "function") {
    throw new TypeError("A WebView2 message bridge is required");
  }
  if (timeoutMs !== undefined && (!Number.isFinite(timeoutMs) || timeoutMs <= 0)) {
    throw new TypeError("timeoutMs must be a positive number");
  }
  if (typeof idFactory !== "function") throw new TypeError("idFactory must be a function");

  const pendingRequests = new Map();

  webview.addEventListener("message", (event) => {
    const reply = event?.data;
    const id = reply?.id;
    if (typeof id !== "string") return;

    const pending = pendingRequests.get(id);
    if (!pending) return;

    pendingRequests.delete(id);
    if (pending.timeout !== null) clearTimeout(pending.timeout);

    if (!isValidNativeReply(reply)) {
      pending.reject(nativeResponseError());
      return;
    }
    if (!reply.ok) {
      pending.reject(new WizardApiError(reply.message, { code: reply.code }));
      return;
    }
    pending.resolve(reply.data);
  });

  function request(command, payload) {
    const id = idFactory();
    if (typeof id !== "string" || id.length === 0) {
      return Promise.reject(new WizardApiError("The Windows host request ID is invalid.", { code: "InvalidRequestId" }));
    }
    if (pendingRequests.has(id)) {
      return Promise.reject(new WizardApiError("The Windows host generated a duplicate request ID.", { code: "DuplicateRequestId" }));
    }

    return new Promise((resolve, reject) => {
      const commandTimeoutMs = timeoutMs ?? NATIVE_COMMAND_TIMEOUT_MS[command];
      const timeout = commandTimeoutMs === null ? null : setTimeout(() => {
        if (!pendingRequests.delete(id)) return;
        reject(new WizardApiError("The Windows host did not respond in time.", { code: "RequestTimedOut" }));
      }, commandTimeoutMs);
      pendingRequests.set(id, { resolve, reject, timeout });

      try {
        webview.postMessage({ version: BRIDGE_VERSION, id, command, payload });
      } catch {
        pendingRequests.delete(id);
        if (timeout !== null) clearTimeout(timeout);
        reject(new WizardApiError(HOST_UNAVAILABLE_MESSAGE, {
          code: "HostUnavailable",
        }));
      }
    });
  }

  return {
    getSystemStatus: () => request("getSystemStatus", {}),
    discoverMt4Accounts: () => request("discoverMt4Accounts", {}),
    browseForCsv: () => request("browseForCsv", {}),
    getOneDriveRoots: () => request("getOneDriveRoots", {}),
    getConfiguredAccounts: () => request("getConfiguredAccounts", {}),
    validateSelection: (payload) => request("validateSelection", payload),
    applySetup: (payload) => request("applySetup", payload),
    runSyncNow: (payload) => request("runSyncNow", payload),
    openReportingFolder: (payload) => request("openReportingFolder", payload),
    exportSupportReport: () => request("exportSupportReport", {}),
  };
}

// This adapter is intentionally opt-in. It supports legacy browser tests only;
// installed AmarTrading Sync uses the WebView2 transport above.
export function createWizardApi(fetchImpl) {
  if (typeof fetchImpl !== "function") throw new TypeError("A fetch implementation is required");

  async function request(path, options = {}) {
    const response = await fetchImpl(path, {
      method: options.method ?? "GET",
      credentials: "same-origin",
      ...(options.body === undefined ? {} : {
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(options.body),
      }),
    });
    let payload;
    try {
      payload = await response.json();
    } catch {
      payload = { ok: false, code: "InvalidResponse", message: "The setup service returned an unreadable response." };
    }
    if (!response.ok || payload?.ok === false) {
      throw new WizardApiError(payload?.message ?? "Could not connect to the setup service.", {
        status: response.status,
        code: payload?.code ?? "RequestFailed",
      });
    }
    return payload;
  }

  return {
    getDiscovery: () => request("/api/discovery"),
    getAccounts: () => request("/api/accounts"),
    runSetup: (setupRequest) => request("/api/setup", { method: "POST", body: setupRequest }),
  };
}

function createMissingHostApi() {
  const reject = () => Promise.reject(new WizardApiError(MISSING_HOST_MESSAGE, { code: "MissingHost" }));
  return Object.fromEntries([...nativeCommands, "getDiscovery", "getAccounts", "runSetup"].map((name) => [name, reject]));
}

function getBrowserWebView() {
  if (typeof window === "undefined") return null;
  const webview = window.chrome?.webview;
  return webview && typeof webview.postMessage === "function" && typeof webview.addEventListener === "function" ? webview : null;
}

export function createProductionWizardApi(webview = getBrowserWebView()) {
  return webview ? createNativeWizardApi(webview) : createMissingHostApi();
}

export const wizardApi = createProductionWizardApi();
