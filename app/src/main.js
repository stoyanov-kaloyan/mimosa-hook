import "./style.css";
import { ethers } from "ethers";
import {
  connect,
  onAccountChange,
  shortAddr,
  getAccount,
  getSigner,
  getChainId,
} from "./wallet.js";
import {
  initHook,
  getHookAddress,
  approve,
  deposit,
  withdraw,
  registerPolicy,
  cancelPolicy,
  executePolicy,
  expirePolicy,
  readDeposit,
  fetchUserPolicies,
  readCurrentPrice,
} from "./hook.js";
import { NETWORKS, loadManifest } from "./config.js";

const $ = (s) => document.querySelector(s);
const btnConnect = $("#btn-connect");
const networkBadge = $("#network-badge");
const statusBar = $("#status-bar");
const accountDisplay = $("#account-display");
const hookDisplay = $("#hook-display");

const sectionDeposit = $("#section-deposit");
const sectionRegister = $("#section-register");
const sectionPolicies = $("#section-policies");
const sectionLog = $("#section-log");

const btnApprove = $("#btn-approve");
const btnDeposit = $("#btn-deposit");
const btnWithdraw = $("#btn-withdraw");
const btnRegister = $("#btn-register");
const btnRefresh = $("#btn-refresh");

const depositToken = $("#deposit-token");
const depositAmount = $("#deposit-amount");
const depositBalance = $("#deposit-balance");

const regPool = $("#reg-pool");
const regPrice = $("#reg-price");
const regDirection = $("#reg-direction");
const regZfo = $("#reg-zfo");
const regAmount = $("#reg-amount");
const regMin = $("#reg-min");
const regExpiry = $("#reg-expiry");
const regTip = $("#reg-tip");

const policiesList = $("#policies-list");
const txLog = $("#tx-log");

let hookAddr = null;
let manifest = null;

function toast(msg, error = false) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.toggle("error", error);
  el.classList.remove("hidden");
  el.classList.add("show");
  setTimeout(() => {
    el.classList.remove("show");
  }, 3500);
}

function logTx(msg, txHash = null, error = false) {
  sectionLog.classList.remove("hidden");
  const empty = txLog.querySelector(".empty-state");
  if (empty) empty.remove();

  const div = document.createElement("div");
  div.className = "tx-entry";

  const time = new Date().toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  div.innerHTML = `
    <span class="tx-time">${time}</span>
    <span class="${error ? "tx-err" : "tx-msg"}">${msg}</span>
    ${txHash ? `<a class="tx-hash" href="${explorerTxUrl(txHash)}" target="_blank">${shortAddr(txHash)}</a>` : ""}
  `;
  txLog.prepend(div);
}

function explorerTxUrl(hash) {
  const net = NETWORKS[getChainId()];
  const base = net?.explorer || "https://etherscan.io";
  return `${base}/tx/${hash}`;
}

function parseAmount(value) {
  // Accepts "1.5" → 1500000000000000000 (18 decimals)
  return ethers.parseEther(value);
}

function formatAmount(value) {
  try {
    return ethers.formatEther(value);
  } catch {
    return value.toString();
  }
}

async function withLoading(btn, fn) {
  btn.classList.add("loading");
  btn.disabled = true;
  try {
    return await fn();
  } finally {
    btn.classList.remove("loading");
    btn.disabled = false;
  }
}

async function resolveHookAddress() {
  // 1. Check URL param
  const params = new URLSearchParams(window.location.search);
  if (params.get("hook")) return params.get("hook");

  // 2. Check network config
  const net = NETWORKS[getChainId()];
  if (net?.hook) return net.hook;

  // 3. Try manifest
  if (!manifest) manifest = await loadManifest();
  if (manifest?.origin?.hook) return manifest.origin.hook;

  // 4. Prompt user
  const addr = prompt("Enter MimosaHook address:");
  return addr || null;
}

btnConnect.addEventListener("click", async () => {
  try {
    await withLoading(btnConnect, async () => {
      const { account, chainId } = await connect();
      await onConnected(account, chainId);
    });
  } catch (e) {
    toast(e.message, true);
  }
});

