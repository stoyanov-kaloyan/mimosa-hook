import "./style.css";
import { ethers } from "ethers";
import { connect, onAccountChange, shortAddr, getAccount, getSigner, getChainId } from "./wallet.js";
import {
  initHook,
  approve,
  deposit,
  registerPolicy,
  cancelPolicy,
  executePolicy,
  expirePolicy,
  readDeposit,
  readCurrentPrice,
  readPoolInitialized,
  readAllowance,
  readTokenBalance,
  fetchUserPolicies,
} from "./hook.js";
import {
  DEMO_DEFAULTS,
  NETWORKS,
  ORDER_PRESETS,
  TRIGGER_PRESETS,
  EXPIRY_PRESETS,
  QUICK_AMOUNTS,
  loadManifest,
} from "./config.js";

const $ = (s) => document.querySelector(s);

const btnConnect = $("#btn-connect");
const btnApprove = $("#btn-approve");
const btnSubmit = $("#btn-submit");
const btnRefresh = $("#btn-refresh");

const networkBadge = $("#network-badge");
const accountPill = $("#account-pill");
const poolStatus = $("#pool-status");
const livePrice = $("#live-price");
const hookPill = $("#hook-pill");
const amountInput = $("#order-amount");
const amountQuickRow = $("#amount-quick-row");
const expirySelect = $("#expiry-select");
const orderSummary = $("#order-summary");
const depositBalance = $("#deposit-balance");
const allowanceBadge = $("#allowance-badge");
const walletBalance = $("#wallet-balance");
const policiesList = $("#policies-list");
const txLog = $("#tx-log");
const modeButtons = Array.from(document.querySelectorAll("[data-mode]"));
const triggerButtons = Array.from(document.querySelectorAll("[data-trigger]"));

let manifest = null;
let hookAddr = null;
let selectedModeId = ORDER_PRESETS[0].id;
let selectedTriggerBps = TRIGGER_PRESETS[0].bps;
let currentPrice = null;
let poolReady = false;

function getErrorMessage(error) {
  if (error?.code === "CALL_EXCEPTION" && error?.revert?.name) {
    return error.revert.name;
  }
  return (
    error?.shortMessage ||
    error?.revert?.name ||
    error?.reason ||
    error?.info?.error?.message ||
    error?.info?.message ||
    error?.message ||
    "Unknown error"
  );
}

function toast(message, error = false) {
  const el = $("#toast");
  el.textContent = message;
  el.classList.toggle("error", error);
  el.classList.remove("hidden");
  el.classList.add("show");
  setTimeout(() => el.classList.remove("show"), 3200);
}

function explorerTxUrl(hash) {
  const net = NETWORKS[getChainId()];
  return `${net?.explorer || "https://etherscan.io"}/tx/${hash}`;
}

function logTx(message, txHash = null, error = false) {
  const empty = txLog.querySelector(".empty-state");
  if (empty) empty.remove();

  const row = document.createElement("div");
  row.className = "tx-entry";
  row.innerHTML = `
    <span class="tx-copy ${error ? "tx-copy-error" : ""}">${message}</span>
    ${txHash ? `<a class="tx-link" href="${explorerTxUrl(txHash)}" target="_blank" rel="noopener">${shortAddr(txHash)}</a>` : ""}
  `;
  txLog.prepend(row);
}

function parseAmount(value) {
  return ethers.parseEther(value);
}

function formatAmount(value) {
  try {
    return ethers.formatEther(value);
  } catch {
    return value.toString();
  }
}

function truncValue(value) {
  const text = value?.toString() || "—";
  if (text.length <= 18) return text;
  return `${text.slice(0, 10)}…${text.slice(-6)}`;
}

function getMode() {
  return ORDER_PRESETS.find((item) => item.id === selectedModeId) || ORDER_PRESETS[0];
}

function getExpirySeconds() {
  const preset = EXPIRY_PRESETS.find((item) => item.id === expirySelect.value) || EXPIRY_PRESETS[1];
  return preset.seconds;
}

function getTriggerPrice() {
  if (!currentPrice) return null;
  const base = BigInt(currentPrice);
  const delta = (base * BigInt(selectedTriggerBps)) / 10_000n;
  const mode = getMode();
  return mode.triggerAbove ? base + delta : base - delta;
}

function isWrongNetwork() {
  return getChainId() !== "0xaa36a7";
}

async function withLoading(button, fn) {
  button.disabled = true;
  button.classList.add("loading");
  try {
    return await fn();
  } finally {
    button.disabled = false;
    button.classList.remove("loading");
    syncActionState();
  }
}

