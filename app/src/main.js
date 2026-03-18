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
import {
  NETWORKS,
  TOKEN_PRESETS,
  POLICY_TEMPLATES,
  EXPIRY_PRESETS,
  QUICK_AMOUNTS,
  ZERO,
  loadManifest,
} from "./config.js";

const $ = (s) => document.querySelector(s);

const btnConnect = $("#btn-connect");
const btnApprove = $("#btn-approve");
const btnDeposit = $("#btn-deposit");
const btnWithdraw = $("#btn-withdraw");
const btnRegister = $("#btn-register");
const btnRefresh = $("#btn-refresh");
const btnPrice = $("#btn-price");

const networkBadge = $("#network-badge");
const statusBar = $("#status-bar");
const accountDisplay = $("#account-display");
const hookDisplay = $("#hook-display");
const deploymentDisplay = $("#deployment-display");

const sectionSetup = $("#section-setup");
const sectionDeposit = $("#section-deposit");
const sectionRegister = $("#section-register");
const sectionPolicies = $("#section-policies");
const sectionLog = $("#section-log");

const templatePreset = $("#template-preset");
const templateSummary = $("#template-summary");
const poolIdInput = $("#pool-id");
const poolPrice = $("#pool-price");

const tokenPreset = $("#deposit-token-preset");
const customTokenWrap = $("#custom-token-wrap");
const depositToken = $("#deposit-token");
const depositAmount = $("#deposit-amount");
const depositBalance = $("#deposit-balance");
const assetNote = $("#asset-note");

const regPrice = $("#reg-price");
const regDirection = $("#reg-direction");
const regZfo = $("#reg-zfo");
const regAmount = $("#reg-amount");
const regMin = $("#reg-min");
const regExpiryPreset = $("#reg-expiry-preset");
const customExpiryWrap = $("#custom-expiry-wrap");
const regExpiry = $("#reg-expiry");
const regTip = $("#reg-tip");

const policiesList = $("#policies-list");
const txLog = $("#tx-log");
const depositQuickRow = $("#deposit-quick-row");
const registerQuickRow = $("#register-quick-row");

let hookAddr = null;
let manifest = null;

function toast(msg, error = false) {
  const el = $("#toast");
  el.textContent = msg;
  el.classList.toggle("error", error);
  el.classList.remove("hidden");
  el.classList.add("show");
  setTimeout(() => el.classList.remove("show"), 3500);
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
    ${txHash ? `<a class="tx-hash" href="${explorerTxUrl(txHash)}" target="_blank" rel="noopener">${shortAddr(txHash)}</a>` : ""}
  `;
  txLog.prepend(div);
}

function explorerTxUrl(hash) {
  const net = NETWORKS[getChainId()];
  return `${net?.explorer || "https://etherscan.io"}/tx/${hash}`;
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

function safeAddress(addr) {
  if (!addr) return null;
  if (addr === "0x0") return ZERO;
  return addr;
}

function isZeroAddress(addr) {
  return !addr || addr.toLowerCase() === ZERO.toLowerCase();
}

function selectedTokenConfig() {
  return TOKEN_PRESETS.find((token) => token.id === tokenPreset.value);
}

function getSelectedTokenAddress() {
  const preset = selectedTokenConfig();
  if (!preset) return null;
  if (preset.id === "custom") return safeAddress(depositToken.value.trim());
  return preset.address;
}

function populateSelect(selectEl, items) {
  selectEl.innerHTML = items
    .map((item) => `<option value="${item.id}">${item.label}</option>`)
    .join("");
}

function renderQuickAmountButtons(target, inputId) {
  target.innerHTML = QUICK_AMOUNTS
    .map(
      (value) =>
        `<button class="chip-btn" data-fill="${value}" data-target="${inputId}">${value}</button>`,
    )
    .join("");
}

function setupPresetControls() {
  populateSelect(templatePreset, POLICY_TEMPLATES);
  populateSelect(tokenPreset, TOKEN_PRESETS);
  populateSelect(regExpiryPreset, EXPIRY_PRESETS);
  renderQuickAmountButtons(depositQuickRow, "deposit-amount");
  renderQuickAmountButtons(registerQuickRow, "reg-amount");

  document.querySelectorAll("[data-fill]").forEach((btn) => {
    btn.addEventListener("click", (event) => {
      event.preventDefault();
      const target = $(`#${btn.dataset.target}`);
      target.value = btn.dataset.fill;
    });
  });

  applyTemplate(POLICY_TEMPLATES[0].id);
  tokenPreset.value = TOKEN_PRESETS[0].id;
  syncTokenPreset();
  syncExpiryPreset();
}

