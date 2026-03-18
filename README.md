# Mimosa Hook

Uniswap v4 hook for reactive limit-style execution. Users deposit funds into the hook, register a price policy, and Reactive Network delivers a callback when pool activity crosses the configured threshold.

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

### One-command deploy

```bash
cp .env.example .env
source .env
./script/deploy.sh
```

### Manual deploy

Deploy origin-side contracts:

```bash
POOL_MANAGER=0x... CALLBACK_PROXY=0x... \
forge script script/DeployMimosaHook.s.sol \
  --rpc-url "$ORIGIN_RPC" \
  --broadcast \
  --verify
```

Deploy the Reactive contract:

```bash
ORIGIN_CHAIN_ID=11155111 \
HOOK=0x... \
CALLBACK=0x... \
REACTIVE_DEPOSIT_WEI=0 \
forge script script/DeployReactive.s.sol \
  --rpc-url "$REACTIVE_RPC" \
  --broadcast
```

Both scripts write JSON manifests into `deployments/` for the frontend.

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
