export class WizardApiError extends Error {
  constructor(message, { status = 0, code = "RequestFailed" } = {}) {
    super(message);
    this.name = "WizardApiError";
    this.status = status;
    this.code = code;
  }
}

export function createWizardApi(fetchImpl = globalThis.fetch) {
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

export const wizardApi = createWizardApi();