function applyTemplate(templateId) {
  const template = POLICY_TEMPLATES.find((item) => item.id === templateId);
  if (!template) return;

  regPrice.value = template.triggerPrice;
  regDirection.value = template.triggerDirection;
  regZfo.value = template.zeroForOne;
  regAmount.value = template.amount;
  regMin.value = template.minOutput;
  regTip.value = template.tip;
  regExpiryPreset.value = template.expiryPreset;
  templateSummary.textContent = template.summary;
  syncExpiryPreset();
}

function syncTokenPreset() {
  const token = selectedTokenConfig();
  const isCustom = token?.id === "custom";
  customTokenWrap.classList.toggle("hidden", !isCustom);

  const label = token?.label || "Unknown";
  const note = token?.note || "Choose the asset you will spend when the policy executes.";
  const address = isCustom ? depositToken.value.trim() || "Paste a token address." : token.address;
  assetNote.textContent = `${label}: ${note} ${address ? `Address: ${address}` : ""}`.trim();

  const customMissing = isCustom && !safeAddress(depositToken.value.trim());
  btnApprove.disabled =
    !token || customMissing || (!isCustom && isZeroAddress(token.address));
  refreshBalance();
}

function syncExpiryPreset() {
  customExpiryWrap.classList.toggle("hidden", regExpiryPreset.value !== "custom");
  if (regExpiryPreset.value !== "custom") regExpiry.value = "";
}

function describeDeployment(hook) {
  return isZeroAddress(hook) ? "Manifest empty" : "Manifest loaded";
}

async function withLoading(btn, fn) {
  btn.classList.add("loading");
  btn.disabled = true;
  try {
    return await fn();
  } finally {
    btn.classList.remove("loading");
    btn.disabled = false;
    syncTokenPreset();
  }
}

async function resolveHookAddress() {
  const params = new URLSearchParams(window.location.search);
  const hookFromQuery = params.get("hook");
  if (hookFromQuery && !isZeroAddress(hookFromQuery)) return hookFromQuery;

  const net = NETWORKS[getChainId()];
  if (net?.hook && !isZeroAddress(net.hook)) return net.hook;

  if (!manifest) manifest = await loadManifest();
  if (manifest?.origin?.hook && !isZeroAddress(manifest.origin.hook)) {
    return manifest.origin.hook;
  }

  return null;
}

async function onConnected(account, chainId) {
  const net = NETWORKS[chainId];
  btnConnect.textContent = shortAddr(account);
  networkBadge.textContent = net?.name || `Chain ${parseInt(chainId, 16)}`;
  networkBadge.classList.remove("hidden");

  if (!manifest) manifest = await loadManifest();
  hookAddr = await resolveHookAddress();

  accountDisplay.textContent = shortAddr(account);
  hookDisplay.textContent = hookAddr ? shortAddr(hookAddr) : "Not deployed";
  deploymentDisplay.textContent = hookAddr
    ? describeDeployment(hookAddr)
    : "Deploy on Sepolia first";
  statusBar.classList.remove("hidden");

  if (!hookAddr) {
    toast("No hook address configured yet. Deploy first, then refresh the app.", true);
    sectionSetup.classList.remove("hidden");
    sectionLog.classList.remove("hidden");
    return;
  }

  initHook(hookAddr, getSigner());

  statusBar.classList.remove("hidden");
  sectionSetup.classList.remove("hidden");
  sectionDeposit.classList.remove("hidden");
  sectionRegister.classList.remove("hidden");
  sectionPolicies.classList.remove("hidden");
  sectionLog.classList.remove("hidden");

  await refreshBalance();
  await refreshPolicies();

  toast(`Connected to ${net?.name || "chain"}`);
  logTx("Wallet connected");
}

