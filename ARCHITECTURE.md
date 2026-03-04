# Mimosa Hook — Architecture

**Event-driven automation primitive for Uniswap v4 pools via Reactive Network.**

## Contract Separation

| Contract           | Chain                  | Responsibility                                                                                                                             |
| ------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **MimosaHook**     | Origin (e.g. Ethereum) | Stores policies, validates price, executes swaps atomically inside v4 pools. Supports multiple pools per deployment via `afterInitialize`. |
| **MimosaReactive** | Reactive Network       | Subscribes to Swap + policy-lifecycle events. Tracks policies in ReactVM state. Emits `Callback` when a price threshold is crossed.        |
| **MimosaCallback** | Origin (same as Hook)  | Receives callbacks from Reactive Network's Callback Proxy. Validates ReactVM ID. Forwards `executePolicy()` to MimosaHook with try/catch.  |

### Why this separation?

1. **Separation of concerns** — detection logic (MimosaReactive on Reactive Network) is decoupled from execution logic (MimosaHook on-chain).
2. **Trust minimization** — `executePolicy()` is permissionless and re-validates price on-chain; neither the reactive contract nor the callback needs to be trusted.
3. **Extensibility** — swap the reactive or callback contract without modifying the hook.
4. **Callback authorization** — MimosaCallback validates both `msg.sender == CallbackProxy` and the embedded ReactVM ID, preventing unauthorized triggering.

### Reactive Network Integration Flow

```
 Origin Chain                    Reactive Network                   Origin Chain
 ┌────────────┐                  ┌──────────────┐                  ┌──────────────┐
 │PoolManager │──Swap event──────▶│MimosaReactive│──Callback event──▶│MimosaCallback│
 │            │                  │  (ReactVM)   │                  │              │
 │MimosaHook  │──PolicyRegistered▶│  tracks      │                  │ executePolicy│
 │            │──PolicyExecuted──▶│  policies    │                  │   ──▶ Hook   │
 │            │──PolicyCancelled─▶│  per pool    │                  │              │
 │            │──PolicyExpired───▶│              │                  │              │
 └────────────┘                  └──────────────┘                  └──────────────┘
```

**Event subscriptions (set in MimosaReactive constructor):**

| Event              | Source      | Purpose                              |
| ------------------ | ----------- | ------------------------------------ |
| `Swap`             | PoolManager | Detect price changes; check policies |
| `PolicyRegistered` | MimosaHook  | Add policy to ReactVM tracking       |
| `PolicyExecuted`   | MimosaHook  | Remove policy from tracking          |
| `PolicyCancelled`  | MimosaHook  | Remove policy from tracking          |
| `PolicyExpired`    | MimosaHook  | Remove policy from tracking          |

**Topic computation:** Event topic hashes are derived from mirror interfaces
using `.selector` (immutable, set in constructor) — no hardcoded hex strings.

---

## Policy Storage Model

```solidity
struct Policy {
    address owner;        // creator & output recipient
    PoolId  poolId;       // which pool this policy targets
    uint160 triggerPrice; // sqrtPriceX96 threshold
    bool    triggerAbove; // true → fire when price ≥ trigger
    bool    zeroForOne;   // swap direction
    uint128 inputAmount;  // exact-input amount
    uint128 minOutput;    // slippage guard (0 = no limit)
    uint64  expiry;       // unix timestamp deadline (0 = no expiry)
    uint128 executorTip;  // tip paid to executor in input currency (0 = no tip)
    bool    executed;     // one-shot guard
}
```

**Storage layout:**

- `mapping(PoolId => PoolKey) _poolKeys` — registered pools (populated by afterInitialize)
- `mapping(PoolId => bool) poolInitialized` — quick existence check
- `mapping(uint256 => Policy) policies` — flat mapping, O(1) lookup
- `uint256 nextPolicyId` — sequential counter
- `mapping(address => mapping(Currency => uint256)) deposits` — pre-funded balances
- `mapping(PoolId => uint256[]) _activePolicies` — active policy IDs per pool (swap-and-pop array)
- `mapping(uint256 => uint256) _activePolicyIndex` — policyId → index in the active array (O(1) removal)

