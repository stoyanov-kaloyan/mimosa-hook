// Add or edit entries to support more chains.
// Key = hex chainId as returned by MetaMask.

export const NETWORKS = {
  // Ethereum Sepolia
  "0xaa36a7": {
    name: "Sepolia",
    hook: "", // ← fill after deployment
    explorer: "https://sepolia.etherscan.io",
  },
  // Ethereum Mainnet
  "0x1": {
    name: "Ethereum",
    hook: "",
    explorer: "https://etherscan.io",
  },
};

/**
 * Try to load addresses from the deployment manifest (`deployments/mimosa.json`)
 * at build-time via Vite's import.meta.glob, or at runtime from the public dir.
 */
export async function loadManifest() {
  try {
    const res = await fetch("/mimosa.json");
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}