async function refreshBalance() {
  if (!getAccount() || !hookAddr) return;
  const token = getSelectedTokenAddress();
  if (!token) {
    depositBalance.textContent = "—";
    return;
  }

  try {
    const bal = await readDeposit(getAccount(), token);
    depositBalance.textContent = formatAmount(bal);
  } catch {
    depositBalance.textContent = "—";
  }
}

function getExpiryValue() {
  const preset = EXPIRY_PRESETS.find((item) => item.id === regExpiryPreset.value);
  if (!preset) return 0;
  if (preset.id === "custom") return parseInt(regExpiry.value.trim(), 10) || 0;
  if (preset.seconds === 0) return 0;
  return Math.floor(Date.now() / 1000) + preset.seconds;
}

function renderPolicyCard(policy) {
  const expiryStr = policy.expiry
    ? new Date(policy.expiry * 1000).toLocaleString()
    : "none";
  const status = policy.executed ? "executed" : "active";
  const trigger = `${policy.triggerAbove ? "≥" : "≤"} ${truncNum(policy.triggerPrice)}`;
  const swapSide = policy.zeroForOne ? "token0→token1" : "token1→token0";

  return `
    <div class="policy-card ${policy.executed ? "executed" : ""}">
      <div class="policy-header">
        <span class="policy-id">#${policy.id}</span>
        <span class="policy-status ${status}">${status}</span>
      </div>
      <dl class="policy-meta">
        <div><dt>Pool</dt><dd>${shortAddr(policy.poolId)}</dd></div>
        <div><dt>Trigger</dt><dd>${trigger}</dd></div>
        <div><dt>Swap</dt><dd>${swapSide}</dd></div>
        <div><dt>Input</dt><dd>${formatAmount(policy.inputAmount)}</dd></div>
        <div><dt>Min out</dt><dd>${formatAmount(policy.minOutput)}</dd></div>
        <div><dt>Tip</dt><dd>${formatAmount(policy.executorTip)}</dd></div>
        <div><dt>Expiry</dt><dd>${expiryStr}</dd></div>
      </dl>
      ${
        policy.executed
          ? ""
          : `
        <div class="policy-actions">
          <button class="btn btn-sm btn-accent" data-action="execute" data-id="${policy.id}">Execute</button>
          <button class="btn btn-sm btn-danger" data-action="cancel" data-id="${policy.id}">Cancel</button>
          ${
            policy.expiry
              ? `<button class="btn btn-sm btn-ghost" data-action="expire" data-id="${policy.id}">Expire</button>`
              : ""
          }
        </div>
      `
      }
    </div>
  `;
}

async function refreshPolicies() {
  if (!getAccount() || !hookAddr) return;

  try {
    const policies = await fetchUserPolicies(getAccount());
    if (policies.length === 0) {
      policiesList.innerHTML = `<p class="empty-state">No policies yet.</p>`;
      return;
    }

    policies.sort((a, b) => {
      if (a.executed !== b.executed) return a.executed ? 1 : -1;
      return b.id - a.id;
    });

    policiesList.innerHTML = policies.map(renderPolicyCard).join("");
    policiesList.querySelectorAll("[data-action]").forEach((btn) => {
      btn.addEventListener("click", handlePolicyAction);
    });
  } catch {
    policiesList.innerHTML = `<p class="empty-state">Error loading policies.</p>`;
  }
}

async function handlePolicyAction(event) {
  const btn = event.currentTarget;
  const action = btn.dataset.action;
  const id = parseInt(btn.dataset.id, 10);

  try {
    await withLoading(btn, async () => {
      let tx;
      if (action === "cancel") tx = await cancelPolicy(id);
      if (action === "execute") tx = await executePolicy(id);
      if (action === "expire") tx = await expirePolicy(id);

      logTx(`${capitalize(action)} #${id} submitted`, tx.hash);
      await tx.wait();
      logTx(`${capitalize(action)} #${id} confirmed`, tx.hash);
      toast(`Policy #${id} ${action}d`);
      await refreshBalance();
      await refreshPolicies();
    });
  } catch (e) {
    const message = e.shortMessage || e.message;
    toast(message, true);
    logTx(`${capitalize(action)} #${id} failed: ${message}`, null, true);
  }
}

function truncNum(n) {
  const s = n.toString();
  if (s.length <= 14) return s;
  return `${s.slice(0, 8)}…${s.slice(-4)}`;
}