**Design choices:**

- Single struct, no nested mappings — auditable and gas-efficient.
- `executed` flag prevents double execution without complex bookkeeping.
- Deposits are separated from policies so a user can fund multiple policies from one balance.
- Multi-pool: a single hook deployment can serve any number of pools. Each policy stores its target `poolId`, so policies on different pools are fully independent.
- **Active index**: swap-and-pop array per pool enables O(1) enumeration of unexecuted policies. Used by Reactive Network to discover which policies to monitor.
- **Expiry**: policies with a non-zero `expiry` are automatically rejected after the deadline. Anyone can call `expirePolicy()` to garbage-collect and refund the owner.
- **Executor tip**: `executorTip` is reserved alongside `inputAmount` at registration. After a successful swap, the tip is transferred directly to `msg.sender`, incentivising third-party keepers.

---

## Execution Validation Logic

```
executePolicy(policyId)
│
├─ 1. Check policy exists (owner ≠ address(0))
├─ 2. Check not already executed
├─ 3. Check not expired (expiry == 0 || block.timestamp ≤ expiry)
├─ 4. Read sqrtPriceX96 from PoolManager via StateLibrary
├─ 5. Validate trigger condition:
│     triggerAbove=true  → require(currentPrice ≥ triggerPrice)
│     triggerAbove=false → require(currentPrice ≤ triggerPrice)
├─ 6. Set executed = true + remove from active index (CEI)
├─ 7. Call poolManager.unlock() → unlockCallback()
│     ├─ poolManager.swap(key, params, "")
│     ├─ Slippage check (outputDelta ≥ minOutput)
│     ├─ _settleDelta(key.currency0, delta.amount0())
│     └─ _settleDelta(key.currency1, delta.amount1())
├─ 8. Transfer executor tip (if any) to msg.sender
└─ 9. Emit PolicyExecuted(policyId, amount0, amount1)
```

**Key invariant:** the on-chain price check in step 4 makes the trigger trustless. Even if a malicious caller invokes `executePolicy`, it only succeeds when conditions are genuinely met.

---

## End-to-End Execution Flow

```

 1. SETUP
    User deposits token1 into MimosaHook
    User calls registerPolicy(poolId, triggerPrice=P, triggerAbove=false,
                              zeroForOne=false, amount=A)
    Policy stored, deposit reserved

 2. IDLE
    Pool trades normally. Price stays above P.
    Any call to executePolicy(id) reverts with TriggerConditionNotMet.

 3. EXTERNAL EVENT
    A large sell (zeroForOne=true) pushes sqrtPriceX96 below P.
    Reactive Network detects the Swap event crossing the threshold.

 4. REACTION (Reactive Network)
    MimosaReactive.react() receives the Swap LogRecord.
    Iterates tracked policies for that pool.
    Finds policy with triggerPrice=P, triggerAbove=false.
    sqrtPriceX96 ≤ P → emits Callback(chainId, callbackContract, gasLimit, payload).

 5. CALLBACK DELIVERY
    Reactive Network delivers callback tx to MimosaCallback.
    First argument replaced with ReactVM ID.
    MimosaCallback validates auth, calls hook.executePolicy(policyId).

 6. ATOMIC EXECUTION (inside PoolManager.unlock callback)
    Hook reads current price → confirms ≤ P
    Hook marks policy executed
    Hook swaps token1→token0 at current market price
    Swap output (token0) sent to policy owner
    All deltas settled → PoolManager re-locks

 6. DONE
    Policy.executed = true
    Owner's token0 balance increased
    Any further executePolicy(id) reverts with PolicyAlreadyExecuted
```

---

## Security Considerations