async function onConnected(account, chainId) {
  // Update header
  btnConnect.textContent = shortAddr(account);
  const net = NETWORKS[chainId];
  networkBadge.textContent = net?.name || `Chain ${parseInt(chainId, 16)}`;
  networkBadge.classList.remove("hidden");

  // Resolve hook
  hookAddr = await resolveHookAddress();
  if (!hookAddr) {
    toast("No hook address configured", true);
    return;
  }

  initHook(hookAddr, getSigner());

  // Show sections
  accountDisplay.textContent = shortAddr(account);
  hookDisplay.textContent = shortAddr(hookAddr);
  statusBar.classList.remove("hidden");
  sectionDeposit.classList.remove("hidden");
  sectionRegister.classList.remove("hidden");
  sectionPolicies.classList.remove("hidden");
  sectionLog.classList.remove("hidden");

  // Load initial data
  await refreshBalance();
  await refreshPolicies();

  toast(`Connected to ${net?.name || "chain"}`);
  logTx("Wallet connected");
}

// Listen for account/chain changes
onAccountChange(async ({ account, chainId }) => {
  if (account && hookAddr) {
    await onConnected(account, chainId);
  }
});

async function refreshBalance() {
  const token = depositToken.value.trim();
  if (!token || !getAccount()) return;
  try {
    const currency = token === "0x0" ? ethers.ZeroAddress : token;
    const bal = await readDeposit(getAccount(), currency);
    depositBalance.textContent = formatAmount(bal);
  } catch {
    depositBalance.textContent = "—";
  }
}

depositToken.addEventListener("change", refreshBalance);

btnApprove.addEventListener("click", async () => {
  const token = depositToken.value.trim();
  if (!token || token === "0x0") {
    toast("No approval needed for ETH");
    return;
  }
  try {
    await withLoading(btnApprove, async () => {
      const tx = await approve(token, getSigner());
      logTx("Approve submitted", tx.hash);
      toast("Approval submitted");
      await tx.wait();
      logTx("Approve confirmed", tx.hash);
    });
  } catch (e) {
    toast(e.shortMessage || e.message, true);
    logTx(`Approve failed: ${e.shortMessage || e.message}`, null, true);
  }
});

btnDeposit.addEventListener("click", async () => {
  const token = depositToken.value.trim();
  const amountStr = depositAmount.value.trim();
  if (!token || !amountStr) {
    toast("Fill token + amount", true);
    return;
  }

  try {
    await withLoading(btnDeposit, async () => {
      const currency = token === "0x0" ? ethers.ZeroAddress : token;
      const amount = parseAmount(amountStr);
      const isETH = token === "0x0" || token === ethers.ZeroAddress;
      const tx = await deposit(currency, amount, isETH);
      logTx("Deposit submitted", tx.hash);
      toast("Deposit submitted");
      await tx.wait();
      logTx("Deposit confirmed", tx.hash);
      await refreshBalance();
    });
  } catch (e) {
    toast(e.shortMessage || e.message, true);
    logTx(`Deposit failed: ${e.shortMessage || e.message}`, null, true);
  }
});

btnWithdraw.addEventListener("click", async () => {
  const token = depositToken.value.trim();
  const amountStr = depositAmount.value.trim();
  if (!token || !amountStr) {
    toast("Fill token + amount", true);
    return;
  }

  try {
    await withLoading(btnWithdraw, async () => {
      const currency = token === "0x0" ? ethers.ZeroAddress : token;
      const amount = parseAmount(amountStr);
      const tx = await withdraw(currency, amount);
      logTx("Withdraw submitted", tx.hash);
      toast("Withdraw submitted");
      await tx.wait();
      logTx("Withdraw confirmed", tx.hash);
      await refreshBalance();
    });
  } catch (e) {
    toast(e.shortMessage || e.message, true);
    logTx(`Withdraw failed: ${e.shortMessage || e.message}`, null, true);
  }
});

btnRegister.addEventListener("click", async () => {
  try {
    await withLoading(btnRegister, async () => {
      const poolId = regPool.value.trim();
      const triggerPrice = regPrice.value.trim();
      const triggerAbove = regDirection.value === "above";
      const zeroForOne = regZfo.value === "true";
      const inputAmount = parseAmount(regAmount.value.trim());
      const minOutput =
        regMin.value.trim() === "0" ? 0n : parseAmount(regMin.value.trim());
      const expiry = parseInt(regExpiry.value.trim()) || 0;
      const tip =
        regTip.value.trim() === "0" ? 0n : parseAmount(regTip.value.trim());

      const tx = await registerPolicy(
        poolId,
        triggerPrice,
        triggerAbove,
        zeroForOne,
        inputAmount,
        minOutput,
        expiry,
        tip,
      );
      logTx("Register policy submitted", tx.hash);
      toast("Policy registration submitted");
      const receipt = await tx.wait();
      logTx("Policy registered", tx.hash);
      toast("Policy registered!");
      await refreshBalance();
      await refreshPolicies();
    });
  } catch (e) {
    toast(e.shortMessage || e.message, true);
    logTx(`Register failed: ${e.shortMessage || e.message}`, null, true);
  }
});

