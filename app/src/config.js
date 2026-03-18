export const ZERO = "0x0000000000000000000000000000000000000000";

export const DEMO_DEFAULTS = {
  originChainId: 11155111,
  reactiveChainId: 5318007,
  poolManager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543",
  callbackProxy: "0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA",
  reactiveRpc: "https://lasna-rpc.rnk.dev/",
};

export const NETWORKS = {
  "0xaa36a7": {
    name: "Sepolia",
    hook: "",
    explorer: "https://sepolia.etherscan.io",
    poolManager: DEMO_DEFAULTS.poolManager,
    callbackProxy: DEMO_DEFAULTS.callbackProxy,
  },
  "0x1": {
    name: "Ethereum",
    hook: "",
    explorer: "https://etherscan.io",
  },
};

export const TOKEN_PRESETS = [
  {
    id: "weth",
    label: "Sepolia WETH",
    address: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
    note: "Useful for demo funding on Sepolia.",
  },
  {
    id: "eth",
    label: "Native ETH",
    address: ZERO,
    note: "Use only for native-currency pools.",
  },
  {
    id: "custom",
    label: "Custom token",
    address: "",
    note: "Paste the exact token used by the pool side you want to spend.",
  },
];

export const POLICY_TEMPLATES = [
  {
    id: "buy-dip",
    label: "Buy the dip",
    summary:
      "Execute when price falls to or below the trigger and swap token1 into token0.",
    triggerPrice: "56022770974786139918731938227",
    triggerDirection: "below",
    zeroForOne: "false",
    amount: "0.10",
    minOutput: "0",
    tip: "0",
    expiryPreset: "1d",
  },
  {
    id: "sell-rally",
    label: "Sell the rally",
    summary:
      "Execute when price rises to or above the trigger and swap token0 into token1.",
    triggerPrice: "112045541949572279837463876454",
    triggerDirection: "above",
    zeroForOne: "true",
    amount: "0.10",
    minOutput: "0",
    tip: "0",
    expiryPreset: "1d",
  },
  {
    id: "keeper-demo",
    label: "Keeper-friendly demo",
    summary:
      "Same as buy-the-dip, but includes a small tip for third-party execution.",
    triggerPrice: "56022770974786139918731938227",
    triggerDirection: "below",
    zeroForOne: "false",
    amount: "0.25",
    minOutput: "0",
    tip: "0.005",
    expiryPreset: "6h",
  },
];

export const EXPIRY_PRESETS = [
  { id: "none", label: "No expiry", seconds: 0 },
  { id: "1h", label: "1 hour", seconds: 60 * 60 },
  { id: "6h", label: "6 hours", seconds: 6 * 60 * 60 },
  { id: "1d", label: "1 day", seconds: 24 * 60 * 60 },
  { id: "custom", label: "Custom unix timestamp", seconds: null },
];

export const QUICK_AMOUNTS = ["0.10", "0.25", "1.00"];

export async function loadManifest() {
  try {
    const res = await fetch("/mimosa.json");
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}
