import { ethers } from "ethers";
import { MIMOSA_HOOK_ABI, ERC20_ABI } from "./abi.js";

let hookContract = null;
let hookAddress = null;

export function initHook(address, signerOrProvider) {
  hookAddress = address;
  hookContract = new ethers.Contract(
    address,
    MIMOSA_HOOK_ABI,
    signerOrProvider,
  );
}

export function getHookAddress() {
  return hookAddress;
}
export function getHookContract() {
  return hookContract;
}

export async function readDeposit(user, currency) {
  return hookContract.deposits(user, currency);
}

export async function readPolicy(policyId) {
  return hookContract.getPolicy(policyId);
}

export async function readActivePolicies(poolId) {
  return hookContract.getActivePolicies(poolId);
}

export async function readCurrentPrice(poolId) {
  return hookContract.getCurrentPrice(poolId);
}

export async function readNextPolicyId() {
  return hookContract.nextPolicyId();
}

export async function readPoolInitialized(poolId) {
  return hookContract.poolInitialized(poolId);
}

export async function approve(tokenAddress, signer) {
  const token = new ethers.Contract(tokenAddress, ERC20_ABI, signer);
  const tx = await token.approve(hookAddress, ethers.MaxUint256);
  return tx;
}

export async function deposit(currency, amount, isETH = false) {
  const opts = isETH ? { value: amount } : {};
  const tx = await hookContract.deposit(currency, amount, opts);
  return tx;
}

export async function withdraw(currency, amount) {
  const tx = await hookContract.withdraw(currency, amount);
  return tx;
}

export async function registerPolicy(
  poolId,
  triggerPrice,
  triggerAbove,
  zeroForOne,
  inputAmount,
  minOutput,
  expiry,
  executorTip,
) {
  const tx = await hookContract.registerPolicy(
    poolId,
    triggerPrice,
    triggerAbove,
    zeroForOne,
    inputAmount,
    minOutput,
    expiry,
    executorTip,
  );
  return tx;
}

export async function cancelPolicy(policyId) {
  const tx = await hookContract.cancelPolicy(policyId);
  return tx;
}

export async function executePolicy(policyId) {
  const tx = await hookContract.executePolicy(policyId);
  return tx;
}

export async function expirePolicy(policyId) {
  const tx = await hookContract.expirePolicy(policyId);
  return tx;
}

/**
 * Fetch all policies owned by `account` by scanning from 0 to nextPolicyId.
 * Good enough for a demo; production would use event indexing.
 */
export async function fetchUserPolicies(account) {
  const nextId = await readNextPolicyId();
  const policies = [];

  const batchSize = 20;
  for (let start = 0; start < Number(nextId); start += batchSize) {
    const end = Math.min(start + batchSize, Number(nextId));
    const batch = [];
    for (let i = start; i < end; i++) {
      batch.push(readPolicy(i).then((p) => ({ id: i, ...policyToObj(p) })));
    }
    const results = await Promise.all(batch);
    for (const p of results) {
      if (p.owner.toLowerCase() === account.toLowerCase()) {
        policies.push(p);
      }
    }
  }

  return policies;
}

function policyToObj(p) {
  return {
    owner: p.owner,
    poolId: p.poolId,
    triggerPrice: p.triggerPrice.toString(),
    triggerAbove: p.triggerAbove,
    zeroForOne: p.zeroForOne,
    inputAmount: p.inputAmount.toString(),
    minOutput: p.minOutput.toString(),
    expiry: Number(p.expiry),
    executorTip: p.executorTip.toString(),
    executed: p.executed,
  };
}