| Concern                    | Mitigation                                                                                                                                                     |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Double execution**       | `executed` flag checked before any state change; set before external call (CEI).                                                                               |
| **Reentrancy**             | CEI pattern: `executed = true` before `poolManager.unlock()`. PoolManager also re-locks after callback.                                                        |
| **Unauthorized execution** | `executePolicy()` is intentionally permissionless. Execution only succeeds when price condition is met on-chain. No trust in caller.                           |
| **Price manipulation**     | MVP acknowledges single-block manipulation risk. Production would add TWAP or multi-block checks.                                                              |
| **Deposit safety**         | Tokens held by hook; reserved at policy registration (inputAmount + executorTip). Only the depositor can withdraw unreserved funds.                            |
| **Callback validation**    | `unlockCallback` checks `msg.sender == address(poolManager)`. MimosaCallback checks `authorizedSenderOnly` + `rvmIdOnly`.                                      |
| **Front-running**          | Trigger is permissionless — anyone can call `executePolicy` before Reactive. This is by design: policy executes at market price regardless of who triggers it. |
| **Slippage / sandwich**    | `minOutput` field on each policy sets a floor on swap output. If the AMM returns less, the entire transaction reverts inside `unlockCallback`.                 |
| **Stale policies**         | `expiry` field allows garbage-collection via `expirePolicy()`. Expired policies refund the owner and are removed from the active index.                        |
| **Executor incentive**     | `executorTip` is paid from hook holdings after a successful swap. Tip payment follows all state changes (CEI). No tip is paid if the swap reverts.             |

---

## Gas Considerations

| Operation              | Notes                                                                                     |
| ---------------------- | ----------------------------------------------------------------------------------------- |
| `registerPolicy`       | ~100k gas — writes a Policy struct + updates deposit mapping + active index               |
| `executePolicy`        | ~200-350k gas — reads slot0, writes `executed`, performs swap + settlement + tip transfer |
| `deposit` / `withdraw` | ~50-80k gas — single ERC-20 transfer + mapping update                                     |

**Optimizations applied:**

- Minimal storage slots (one struct per policy)
- No loops in execution path
- `StateLibrary.getSlot0()` is a single `extsload` (cold ~2100 gas)
- Settlement uses direct `transfer` + `settle` (no approve needed for hook→PoolManager)

---

## Local Testing Strategy

### Quick start

```bash
forge test -vvv --match-path test/MimosaHook.t.sol
```

### Test matrix

| Test                                        | What it proves                                                                             |
| ------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `test_fullDemoFlow`                         | Complete demo narrative: register → fail → price move → execute → succeed → no double-exec |
| `test_deposit_and_withdraw`                 | Deposit/withdraw accounting is correct                                                     |
| `test_registerPolicy_insufficientDeposit`   | Cannot register without funds                                                              |
| `test_registerPolicy_zeroAmount`            | Zero amount rejected                                                                       |
| `test_executePolicy_nonexistent`            | Non-existent policy reverts cleanly                                                        |
| `test_executePolicy_permissionless`         | Anyone (not just Reactive) can trigger execution                                           |
| `test_triggerAbove_direction`               | `triggerAbove=true` works — sell when price is high                                        |
| `test_getCurrentPrice`                      | Price read works                                                                           |
| `test_multiplePolicies_differentThresholds` | Policies at different thresholds execute independently                                     |
| `test_cancelPolicy_refundsDeposit`          | Cancel returns reserved tokens to deposit balance                                          |
| `test_cancelPolicy_notOwner`                | Only owner can cancel a policy                                                             |
| `test_cancelPolicy_alreadyExecuted`         | Cannot cancel an already-executed policy                                                   |
| `test_cancelPolicy_nonexistent`             | Cannot cancel a non-existent policy                                                        |
| `test_cancelPolicy_thenWithdraw`            | Cancel + withdraw restores full token balance                                              |
| `test_registerPolicy_poolNotInitialized`    | Cannot register a policy for an uninitialized pool                                         |
| `test_multiPool`                            | Two pools share one hook; policies and prices are independent                              |
| `test_slippage_protection_passes`           | Swap succeeds when output meets `minOutput`                                                |
| `test_slippage_protection_reverts`          | Swap reverts when `minOutput` is unachievable                                              |
| `test_deposit_and_withdraw_nativeETH`       | Native ETH deposit/withdraw works correctly                                                |
| `test_deposit_nativeETH_incorrectValue`     | Rejects ETH deposit with mismatched `msg.value`                                            |
| `test_activePolicy_index`                   | Active policy array tracks register/cancel/execute correctly (swap-and-pop)                |
| `test_expiry_revertsWhenExpired`            | Expired policy cannot be executed                                                          |
| `test_expiry_executesBeforeDeadline`        | Policy with expiry executes successfully before deadline                                   |
| `test_expirePolicy_refunds`                 | Permissionless `expirePolicy()` refunds owner deposits                                     |
| `test_expirePolicy_notExpiredYet`           | Cannot expire a policy before its deadline                                                 |
| `test_expirePolicy_noExpirySet`             | Cannot expire a policy with no expiry (expiry == 0)                                        |
| `test_executorTip_paidToExecutor`           | Executor receives tip in input currency after execution                                    |
| `test_executorTip_cancelRefundsFull`        | Cancel refunds both `inputAmount` + `executorTip`                                          |
| `test_expirePolicy_refundsTipAndInput`      | Expire refunds both `inputAmount` + `executorTip`                                          |

