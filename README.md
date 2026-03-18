# Mimosa Hook

Uniswap v4 hook for reactive limit-style execution. Users deposit funds into the hook, register a price policy, and Reactive Network delivers a callback when pool activity crosses the configured threshold.

## Hook addresses
  - MimosaHook: 0x892D42B22Ac103C682e43b945c81C4572E269000
  - MimosaCallback: 0x673e2D03864C2c2Eb819646c7DDa3B5047aE627d
  - MimosaReactive: 0xC9AFf43028B7578F42C2eF08C51B48F3d16341E9

## What it does

`MimosaHook` turns Uniswap v4 swaps into event-driven orders:

1. Deposit the input asset into the hook.
2. Register a policy for a specific pool and `sqrtPriceX96` trigger.
3. `MimosaReactive` watches `Swap` and policy lifecycle events.
4. When a trigger is crossed, Reactive Network sends a callback.
5. `MimosaCallback` forwards execution to the hook.
6. `MimosaHook` re-checks the live pool price on-chain and executes the swap atomically.

The reactive layer is used for detection and delivery, not trust. Execution is still permissionless, and the hook only swaps if the condition is true at execution time.

## Contracts

| Contract | Chain | Role |
| --- | --- | --- |
| `MimosaHook` | Origin chain | Stores deposits and policies, validates trigger conditions, executes the Uniswap v4 swap |
| `MimosaReactive` | Reactive Network | Subscribes to `Swap`, `PolicyRegistered`, `PolicyExecuted`, `PolicyCancelled`, and `PolicyExpired`; tracks active policies and emits `Callback` |
| `MimosaCallback` | Origin chain | Accepts the Reactive callback and forwards `executePolicy(policyId)` to the hook |

## Reactive Network integration

The integration is intentionally split:

- `MimosaHook` is the trust anchor. It owns user funds, stores policy state, reads `slot0`, and executes through `PoolManager.unlock()`.
- `MimosaReactive` reconstructs enough policy state from emitted events to know which pool/price combinations should trigger callbacks.
- `MimosaCallback` is the authorized callback receiver on the origin chain. It uses `try/catch` so stale deliveries do not revert the whole callback transaction.

End-to-end flow:

1. User deposits into `MimosaHook`.
2. User calls `registerPolicy(...)`.
3. `MimosaReactive` tracks that policy from `PolicyRegistered`.
4. A Uniswap v4 `Swap` crosses the threshold.
5. `MimosaReactive` emits `Callback(originChainId, callbackContract, gasLimit, payload)`.
6. Reactive Network delivers the callback to `MimosaCallback`.
7. `MimosaCallback` calls `MimosaHook.executePolicy(policyId)`.
8. `MimosaHook` re-validates price on-chain, settles deltas, and pays the output directly to the policy owner.

## Correctness notes

The current implementation is coherent across all three contracts:

- `MimosaHook` is correctly wired as a v4 `afterInitialize` hook and captures each initialized `PoolKey`.
- Policies reserve funds up front and release them correctly on cancel or expiry.
- Execution is one-shot, permissionless, and protected by a fresh on-chain price check before swap.
- `MimosaReactive` subscribes to the right event set and tracks active policies by pool without needing RPC reads.
- `MimosaCallback` enforces callback-proxy sender auth plus ReactVM identity auth before forwarding execution.

Local verification in this repo:

```bash
forge build
forge test
```

Current result: `45/45` tests passing.

## Deployment

`MimosaHook` and `MimosaCallback` are deployed on the origin chain. `MimosaReactive` is deployed on Reactive Network.

Important operational detail: `MimosaCallback` stores the deployer as its allowed ReactVM ID through `AbstractCallback`, so `MimosaReactive` and `MimosaCallback` should be deployed by the same broadcaster.

### Sepolia deployment that succeeded

Origin chain:

- Chain ID: `11155111`
- PoolManager: `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`
- Callback Proxy: `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`

Reactive chain:

- Reactive Lasna (`5318007`)
- RPC: `https://lasna-rpc.rnk.dev/`

Deploy the origin-side contracts first:

```bash
forge script script/DeployMimosaHook.s.sol:DeployOrigin \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer \
  --broadcast
```

Deploy the reactive contract without auto-activating subscriptions:

```bash
export ORIGIN_CHAIN_ID=11155111
export POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
export HOOK=0x892D42B22Ac103C682e43b945c81C4572E269000
export CALLBACK=0x673e2D03864C2c2Eb819646c7DDa3B5047aE627d
export REACTIVE_DEPOSIT_WEI=0
export ACTIVATE_SUBSCRIPTIONS=false

forge script script/DeployReactive.s.sol:DeployReactive \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer \
  --broadcast
```

Then activate subscriptions manually on Reactive Network:

```bash
cast send 0xC9AFf43028B7578F42C2eF08C51B48F3d16341E9 \
  "activateHookSubscriptions()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer

cast send 0xC9AFf43028B7578F42C2eF08C51B48F3d16341E9 \
  "activateSwapSubscription()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

This manual two-step activation is the flow that succeeded in practice. Constructor-time or single-step subscription activation reverted against the Reactive system contract.

### Deployment manifests

Write the final addresses into:

- `deployments/11155111.json`
- `deployments/reactive-5318007.json`
- `app/public/mimosa.json`

so the frontend can resolve the live deployment automatically.

## Project layout

```text
src/
├── MimosaHook.sol
├── MimosaReactive.sol
└── MimosaCallback.sol
test/
├── MimosaHook.t.sol
└── MimosaReactive.t.sol
script/
├── DeployMimosaHook.s.sol
├── DeployReactive.s.sol
└── deploy.sh
```

## More detail

See `ARCHITECTURE.md` for the fuller design and security notes.
