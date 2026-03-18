export const ZERO = "0x0000000000000000000000000000000000000000";

export const DEMO_DEFAULTS = {
  originChainId: 11155111,
  reactiveChainId: 5318007,
  poolManager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543",
  callbackProxy: "0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA",
  reactiveRpc: "https://lasna-rpc.rnk.dev/",
  demoToken: "0x5B753e64d1B87fBC350e9adC1758eecf52c32Ae5",
  demoTokenSymbol: "mUSD",
  quoteToken: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14",
  quoteTokenSymbol: "WETH",
  demoPoolId:
    "0xf0e88c3617e824a1f559635edca7b5a68215c4e80d60e15903f144c8c9f2a679",
  demoSqrtPriceX96: "79228162514264337593543950336",
};

export const NETWORKS = {
  "0xaa36a7": {
    name: "Sepolia",
    hook: "0x892D42B22Ac103C682e43b945c81C4572E269000",
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

export const ORDER_PRESETS = [
  {
    id: "buy-dip",
    label: "Buy The Dip",
    summary: "Spend WETH only after the live pool price drops below your selected trigger band.",
    spendToken: DEMO_DEFAULTS.quoteToken,
    spendSymbol: DEMO_DEFAULTS.quoteTokenSymbol,
    receiveSymbol: DEMO_DEFAULTS.demoTokenSymbol,
    triggerAbove: false,
    zeroForOne: false,
  },
  {
    id: "sell-rally",
    label: "Sell The Rally",
    summary: "Spend mUSD only after the live pool price rises above your selected trigger band.",
    spendToken: DEMO_DEFAULTS.demoToken,
    spendSymbol: DEMO_DEFAULTS.demoTokenSymbol,
    receiveSymbol: DEMO_DEFAULTS.quoteTokenSymbol,
    triggerAbove: true,
    zeroForOne: true,
  },
];

export const TRIGGER_PRESETS = [
  {
    id: "5",
    label: "5%",
    bps: 500,
  },
  {
    id: "10",
    label: "10%",
    bps: 1000,
  },
  {
    id: "20",
    label: "20%",
    bps: 2000,
  },
];

export const EXPIRY_PRESETS = [
  { id: "1h", label: "1 hour", seconds: 60 * 60 },
  { id: "6h", label: "6 hours", seconds: 6 * 60 * 60 },
  { id: "1d", label: "1 day", seconds: 24 * 60 * 60 },
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
