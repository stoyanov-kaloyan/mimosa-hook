import { ethers } from "ethers";

let provider = null;
let signer = null;
let account = null;
let chainId = null;

const listeners = new Set();

export function onAccountChange(fn) {
  listeners.add(fn);
}

function notify() {
  listeners.forEach((fn) => fn({ account, chainId, provider, signer }));
}

export function getProvider() {
  return provider;
}
export function getSigner() {
  return signer;
}
export function getAccount() {
  return account;
}
export function getChainId() {
  return chainId;
}

export async function connect() {
  if (!window.ethereum)
    throw new Error("No wallet detected. Install MetaMask.");

  provider = new ethers.BrowserProvider(window.ethereum);
  const accounts = await provider.send("eth_requestAccounts", []);
  signer = await provider.getSigner();
  account = accounts[0];
  chainId = await window.ethereum.request({ method: "eth_chainId" });

  // Listen for changes
  window.ethereum.on("accountsChanged", async (accs) => {
    account = accs[0] || null;
    if (account) signer = await provider.getSigner();
    notify();
  });

  window.ethereum.on("chainChanged", (id) => {
    chainId = id;
    provider = new ethers.BrowserProvider(window.ethereum);
    notify();
  });

  notify();
  return { account, chainId };
}

export function shortAddr(addr) {
  if (!addr) return "—";
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}