function capitalize(value) {
  return value.charAt(0).toUpperCase() + value.slice(1);
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

btnPrice.addEventListener("click", async () => {
  if (!poolIdInput.value.trim()) {
    toast("Paste a pool ID first", true);
    return;
  }
  if (!hookAddr) {
    toast("Deploy and configure the hook first", true);
    return;
  }

  try {
    await withLoading(btnPrice, async () => {
      const price = await readCurrentPrice(poolIdInput.value.trim());
      poolPrice.textContent = price.toString();
      logTx("Read current pool price");
    });
  } catch (e) {
    poolPrice.textContent = "Unavailable";
    toast(e.shortMessage || e.message, true);
  }
});

tokenPreset.addEventListener("change", syncTokenPreset);
depositToken.addEventListener("input", syncTokenPreset);
templatePreset.addEventListener("change", () => applyTemplate(templatePreset.value));
regExpiryPreset.addEventListener("change", syncExpiryPreset);

btnApprove.addEventListener("click", async () => {
  const token = getSelectedTokenAddress();
  if (!token || isZeroAddress(token)) {
    toast("No approval needed for native ETH", true);
    return;
  }

  try {
    await withLoading(btnApprove, async () => {
      const tx = await approve(token, getSigner());
      logTx("Approve submitted", tx.hash);
      await tx.wait();
      logTx("Approve confirmed", tx.hash);
      toast("Approval confirmed");
    });
  } catch (e) {
    const message = e.shortMessage || e.message;
    toast(message, true);
    logTx(`Approve failed: ${message}`, null, true);
  }
});

btnDeposit.addEventListener("click", async () => {
  const token = getSelectedTokenAddress();
  const amountStr = depositAmount.value.trim();

  if (!token || !amountStr) {
    toast("Choose an asset and amount", true);
    return;
  }

  try {
    await withLoading(btnDeposit, async () => {
      const amount = parseAmount(amountStr);
      const isETH = isZeroAddress(token);
      const tx = await deposit(token, amount, isETH);
      logTx("Deposit submitted", tx.hash);
      await tx.wait();
      logTx("Deposit confirmed", tx.hash);
      toast("Deposit confirmed");
      await refreshBalance();
    });
  } catch (e) {
    const message = e.shortMessage || e.message;
    toast(message, true);
    logTx(`Deposit failed: ${message}`, null, true);
  }
});

btnWithdraw.addEventListener("click", async () => {
  const token = getSelectedTokenAddress();
  const amountStr = depositAmount.value.trim();

  if (!token || !amountStr) {
    toast("Choose an asset and amount", true);
    return;
  }

  try {
    await withLoading(btnWithdraw, async () => {
      const tx = await withdraw(token, parseAmount(amountStr));
      logTx("Withdraw submitted", tx.hash);
      await tx.wait();
      logTx("Withdraw confirmed", tx.hash);
      toast("Withdraw confirmed");
      await refreshBalance();
    });
  } catch (e) {
    const message = e.shortMessage || e.message;
    toast(message, true);
    logTx(`Withdraw failed: ${message}`, null, true);
  }
});

btnRegister.addEventListener("click", async () => {
  if (!poolIdInput.value.trim()) {
    toast("Pool ID is required", true);
    return;
  }

  try {
    await withLoading(btnRegister, async () => {
      const tx = await registerPolicy(
        poolIdInput.value.trim(),
        regPrice.value.trim(),
        regDirection.value === "above",
        regZfo.value === "true",
        parseAmount(regAmount.value.trim()),
        regMin.value.trim() === "0" ? 0n : parseAmount(regMin.value.trim()),
        getExpiryValue(),
        regTip.value.trim() === "0" ? 0n : parseAmount(regTip.value.trim()),
      );

      logTx("Register policy submitted", tx.hash);
      await tx.wait();
      logTx("Policy registered", tx.hash);
      toast("Policy registered");
      await refreshBalance();
      await refreshPolicies();
    });
  } catch (e) {
    const message = e.shortMessage || e.message;
    toast(message, true);
    logTx(`Register failed: ${message}`, null, true);
  }
});

btnRefresh.addEventListener("click", refreshPolicies);

onAccountChange(async ({ account, chainId }) => {
  if (account) await onConnected(account, chainId);
});

setupPresetControls();
