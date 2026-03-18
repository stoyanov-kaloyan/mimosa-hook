# Mimosa Hook

Uniswap v4 hook for reactive limit-style execution. Users deposit funds into the hook, register a price policy, and Reactive Network delivers a callback when pool activity crosses the configured threshold.

## Hook addresses
  - MimosaHook: 0x892D42B22Ac103C682e43b945c81C4572E269000
  - MimosaCallback: 0x673e2D03864C2c2Eb819646c7DDa3B5047aE627d
  - MimosaReactive: 0xe407a500F9c4948a53F7d51F025F74F62b7CE801

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
cast send 0xe407a500F9c4948a53F7d51F025F74F62b7CE801 \
  "activateHookSubscriptions()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer

cast send 0xe407a500F9c4948a53F7d51F025F74F62b7CE801 \
  "activateSwapSubscription()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

This manual two-step activation is the flow that succeeded in practice. Constructor-time or single-step subscription activation reverted against the Reactive system contract.

If subscriptions later show as inactive after the contract runs out of `lREACT`, refuel the contract and explicitly re-arm them:

```bash
cast send 0xe407a500F9c4948a53F7d51F025F74F62b7CE801 \
  "repairSubscriptions()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

That repair path is available in the patched `MimosaReactive` contract and should be used for future deployments.

### Deployment manifests

Write the final addresses into:

- `deployments/11155111.json`
- `deployments/reactive-5318007.json`
- `app/public/mimosa.json`

so the frontend can resolve the live deployment automatically.

### Demo pool on Sepolia

The current Sepolia demo pool uses:

- `token0`: `0x5B753e64d1B87fBC350e9adC1758eecf52c32Ae5` (`Mimosa Demo USD`)
- `token1`: `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` (Sepolia WETH)
- `fee`: `3000`
- `tickSpacing`: `60`
- `sqrtPriceX96`: `79228162514264337593543950336`
- `poolId`: `0xf0e88c3617e824a1f559635edca7b5a68215c4e80d60e15903f144c8c9f2a679`

Deploy a demo token if you want a fresh asset:

```bash
export TOKEN_NAME="Mimosa Demo USD"
export TOKEN_SYMBOL="mUSD"
export TOKEN_DECIMALS=18
export TOKEN_MINT_AMOUNT=1000000000000000000000000
export TOKEN_MINT_TO=$(cast wallet address --account mimosa-deployer)

forge script script/DeployDemoToken.s.sol:DeployDemoToken \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer \
  --broadcast
```

Initialize the hook-enabled pool:

```bash
export HOOK=0x892D42B22Ac103C682e43b945c81C4572E269000
export TOKEN_A=0x5B753e64d1B87fBC350e9adC1758eecf52c32Ae5
export TOKEN_B=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
export POOL_FEE=3000
export TICK_SPACING=60
export SQRT_PRICE_X96=79228162514264337593543950336

forge script script/InitSepoliaPool.s.sol:InitSepoliaPool \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer \
  --broadcast
```

Seed the pool with full-range liquidity:

```bash
export HOOK=0x892D42B22Ac103C682e43b945c81C4572E269000
export TOKEN_A=0x5B753e64d1B87fBC350e9adC1758eecf52c32Ae5
export TOKEN_B=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
export TOKEN_A_AMOUNT=1000000000000000000000
export TOKEN_B_AMOUNT=1000000000000000000
export POOL_FEE=3000
export TICK_SPACING=60
export SQRT_PRICE_X96=79228162514264337593543950336
export WRAP_WETH=true

forge script script/AddSepoliaLiquidity.s.sol:AddSepoliaLiquidity \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer \
  --broadcast
```

That script wraps the WETH leg if `WRAP_WETH=true`, approves Permit2 plus the Sepolia PositionManager, and mints a full-range position NFT into the initialized pool.

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