function renderAmountChips() {
  amountQuickRow.innerHTML = QUICK_AMOUNTS
    .map((value) => `<button class="chip-btn" data-fill="${value}">${value}</button>`)
    .join("");

  amountQuickRow.querySelectorAll("[data-fill]").forEach((button) => {
    button.addEventListener("click", (event) => {
      event.preventDefault();
      amountInput.value = button.dataset.fill;
      renderSummary();
      syncActionState();
    });
  });
}

function renderExpiryOptions() {
  expirySelect.innerHTML = EXPIRY_PRESETS.map((item) => `<option value="${item.id}">${item.label}</option>`).join("");
  expirySelect.value = "1d";
}

function setActiveButtons() {
  modeButtons.forEach((button) => {
    button.classList.toggle("is-active", button.dataset.mode === selectedModeId);
  });
  triggerButtons.forEach((button) => {
    button.classList.toggle("is-active", Number(button.dataset.trigger) === selectedTriggerBps);
  });
}

function renderSummary() {
  const mode = getMode();
  const triggerPrice = getTriggerPrice();
  const amount = amountInput.value.trim() || "0.00";
  const triggerLabel = mode.triggerAbove ? "above" : "below";
  const percent = (selectedTriggerBps / 100).toFixed(0);
  const expiry = EXPIRY_PRESETS.find((item) => item.id === expirySelect.value)?.label || "1 day";

  orderSummary.innerHTML = `
    <div class="summary-line">
      <span>Pool</span>
      <strong>mUSD / WETH on Sepolia</strong>
    </div>
    <div class="summary-line">
      <span>Spend asset</span>
      <strong>${mode.spendSymbol}</strong>
    </div>
    <div class="summary-line">
      <span>Trigger</span>
      <strong>${percent}% ${triggerLabel} live price</strong>
    </div>
    <div class="summary-line">
      <span>Computed trigger</span>
      <strong class="mono">${triggerPrice ? truncValue(triggerPrice) : "Waiting for pool read"}</strong>
    </div>
    <div class="summary-line">
      <span>Amount</span>
      <strong>${amount} ${mode.spendSymbol}</strong>
    </div>
    <div class="summary-line">
      <span>Expiry</span>
      <strong>${expiry}</strong>
    </div>
  `;
}

async function resolveHookAddress() {
  const params = new URLSearchParams(window.location.search);
  const fromQuery = params.get("hook");
  if (fromQuery) return fromQuery;

  const networkHook = NETWORKS[getChainId()]?.hook;
  if (networkHook) return networkHook;

  if (!manifest) manifest = await loadManifest();
  return manifest?.origin?.hook || null;
}

async function refreshPoolState() {
  if (isWrongNetwork()) {
    poolReady = false;
    currentPrice = null;
    poolStatus.textContent = "Switch wallet to Sepolia";
    livePrice.textContent = "—";
    return;
  }

  if (!hookAddr) {
    poolReady = false;
    poolStatus.textContent = "Hook missing";
    livePrice.textContent = "—";
    currentPrice = null;
    return;
  }

  try {
    const initialized = await readPoolInitialized(DEMO_DEFAULTS.demoPoolId);
    poolReady = initialized;
    poolStatus.textContent = initialized ? "Live and ready" : "Pool not registered";
    currentPrice = initialized ? await readCurrentPrice(DEMO_DEFAULTS.demoPoolId) : null;
    livePrice.textContent = currentPrice ? truncValue(currentPrice) : "—";
  } catch (error) {
    poolReady = false;
    currentPrice = null;
    poolStatus.textContent = "Pool read failed";
    livePrice.textContent = "—";
    logTx(`Pool read failed: ${getErrorMessage(error)}`, null, true);
  }

  renderSummary();
}

async function refreshBalances() {
  if (isWrongNetwork()) {
    depositBalance.textContent = "Switch to Sepolia";
    allowanceBadge.textContent = "Switch to Sepolia";
    walletBalance.textContent = "Switch to Sepolia";
    return;
  }

  if (!getAccount() || !hookAddr) {
    depositBalance.textContent = "—";
    allowanceBadge.textContent = "Connect wallet";
    walletBalance.textContent = "—";
    return;
  }

  const mode = getMode();
  try {
    const [hookDeposit, allowance, spendBalance] = await Promise.all([
      readDeposit(getAccount(), mode.spendToken),
      readAllowance(mode.spendToken, getAccount()),
      readTokenBalance(mode.spendToken, getAccount()),
    ]);

    depositBalance.textContent = `${formatAmount(hookDeposit)} ${mode.spendSymbol}`;
    allowanceBadge.textContent = allowance > 0n ? "Approved" : "Approval needed";
    walletBalance.textContent = `${formatAmount(spendBalance)} ${mode.spendSymbol}`;
  } catch (error) {
    depositBalance.textContent = "Read failed";
    allowanceBadge.textContent = "Read failed";
    walletBalance.textContent = "Read failed";
    logTx(`Balance read failed: ${getErrorMessage(error)}`, null, true);
  }
}

