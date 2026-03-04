# Mimosa Hook — Architecture

**Event-driven automation primitive for Uniswap v4 pools via Reactive Network.**

## Contract Separation

| Contract            | Chain                         | Responsibility                                                                                                                      |
| ------------------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **MimosaHook**      | Ethereum                      | Stores policies, validates price, executes swaps atomically inside the v4 pool. Attaches via `afterInitialize`.                     |
| **ReactiveTrigger** | Ethereum (called by Reactive) | Thin relay that bridges Reactive Network event detection to `MimosaHook.executePolicy()`. Catches reverts so subscriptions survive. |

### Why two contracts?

1. **Separation of concerns** — detection logic (Reactive) is decoupled from execution logic (hook).
2. **Trust minimization** — `executePolicy()` is permissionless and re-validates on-chain; the trigger doesn't need to be trusted.
3. **Extensibility** — swap the trigger contract without modifying the hook.

---

## Policy Storage Model

```solidity
struct Policy {
    address owner;        // creator & output recipient
    uint160 triggerPrice; // sqrtPriceX96 threshold
    bool    triggerAbove; // true → fire when price ≥ trigger
    bool    zeroForOne;   // swap direction
    uint128 inputAmount;  // exact-input amount
    bool    executed;     // one-shot guard
}
```

**Storage layout:**

- `mapping(uint256 => Policy) policies` — flat mapping, O(1) lookup
- `uint256 nextPolicyId` — sequential counter
- `mapping(address => mapping(Currency => uint256)) deposits` — pre-funded balances

**Design choices:**

- Single struct, no nested mappings — auditable and gas-efficient.
- `executed` flag prevents double execution without complex bookkeeping.
- Deposits are separated from policies so a user can fund multiple policies from one balance.

---

## Execution Validation Logic

```
executePolicy(policyId)
│
├─ 1. Check policy exists (owner ≠ address(0))
├─ 2. Check not already executed
├─ 3. Read sqrtPriceX96 from PoolManager via StateLibrary
├─ 4. Validate trigger condition:
│     triggerAbove=true  → require(currentPrice ≥ triggerPrice)
│     triggerAbove=false → require(currentPrice ≤ triggerPrice)
├─ 5. Set executed = true  (CEI pattern — before external call)
├─ 6. Call poolManager.unlock() → unlockCallback()
│     ├─ poolManager.swap(poolKey, params, "")
│     ├─ _settleDelta(currency0, delta.amount0())
│     └─ _settleDelta(currency1, delta.amount1())
└─ 7. Emit PolicyExecuted(policyId, amount0, amount1)
```

**Key invariant:** the on-chain price check in step 4 makes the trigger trustless. Even if a malicious caller invokes `executePolicy`, it only succeeds when conditions are genuinely met.

---

## End-to-End Execution Flow

```

 1. SETUP
    User deposits token1 into MimosaHook
    User calls registerPolicy(triggerPrice=P, triggerAbove=false,
                              zeroForOne=false, amount=A)
    Policy stored, deposit reserved

 2. IDLE
    Pool trades normally. Price stays above P.
    Any call to executePolicy(id) reverts with TriggerConditionNotMet.

 3. EXTERNAL EVENT
    A large sell (zeroForOne=true) pushes sqrtPriceX96 below P.
    Reactive Network detects the Swap event crossing the threshold.

 4. REACTION
    Reactive runtime calls ReactiveTrigger.react(policyId).
    ReactiveTrigger calls MimosaHook.executePolicy(policyId).

 5. ATOMIC EXECUTION (inside PoolManager.unlock callback)
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
| **Deposit safety**         | Tokens held by hook; reserved at policy registration. Only the depositor can withdraw unreserved funds.                                                        |
| **Callback validation**    | `unlockCallback` checks `msg.sender == address(poolManager)`.                                                                                                  |
| **Front-running**          | Trigger is permissionless — anyone can call `executePolicy` before Reactive. This is by design: policy executes at market price regardless of who triggers it. |

---

## Gas Considerations

| Operation              | Notes                                                                      |
| ---------------------- | -------------------------------------------------------------------------- |
| `registerPolicy`       | ~100k gas — writes a Policy struct + updates deposit mapping               |
| `executePolicy`        | ~200-350k gas — reads slot0, writes `executed`, performs swap + settlement |
| `deposit` / `withdraw` | ~50-80k gas — single ERC-20 transfer + mapping update                      |

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

| Test                                        | What it proves                                                                           |
| ------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `test_fullDemoFlow`                         | Complete demo narrative: register → fail → price move → react → succeed → no double-exec |
| `test_deposit_and_withdraw`                 | Deposit/withdraw accounting is correct                                                   |
| `test_registerPolicy_insufficientDeposit`   | Cannot register without funds                                                            |
| `test_registerPolicy_zeroAmount`            | Zero amount rejected                                                                     |
| `test_executePolicy_nonexistent`            | Non-existent policy reverts cleanly                                                      |
| `test_executePolicy_permissionless`         | Anyone (not just Reactive) can trigger execution                                         |
| `test_triggerAbove_direction`               | `triggerAbove=true` works — sell when price is high                                      |
| `test_reactiveTrigger_unauthorized`         | Only authorized origin can call `react()`                                                |
| `test_reactiveTrigger_batchExecution`       | Multiple policies execute in one tx                                                      |
| `test_getCurrentPrice`                      | Price read works                                                                         |
| `test_multiplePolicies_differentThresholds` | Policies at different thresholds execute independently                                   |

### Suggested next steps for integration testing

1. **Fork test** — fork mainnet/testnet, test against a real pool with real price
2. **Reactive simulation** — mock the Reactive runtime event loop with `vm.warp` / `vm.roll`
3. **Gas snapshot** — `forge snapshot` to track gas regressions

---

## File Structure

```
src/
├── MimosaHook.sol        # V4 hook: policies, validation, swap execution
└── ReactiveTrigger.sol   # Reactive Network relay contract
test/
└── MimosaHook.t.sol      # Full test suite (11 tests)
```

---

## Extensibility (post-MVP)

The architecture naturally extends to:

- **Multi-condition policies** — add a `bytes conditionData` field + pluggable condition checker
- **Multiple actions** — replace the fixed swap with an action enum (swap, add/remove liquidity, donate)
- **Recurring policies** — remove the `executed` flag, add a cooldown period
- **Cross-chain triggers** — Reactive Network already supports cross-chain event subscriptions
- **TWAP oracles** — replace the spot price check with a TWAP condition for manipulation resistance