#### MimosaReactive.t.sol (16 tests)

| Test                                          | What it proves                                                             |
| --------------------------------------------- | -------------------------------------------------------------------------- |
| `test_reactive_tracksPolicyOnRegistered`      | PolicyRegistered event correctly populates ReactVM tracking state          |
| `test_reactive_tracksDuplicateIdempotent`     | Duplicate events are silently ignored (idempotent)                         |
| `test_reactive_untracksPolicyOnExecuted`      | PolicyExecuted event removes policy from tracking                          |
| `test_reactive_untracksPolicyOnCancelled`     | PolicyCancelled event removes policy from tracking                         |
| `test_reactive_untracksPolicyOnExpired`       | PolicyExpired event removes policy from tracking                           |
| `test_reactive_emitsCallbackOnSwap`           | Swap below trigger price emits a Callback event                            |
| `test_reactive_noCallbackWhenConditionNotMet` | Swap that doesn't cross threshold emits no Callback                        |
| `test_reactive_multipleTriggersInOneSwap`     | Single swap triggers multiple policies → multiple Callbacks                |
| `test_reactive_triggerAbove`                  | triggerAbove=true correctly triggers when price rises above threshold      |
| `test_reactive_ignoresUnrelatedPool`          | Swap on a different pool does not trigger policies for another pool        |
| `test_callback_executesPolicy`                | MimosaCallback successfully forwards execution to MimosaHook               |
| `test_callback_unauthorizedSenderReverts`     | Only the Callback Proxy can call executeCallback                           |
| `test_callback_wrongRvmIdReverts`             | Wrong ReactVM ID is rejected                                               |
| `test_callback_failedExecutionDoesNotRevert`  | Failed execution (nonexistent policy) doesn't revert the callback tx       |
| `test_callback_emitsExecutionForwarded`       | ExecutionForwarded event emitted with correct success flag                 |
| `test_endToEnd_reactive_triggers_callback`    | Full flow: register → feed events to reactive → callback → policy executed |

### Suggested next steps for integration testing

1. **Fork test** — fork mainnet/testnet, test against a real pool with real price
2. **Reactive simulation** — mock the Reactive runtime event loop with `vm.warp` / `vm.roll`
3. **Gas snapshot** — `forge snapshot` to track gas regressions

---

## File Structure

```
src/
├── MimosaHook.sol        # V4 hook: policies, validation, swap execution
├── MimosaReactive.sol    # Reactive Network: event subscriptions, policy tracking, callback emission
└── MimosaCallback.sol    # Destination chain: callback receiver, auth, try/catch forwarding
test/
├── MimosaHook.t.sol      # Hook test suite (29 tests)
└── MimosaReactive.t.sol  # Reactive + Callback test suite (16 tests)
```

---

## Extensibility (post-MVP)

The architecture naturally extends to:

- **Multi-condition policies** — add a `bytes conditionData` field + pluggable condition checker
- **Multiple actions** — replace the fixed swap with an action enum (swap, add/remove liquidity, donate)
- **Recurring policies** — remove the `executed` flag, add a cooldown period
- **Cross-chain triggers** — Reactive Network already supports cross-chain event subscriptions
- **Multi-pool strategies** — policies that span multiple pools (e.g., arbitrage between fee tiers)
- **TWAP oracles** — replace the spot price check with a TWAP condition for manipulation resistance