function syncActionState() {
  const hasWallet = Boolean(getAccount());
  const validAmount = Boolean(amountInput.value.trim()) && Number(amountInput.value.trim()) > 0;
  const ready = hasWallet && poolReady && !isWrongNetwork() && validAmount;

  btnApprove.disabled = !hasWallet || isWrongNetwork();
  btnSubmit.disabled = !ready;
}

function isPolicyExpired(policy) {
  return Boolean(policy.expiry) && Math.floor(Date.now() / 1000) > policy.expiry;
}

function isTriggerMet(policy) {
  if (!currentPrice) return false;

  const live = BigInt(currentPrice);
  const trigger = BigInt(policy.triggerPrice);
  return policy.triggerAbove ? live >= trigger : live <= trigger;
}

function renderPolicyCard(policy) {
  const mode = policy.zeroForOne ? "Sell rally" : "Buy dip";
  const expired = isPolicyExpired(policy);
  const triggerMet = isTriggerMet(policy);
  const status = policy.terminalState === "executed"
    ? "Executed"
    : policy.terminalState === "cancelled"
      ? "Cancelled"
      : policy.terminalState === "expired"
        ? "Expired"
    : policy.executed
      ? "Closed"
    : expired
      ? "Expired"
      : triggerMet
        ? "Ready"
        : "Watching";
  const expiry = policy.expiry ? new Date(policy.expiry * 1000).toLocaleString() : "None";
  const actionMarkup = policy.executed || policy.terminalState !== "active"
    ? ""
    : expired
      ? `<div class="policy-actions">
          <button class="btn btn-accent btn-small" data-action="expire" data-id="${policy.id}">Expire</button>
        </div>`
      : triggerMet
        ? `<div class="policy-actions">
            <button class="btn btn-accent btn-small" data-action="execute" data-id="${policy.id}">Execute</button>
            <button class="btn btn-ghost btn-small" data-action="cancel" data-id="${policy.id}">Cancel</button>
          </div>`
        : `<div class="policy-actions">
            <button class="btn btn-ghost btn-small" data-action="cancel" data-id="${policy.id}">Cancel</button>
          </div>`;

  return `
    <article class="policy-card ${policy.executed || policy.terminalState !== "active" ? "is-done" : ""}">
      <div class="policy-head">
        <strong>#${policy.id} ${mode}</strong>
        <span>${status}</span>
      </div>
      <div class="policy-grid">
        <span>Trigger <strong class="mono">${truncValue(policy.triggerPrice)}</strong></span>
        <span>Input <strong>${formatAmount(policy.inputAmount)}</strong></span>
        <span>Expiry <strong>${expiry}</strong></span>
      </div>
      ${actionMarkup}
    </article>
  `;
}

async function refreshPolicies() {
  if (isWrongNetwork()) {
    policiesList.innerHTML = `<p class="empty-state">Switch your wallet to Sepolia to view demo orders.</p>`;
    return;
  }

  if (!getAccount() || !hookAddr) {
    policiesList.innerHTML = `<p class="empty-state">Connect a wallet to see demo orders.</p>`;
    return;
  }

  try {
    const policies = await fetchUserPolicies(getAccount());
    if (!policies.length) {
      policiesList.innerHTML = `<p class="empty-state">No demo orders yet.</p>`;
      return;
    }

    policies.sort((a, b) => b.id - a.id);
    policiesList.innerHTML = policies.map(renderPolicyCard).join("");

    policiesList.querySelectorAll("[data-action]").forEach((button) => {
      button.addEventListener("click", handlePolicyAction);
    });
  } catch (error) {
    policiesList.innerHTML = `<p class="empty-state">Could not load existing orders.</p>`;
    logTx(`Order list read failed: ${getErrorMessage(error)}`, null, true);
  }
}

