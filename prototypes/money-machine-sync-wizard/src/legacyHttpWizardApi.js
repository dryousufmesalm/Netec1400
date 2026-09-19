import { WizardApiError } from "./api.js";

// Opt-in HTTP adapter for Node/browser tests only. Installed AmarTrading Sync
// uses WebView2 and must not ship these routes inside the Windows bundle.
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
