const BRIDGE_VERSION = 1;
const NATIVE_COMMAND_TIMEOUT_MS = Object.freeze({
  getSystemStatus: 60_000,
  discoverMt4Accounts: 60_000,
  browseForCsv: null,
  browseForOneDriveFolder: null,
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
  "browseForOneDriveFolder",
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
    browseForOneDriveFolder: (payload) => request("browseForOneDriveFolder", payload),
    getOneDriveRoots: () => request("getOneDriveRoots", {}),
    getConfiguredAccounts: () => request("getConfiguredAccounts", {}),
    validateSelection: (payload) => request("validateSelection", payload),
    applySetup: (payload) => request("applySetup", payload),
    runSyncNow: (payload) => request("runSyncNow", payload),
    openReportingFolder: (payload) => request("openReportingFolder", payload),
    exportSupportReport: () => request("exportSupportReport", {}),
  };
}

export function createBrowserWizardApi(fetchImpl, { idFactory = createDefaultId } = {}) {
  if (typeof fetchImpl !== "function") throw new TypeError("A fetch implementation is required");
  if (typeof idFactory !== "function") throw new TypeError("idFactory must be a function");

  async function request(command, payload = {}) {
    const id = idFactory();
    if (typeof id !== "string" || id.length === 0) {
      throw new WizardApiError("The browser request ID is invalid.", { code: "InvalidRequestId" });
    }

    const controller = typeof AbortController === "function" ? new AbortController() : null;
    const commandTimeoutMs = NATIVE_COMMAND_TIMEOUT_MS[command];
    const timeout = controller && commandTimeoutMs !== null && commandTimeoutMs !== undefined
      ? setTimeout(() => controller.abort(), commandTimeoutMs)
      : null;
    let response;
    try {
      response = await fetchImpl("/api/command", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ version: BRIDGE_VERSION, id, command, payload }),
        ...(controller ? { signal: controller.signal } : {}),
      });
    } catch (error) {
      if (error?.name === "AbortError") {
        throw new WizardApiError("The local setup service did not respond in time.", { code: "RequestTimedOut" });
      }
      throw new WizardApiError("The local Windows setup service is unavailable.", { code: "HostUnavailable" });
    } finally {
      if (timeout !== null) clearTimeout(timeout);
    }
    let reply;
    try {
      reply = await response.json();
    } catch {
      throw new WizardApiError("The local setup service returned an unreadable response.", {
        status: response.status,
        code: "InvalidResponse",
      });
    }

    if (reply?.version !== BRIDGE_VERSION || reply?.id !== id || typeof reply?.ok !== "boolean" || typeof reply?.code !== "string" || reply.code.length === 0 || !Object.prototype.hasOwnProperty.call(reply, "data")) {
      throw new WizardApiError("The local setup service returned an invalid response.", {
        status: response.status,
        code: "InvalidResponse",
      });
    }
    if (!response.ok || !reply.ok) {
      throw new WizardApiError(reply.message ?? "The local setup service could not complete that action.", {
        status: response.status,
        code: reply.code,
      });
    }
    return reply.data;
  }

  return {
    getSystemStatus: () => request("getSystemStatus"),
    discoverMt4Accounts: () => request("discoverMt4Accounts"),
    browseForCsv: () => request("browseForCsv"),
    browseForOneDriveFolder: (payload) => request("browseForOneDriveFolder", payload),
    getOneDriveRoots: () => request("getOneDriveRoots"),
    getConfiguredAccounts: () => request("getConfiguredAccounts"),
    validateSelection: (payload) => request("validateSelection", payload),
    applySetup: (payload) => request("applySetup", payload),
    runSyncNow: (payload) => request("runSyncNow", payload),
    openReportingFolder: (payload) => request("openReportingFolder", payload),
    exportSupportReport: () => request("exportSupportReport"),
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

function isLocalBrowserHost() {
  const location = globalThis.window?.location;
  return location && ["127.0.0.1", "localhost", "[::1]"].includes(location.hostname);
}

export function createProductionWizardApi(webview = getBrowserWebView()) {
  if (webview) return createNativeWizardApi(webview);
  if (isLocalBrowserHost() && typeof globalThis.window?.fetch === "function") {
    return createBrowserWizardApi(globalThis.window.fetch.bind(globalThis.window));
  }
  return createMissingHostApi();
}

export const wizardApi = createProductionWizardApi();