async function refreshPolicies() {
  if (!getAccount()) return;

  try {
    const policies = await fetchUserPolicies(getAccount());

    if (policies.length === 0) {
      policiesList.innerHTML = `<p class="empty-state">No policies yet.</p>`;
      return;
    }

    // Sort: active first, then by ID descending
    policies.sort((a, b) => {
      if (a.executed !== b.executed) return a.executed ? 1 : -1;
      return b.id - a.id;
    });

    policiesList.innerHTML = policies.map((p) => renderPolicyCard(p)).join("");

    // Attach button handlers
    policiesList.querySelectorAll("[data-action]").forEach((btn) => {
      btn.addEventListener("click", handlePolicyAction);
    });
  } catch (e) {
    policiesList.innerHTML = `<p class="empty-state">Error loading policies.</p>`;
  }
}

function renderPolicyCard(p) {
  const isActive = !p.executed;
  const expiryStr = p.expiry
    ? new Date(p.expiry * 1000).toLocaleString()
    : "none";

  return `
    <div class="policy-card ${p.executed ? "executed" : ""}">
      <div class="policy-header">
        <span class="policy-id">#${p.id}</span>
        <span class="policy-status ${isActive ? "active" : "executed"}">
          ${isActive ? "active" : "executed"}
        </span>
      </div>
      <dl class="policy-meta">
        <div><dt>Pool</dt><dd>${shortAddr(p.poolId)}</dd></div>
        <div><dt>Trigger</dt><dd>${p.triggerAbove ? "≥" : "≤"} ${truncNum(p.triggerPrice)}</dd></div>
        <div><dt>Direction</dt><dd>${p.zeroForOne ? "token0→1" : "token1→0"}</dd></div>
        <div><dt>Amount</dt><dd>${formatAmount(p.inputAmount)}</dd></div>
        <div><dt>Min output</dt><dd>${formatAmount(p.minOutput)}</dd></div>
        <div><dt>Expiry</dt><dd>${expiryStr}</dd></div>
        <div><dt>Tip</dt><dd>${formatAmount(p.executorTip)}</dd></div>
      </dl>
      ${
        isActive
          ? `
        <div class="policy-actions">
          <button class="btn btn-sm btn-accent" data-action="execute" data-id="${p.id}">Execute</button>
          <button class="btn btn-sm btn-danger" data-action="cancel" data-id="${p.id}">Cancel</button>
          ${p.expiry ? `<button class="btn btn-sm btn-ghost" data-action="expire" data-id="${p.id}">Expire</button>` : ""}
        </div>
      `
          : ""
      }
    </div>
  `;
}

async function handlePolicyAction(e) {
  const btn = e.currentTarget;
  const action = btn.dataset.action;
  const id = parseInt(btn.dataset.id);

  try {
    await withLoading(btn, async () => {
      let tx;
      if (action === "cancel") {
        tx = await cancelPolicy(id);
        logTx(`Cancel #${id} submitted`, tx.hash);
      } else if (action === "execute") {
        tx = await executePolicy(id);
        logTx(`Execute #${id} submitted`, tx.hash);
      } else if (action === "expire") {
        tx = await expirePolicy(id);
        logTx(`Expire #${id} submitted`, tx.hash);
      }

      toast(`${action} submitted`);
      await tx.wait();
      logTx(`${action} #${id} confirmed`, tx.hash);
      toast(`Policy #${id} ${action}d!`);
      await refreshBalance();
      await refreshPolicies();
    });
  } catch (e) {
    toast(e.shortMessage || e.message, true);
    logTx(
      `${action} #${id} failed: ${e.shortMessage || e.message}`,
      null,
      true,
    );
  }
}

btnRefresh.addEventListener("click", refreshPolicies);

function truncNum(n) {
  const s = n.toString();
  if (s.length <= 12) return s;
  return s.slice(0, 8) + "…" + s.slice(-4);
}
