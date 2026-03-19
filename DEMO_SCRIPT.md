# Demo Script

This is a help script for helping me record the demo and keep track of useful commands

This is Mimosa, a Uniswap v4 hook that uses Reactive Network to automate trigger-based orders.
The demo is intentionally simple. I connect on Sepolia, pick a preset order, enter an amount, and create the order in a couple of clicks.
The frontend already knows the live pool, deployed hook, and trigger logic. Here I’m creating a sell-the-rally order against the live demo pool.
The input funds are deposited into the hook, the policy is registered on-chain, and the system waits for the pool price to cross the threshold.
When price crosses the trigger, the order becomes executable, and with active Reactive subscriptions it can be delivered automatically. The hook still re-checks the live price on-chain before it swaps.

## Notebook Appendix

### Environment

```bash
export ORIGIN_RPC=...
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/
export ORIGIN_CHAIN_ID=11155111
export POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
export CALLBACK_PROXY=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA
export HOOK=0x892D42B22Ac103C682e43b945c81C4572E269000
export CALLBACK=0x673e2D03864C2c2Eb819646c7DDa3B5047aE627d
export REACTIVE=0xe407a500F9c4948a53F7d51F025F74F62b7CE801
export DEMO_TOKEN=0x5B753e64d1B87fBC350e9adC1758eecf52c32Ae5
export WETH=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
export DEMO_POOL_ID=0xf0e88c3617e824a1f559635edca7b5a68215c4e80d60e15903f144c8c9f2a679
```

### Run The Frontend

```bash
cd /home/kale/repos/mimosa-hook/app
npm run dev
```

### Check Wallet And Token Balances

App wallet:

```bash
cast wallet address --account mimosa-deployer
```

Sepolia ETH balance:

```bash
cast balance 0x10415EDc7cB9aD10fFFEB371d80cE0ca6D26dA5C --rpc-url "$ORIGIN_RPC"
```

Sepolia WETH balance:

```bash
cast call $WETH \
  "balanceOf(address)(uint256)" \
  0x10415EDc7cB9aD10fFFEB371d80cE0ca6D26dA5C \
  --rpc-url "$ORIGIN_RPC"
```

Sepolia demo token balance:

```bash
cast call $DEMO_TOKEN \
  "balanceOf(address)(uint256)" \
  0x10415EDc7cB9aD10fFFEB371d80cE0ca6D26dA5C \
  --rpc-url "$ORIGIN_RPC"
```

Reactive native balance:

```bash
cast balance $REACTIVE --rpc-url "$REACTIVE_RPC"
```

### Wrap More Sepolia ETH Into WETH

Wrap `0.1 ETH`:

```bash
cast send $WETH \
  "deposit()" \
  --value 100000000000000000 \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer
```

Wrap `0.2 ETH`:

```bash
cast send $WETH \
  "deposit()" \
  --value 200000000000000000 \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer
```

Wrap `0.5 ETH`:

```bash
cast send $WETH \
  "deposit()" \
  --value 500000000000000000 \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer
```

### Fund The Reactive Contract

Send `1 lREACT`:

```bash
cast send $REACTIVE \
  --value 1000000000000000000 \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

Send `0.2 lREACT`:

```bash
cast send $REACTIVE \
  --value 200000000000000000 \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

### Activate Or Repair Reactive Subscriptions

Activate hook event subscriptions:

```bash
cast send $REACTIVE \
  "activateHookSubscriptions()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

Activate swap subscription:

```bash
cast send $REACTIVE \
  "activateSwapSubscription()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

Repair subscriptions after refueling:

```bash
cast send $REACTIVE \
  "repairSubscriptions()" \
  --rpc-url "$REACTIVE_RPC" \
  --account mimosa-deployer
```

### Verify The Demo Pool Is Registered

```bash
cast call $HOOK \
  "poolInitialized(bytes32)(bool)" \
  $DEMO_POOL_ID \
  --rpc-url "$ORIGIN_RPC"
```

```bash
cast call $HOOK \
  "getCurrentPrice(bytes32)(uint160)" \
  $DEMO_POOL_ID \
  --rpc-url "$ORIGIN_RPC"
```

### Price Spike Commands

Use these after creating a `Sell The Rally` order in the UI. `ZERO_FOR_ONE=false` pushes the demo pool price upward.

Spike with `0.05 WETH`:

```bash
cd /home/kale/repos/mimosa-hook
export SWAP_AMOUNT=50000000000000000
export ZERO_FOR_ONE=false

forge script script/SpikeSepoliaPrice.s.sol:SpikeSepoliaPrice \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer \
  --broadcast
```

Spike with `0.1 WETH`:

```bash
cd /home/kale/repos/mimosa-hook
export SWAP_AMOUNT=100000000000000000
export ZERO_FOR_ONE=false

forge script script/SpikeSepoliaPrice.s.sol:SpikeSepoliaPrice \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer \
  --broadcast
```

Spike with `0.5 WETH`:

```bash
cd /home/kale/repos/mimosa-hook
export SWAP_AMOUNT=500000000000000000
export ZERO_FOR_ONE=false

forge script script/SpikeSepoliaPrice.s.sol:SpikeSepoliaPrice \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer \
  --broadcast
```

### Frontend Demo Flow

1. Open the app on Sepolia.
2. Choose `Sell The Rally`.
3. Enter an amount of `mUSD`.
4. Keep the preset `5%` trigger band.
5. Create the order.
6. Run one of the price spike commands above.
7. Refresh the app and compare `Live Price` vs `Trigger Price`.
8. If the order is `Ready`, either wait for automation or click `Execute`.

### Manual Fallback If Auto-Execution Is Delayed

Use the UI `Execute` button, or call the hook directly if needed:

```bash
cast send $HOOK \
  "executePolicy(uint256)" \
  0 \
  --rpc-url "$ORIGIN_RPC" \
  --account mimosa-deployer
```

Replace `0` with the actual policy id.
