export const screens = Object.freeze({
  SYSTEM: "system",
  ACCOUNTS: "accounts",
  ONEDRIVE: "onedrive",
  TEST: "test",
  FINISH: "finish",
  MONITOR: "monitor",
});

export const initialWizardState = Object.freeze({
  screen: screens.SYSTEM,
  accounts: [],
  selectedDiscoveryIds: [],
  roots: [],
  oneDriveRoot: "",
  vpsName: "",
  systemStatus: null,
  configuredAccounts: [],
  stages: [],
  setupResult: null,
  error: null,
});

const screenValues = new Set(Object.values(screens));

function value(record, camelName, pascalName) {
  return record?.[camelName] ?? record?.[pascalName];
}

export function discoveryId(account) {
  return String(value(account, "discoveryId", "DiscoveryId") ?? "");
}

export function accountNumber(account) {
  return String(value(account, "accountNumber", "AccountNumber") ?? "");
}

export function sourceCsv(account) {
  return String(value(account, "sourceCsv", "SourceCsv") ?? "");
}

export function reasonCode(account) {
  return String(value(account, "reasonCode", "ReasonCode") ?? "Unavailable");
}

export function isAccountEligible(account) {
  return String(value(account, "eligibility", "Eligibility") ?? "").toLowerCase() === "ready";
}

export function rootPath(root) {
  return String(value(root, "path", "Path") ?? root ?? "");
}

function isRecommendedRoot(root) {
  return ["isActive", "IsActive", "isDefault", "IsDefault", "recommended", "Recommended"]
    .some((key) => root?.[key] === true);
}

export function canContinueFromAccounts(state) {
  if (state.selectedDiscoveryIds.length === 0) return false;
  const eligibleIds = new Set(state.accounts.filter(isAccountEligible).map(discoveryId));
  return state.selectedDiscoveryIds.every((id) => eligibleIds.has(id));
}

export function buildSetupPayload(state) {
  const selectedIds = new Set(state.selectedDiscoveryIds);
  return {
    vpsName: state.vpsName.trim(),
    oneDriveRoot: state.oneDriveRoot,
    accounts: state.accounts
      .filter((account) => selectedIds.has(discoveryId(account)))
      .map((account) => ({
        discoveryId: discoveryId(account),
        expectedMT4Login: accountNumber(account),
        sourceCsv: sourceCsv(account),
      })),
  };
}

const stageDefinitions = Object.freeze([
  { id: "validation", label: "Source validation", codes: ["Validated"] },
  { id: "publication", label: "Local OneDrive publication", codes: ["LocalPublished"] },
  { id: "automation", label: "Automatic sync", codes: ["Automated", "TaskRegistrationSkipped"] },
]);

function normalizedStageStatus(stage) {
  const status = String(value(stage, "status", "Status") ?? "pending").toLowerCase();
  if (["success", "error", "running", "pending"].includes(status)) return status;
  return "pending";
}

export function mapSetupStages(stages = []) {
  return stageDefinitions.map((definition) => {
    const stage = stages.find((candidate) => definition.codes.includes(String(value(candidate, "code", "Code") ?? "")));
    return {
      id: definition.id,
      label: definition.label,
      status: stage ? normalizedStageStatus(stage) : "pending",
      message: String(value(stage, "message", "Message") ?? "Waiting to start"),
    };
  });
}

export function reduceWizard(state, action) {
  switch (action.type) {
    case "SCREEN_CHANGED": {
      if (!screenValues.has(action.screen)) throw new Error(`Unknown wizard screen: ${action.screen}`);
      return { ...state, screen: action.screen, error: null };
    }
    case "SYSTEM_LOADED": {
      const status = action.status ?? {};
      const suggestedName = String(value(status, "vpsName", "VpsName")
        ?? value(status, "computerName", "ComputerName")
        ?? "This VPS");
      return {
        ...state,
        systemStatus: status,
        vpsName: state.vpsName || suggestedName,
        error: null,
      };
    }
    case "VPS_NAME_CHANGED":
      return { ...state, vpsName: String(action.vpsName ?? "") };
    case "DISCOVERY_LOADED": {
      const accounts = Array.isArray(action.accounts) ? action.accounts : [];
      const eligibleIds = new Set(accounts.filter(isAccountEligible).map(discoveryId));
      return {
        ...state,
        accounts,
        selectedDiscoveryIds: state.selectedDiscoveryIds.filter((id) => eligibleIds.has(id)),
        error: null,
      };
    }
    case "ACCOUNT_TOGGLED": {
      const account = state.accounts.find((candidate) => discoveryId(candidate) === action.discoveryId);
      if (!account) throw new Error(`Unknown MT4 discovery: ${action.discoveryId}`);
      if (!isAccountEligible(account)) {
        throw new Error(`MT4 account is not eligible: ${reasonCode(account)}`);
      }
      const selected = state.selectedDiscoveryIds.includes(action.discoveryId);
      return {
        ...state,
        selectedDiscoveryIds: selected
          ? state.selectedDiscoveryIds.filter((id) => id !== action.discoveryId)
          : [...state.selectedDiscoveryIds, action.discoveryId],
        error: null,
      };
    }
    case "SELECTION_CLEARED":
      return { ...state, selectedDiscoveryIds: [], stages: [], setupResult: null, error: null };
    case "ROOTS_LOADED": {
      const roots = Array.isArray(action.roots) ? action.roots : [];
      const currentStillExists = roots.some((root) => rootPath(root) === state.oneDriveRoot);
      const recommended = roots.find(isRecommendedRoot) ?? roots[0];
      return {
        ...state,
        roots,
        oneDriveRoot: currentStillExists ? state.oneDriveRoot : rootPath(recommended),
        error: null,
      };
    }
    case "ROOT_SELECTED": {
      const oneDriveRoot = String(action.oneDriveRoot ?? "");
      if (!state.roots.some((root) => rootPath(root) === oneDriveRoot)) {
        throw new Error("Select an available OneDrive folder.");
      }
      return { ...state, oneDriveRoot, error: null };
    }
    case "STAGES_LOADED":
      return { ...state, stages: Array.isArray(action.stages) ? action.stages : [] };
    case "SETUP_COMPLETED":
      return {
        ...state,
        setupResult: action.result ?? null,
        stages: action.result?.stages ?? action.result?.Stages ?? state.stages,
        screen: screens.FINISH,
        error: null,
      };
    case "CONFIGURED_LOADED":
      return { ...state, configuredAccounts: Array.isArray(action.accounts) ? action.accounts : [], error: null };
    case "ERROR_SET":
      return { ...state, error: String(action.error ?? "An unexpected error occurred.") };
    case "ERROR_CLEARED":
      return { ...state, error: null };
    default:
      throw new Error(`Unknown wizard action: ${action.type}`);
  }
}
