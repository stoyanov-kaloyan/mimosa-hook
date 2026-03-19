import { ethers } from "ethers";

let provider = null;
let signer = null;
let account = null;
let chainId = null;
let listenersBound = false;

const SEPOLIA_CHAIN_ID = "0xaa36a7";
const SEPOLIA_PARAMS = {
  chainId: SEPOLIA_CHAIN_ID,
  chainName: "Sepolia",
  nativeCurrency: {
    name: "Sepolia ETH",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com"],
  blockExplorerUrls: ["https://sepolia.etherscan.io"],
};

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

export function disconnect() {
  provider = null;
  signer = null;
  account = null;
  chainId = null;
  notify();
}

async function ensureSepolia() {
  const currentChainId = await window.ethereum.request({ method: "eth_chainId" });
  if (currentChainId === SEPOLIA_CHAIN_ID) return currentChainId;

  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: SEPOLIA_CHAIN_ID }],
    });
  } catch (error) {
    if (error?.code !== 4902) {
      throw error;
    }

    await window.ethereum.request({
      method: "wallet_addEthereumChain",
      params: [SEPOLIA_PARAMS],
    });
  }

  return window.ethereum.request({ method: "eth_chainId" });
}

function bindWalletListeners() {
  if (listenersBound) return;

  window.ethereum.on("accountsChanged", async (accs) => {
    account = accs[0] || null;
    if (account && provider) {
      signer = await provider.getSigner();
    } else {
      signer = null;
    }
    notify();
  });

  window.ethereum.on("chainChanged", async (id) => {
    chainId = id;
    provider = new ethers.BrowserProvider(window.ethereum);
    signer = account ? await provider.getSigner() : null;
    notify();
  });

  listenersBound = true;
}

export async function connect() {
  if (!window.ethereum)
    throw new Error("No wallet detected. Install MetaMask.");

  provider = new ethers.BrowserProvider(window.ethereum);
  bindWalletListeners();

  await provider.send("eth_requestAccounts", []);
  chainId = await ensureSepolia();
  const accounts = await provider.send("eth_accounts", []);
  provider = new ethers.BrowserProvider(window.ethereum);
  signer = await provider.getSigner();
  account = accounts[0];

  notify();
  return { account, chainId };
}

export function shortAddr(addr) {
  if (!addr) return "—";
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}