async function handlePolicyAction(event) {
  const button = event.currentTarget;
  const action = button.dataset.action;
  const id = Number(button.dataset.id);

  try {
    await withLoading(button, async () => {
      const tx =
        action === "cancel"
          ? await cancelPolicy(id)
          : action === "execute"
            ? await executePolicy(id)
            : await expirePolicy(id);

      logTx(`${action} #${id} submitted`, tx.hash);
      await tx.wait();
      logTx(`${action} #${id} confirmed`, tx.hash);
      await refreshPolicies();
      await refreshBalances();
    });
  } catch (error) {
    const message = getErrorMessage(error);
    toast(message, true);
    logTx(`${action} #${id} failed: ${message}`, null, true);
  }
}

async function refreshDemo() {
  await refreshPoolState();
  await refreshBalances();
  await refreshPolicies();
  renderSummary();
  syncActionState();
}

async function onConnected(account, chainId) {
  const network = NETWORKS[chainId];
  btnConnect.textContent = shortAddr(account);
  networkBadge.textContent = network?.name || `Chain ${parseInt(chainId, 16)}`;
  networkBadge.classList.remove("hidden");
  accountPill.textContent = shortAddr(account);

  hookAddr = await resolveHookAddress();
  hookPill.textContent = hookAddr ? shortAddr(hookAddr) : "Missing";

  if (!hookAddr) {
    toast("Hook address missing from config.", true);
    syncActionState();
    return;
  }

  initHook(hookAddr, getSigner());
  if (isWrongNetwork()) {
    toast("Switch your wallet to Sepolia for the live demo.", true);
  }
  await refreshDemo();
}

btnConnect.addEventListener("click", async () => {
  try {
    await withLoading(btnConnect, async () => {
      const { account, chainId } = await connect();
      await onConnected(account, chainId);
      toast("Wallet connected");
      logTx("Wallet connected");
    });
  } catch (error) {
    toast(getErrorMessage(error), true);
  }
});

btnApprove.addEventListener("click", async () => {
  try {
    await withLoading(btnApprove, async () => {
      const mode = getMode();
      const tx = await approve(mode.spendToken, getSigner());
      logTx(`Approve ${mode.spendSymbol}`, tx.hash);
      await tx.wait();
      await refreshBalances();
      toast(`${mode.spendSymbol} approved`);
    });
  } catch (error) {
    const message = getErrorMessage(error);
    toast(message, true);
    logTx(`Approve failed: ${message}`, null, true);
  }
});

btnSubmit.addEventListener("click", async () => {
  try {
    await withLoading(btnSubmit, async () => {
      const mode = getMode();
      const amount = parseAmount(amountInput.value.trim());
      const expiry = Math.floor(Date.now() / 1000) + getExpirySeconds();
      const triggerPrice = getTriggerPrice();
      const spendBalance = await readTokenBalance(mode.spendToken, getAccount());

      if (spendBalance < amount) {
        throw new Error(`Not enough ${mode.spendSymbol} in wallet`);
      }

      const depositTx = await deposit(mode.spendToken, amount, false);
      logTx(`Deposit ${mode.spendSymbol}`, depositTx.hash);
      await depositTx.wait();

      const registerTx = await registerPolicy(
        DEMO_DEFAULTS.demoPoolId,
        triggerPrice,
        mode.triggerAbove,
        mode.zeroForOne,
        amount,
        0n,
        expiry,
        0n,
      );
      logTx("Register demo order", registerTx.hash);
      await registerTx.wait();

      amountInput.value = "";
      await refreshDemo();
      toast("Demo order created");
    });
  } catch (error) {
    const message = getErrorMessage(error);
    toast(message, true);
    logTx(`Create order failed: ${message}`, null, true);
  }
});

btnRefresh.addEventListener("click", async () => {
  try {
    await refreshDemo();
  } catch (error) {
    toast(getErrorMessage(error), true);
  }
});

modeButtons.forEach((button) => {
  button.addEventListener("click", async () => {
    selectedModeId = button.dataset.mode;
    setActiveButtons();
    renderSummary();
    if (getAccount() && hookAddr) {
      await refreshBalances();
    } else {
      syncActionState();
    }
  });
});

triggerButtons.forEach((button) => {
  button.addEventListener("click", () => {
    selectedTriggerBps = Number(button.dataset.trigger);
    setActiveButtons();
    renderSummary();
  });
});

amountInput.addEventListener("input", () => {
  renderSummary();
  syncActionState();
});

expirySelect.addEventListener("change", renderSummary);

onAccountChange(async ({ account, chainId }) => {
  if (!account) return;
  await onConnected(account, chainId);
});

renderAmountChips();
renderExpiryOptions();
setActiveButtons();
renderSummary();
syncActionState();
