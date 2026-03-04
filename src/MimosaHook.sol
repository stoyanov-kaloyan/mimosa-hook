// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @title MimosaHook
/// @notice Event-driven automation primitive for Uniswap v4 pools.
///         Stores price-threshold policies and executes swaps atomically when
///         trigger conditions are satisfied. Designed to be called by Reactive
///         Network but permissionlessly executable by anyone.
/// @dev Supports multiple v4 pools via afterInitialize. Policies are funded
///      by pre-depositing tokens. Execution validates price on-chain, preventing
///      trust assumptions on the caller.
contract MimosaHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice Minimal policy
    /// one condition, one action, one execution.
    struct Policy {
        address owner; // creator & output recipient
        PoolId poolId; // which pool this policy targets
        uint160 triggerPrice; // sqrtPriceX96 threshold
        bool triggerAbove; // true ⇒ execute when price ≥ trigger
        bool zeroForOne; // swap direction (token0→token1 or vice-versa)
        uint128 inputAmount; // exact-input amount for the swap
        uint128 minOutput; // minimum acceptable output (slippage protection, 0 = no limit)
        bool executed; // double-execution guard
    }

    /// @notice Registered pools (populated via afterInitialize)
    mapping(PoolId => PoolKey) internal _poolKeys;
    mapping(PoolId => bool) public poolInitialized;

    /// @notice Policy registry.  policyId -> Policy
    mapping(uint256 => Policy) public policies;
    uint256 public nextPolicyId;

    /// @notice Pre-deposited token balances.  user -> currency -> amount
    mapping(address => mapping(Currency => uint256)) public deposits;

    event PolicyRegistered(
        uint256 indexed policyId,
        address indexed owner,
        uint160 triggerPrice,
        bool triggerAbove,
        bool zeroForOne,
        uint128 inputAmount,
        uint128 minOutput
    );
    event PolicyExecuted(uint256 indexed policyId, int128 amount0, int128 amount1);
    event PolicyCancelled(uint256 indexed policyId, address indexed owner, uint128 refundedAmount);
    event PoolAdded(PoolId indexed poolId);
    event Deposited(address indexed user, Currency indexed currency, uint256 amount);
    event Withdrawn(address indexed user, Currency indexed currency, uint256 amount);

    error PoolNotInitialized();
    error PolicyAlreadyExecuted();
    error PolicyDoesNotExist();
    error PolicyNotOwner();
    error TriggerConditionNotMet();
    error InsufficientDeposit();
    error InvalidAmount();
    error OnlyPoolManager();
    error TransferFromFailed();
    error SlippageExceeded();

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // capture PoolKey
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId id = key.toId();
        _poolKeys[id] = key;
        poolInitialized[id] = true;
        emit PoolAdded(id);
        return this.afterInitialize.selector;
    }

    /// @notice Deposit ERC-20 tokens (requires prior approval) or native ETH.
    function deposit(Currency currency, uint128 amount) external payable {
        if (amount == 0) revert InvalidAmount();

        if (currency.isAddressZero()) {
            require(msg.value == amount, "Incorrect ETH");
        } else {
            _safeTransferFrom(Currency.unwrap(currency), msg.sender, address(this), amount);
        }

        deposits[msg.sender][currency] += amount;
        emit Deposited(msg.sender, currency, amount);
    }

    /// @notice Withdraw previously deposited tokens.
    function withdraw(Currency currency, uint128 amount) external {
        require(deposits[msg.sender][currency] >= amount, "Insufficient balance");
        deposits[msg.sender][currency] -= amount;

        currency.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, currency, amount);
    }

    /// @notice Create a policy.  Caller must have deposited enough of the
    ///         input currency beforehand.  The deposit is reserved immediately.
    /// @param poolId The pool this policy targets (must have been initialized with this hook).
    /// @return policyId Sequential identifier for the new policy.
    function registerPolicy(
        PoolId poolId,
        uint160 triggerPrice,
        bool triggerAbove,
        bool zeroForOne,
        uint128 inputAmount,
        uint128 minOutput
    ) external returns (uint256 policyId) {
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        if (inputAmount == 0) revert InvalidAmount();

        PoolKey memory key = _poolKeys[poolId];
        // Determine which currency the swap consumes
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        if (deposits[msg.sender][inputCurrency] < inputAmount) revert InsufficientDeposit();

        // Reserve tokens
        deposits[msg.sender][inputCurrency] -= inputAmount;

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            owner: msg.sender,
            poolId: poolId,
            triggerPrice: triggerPrice,
            triggerAbove: triggerAbove,
            zeroForOne: zeroForOne,
            inputAmount: inputAmount,
            minOutput: minOutput,
            executed: false
        });

        emit PolicyRegistered(policyId, msg.sender, triggerPrice, triggerAbove, zeroForOne, inputAmount, minOutput);
    }

    /// @notice Cancel an unexecuted policy and reclaim the reserved input tokens.
    /// @param policyId The policy to cancel. Only the policy owner may cancel.
    function cancelPolicy(uint256 policyId) external {
        Policy storage policy = policies[policyId];
        if (policy.owner == address(0)) revert PolicyDoesNotExist();
        if (policy.owner != msg.sender) revert PolicyNotOwner();
        if (policy.executed) revert PolicyAlreadyExecuted();

        // Mark as executed to prevent double-cancel
        policy.executed = true;

        // Refund the reserved tokens back to the owner's deposit balance
        PoolKey memory key = _poolKeys[policy.poolId];
        Currency inputCurrency = policy.zeroForOne ? key.currency0 : key.currency1;
        uint128 refund = policy.inputAmount;
        deposits[msg.sender][inputCurrency] += refund;

        emit PolicyCancelled(policyId, msg.sender, refund);
    }

    /// @notice Execute a policy if its trigger condition is currently met.
    ///         Callable by anyone (Reactive Network, keeper, EOA, …).
    ///         Re-validates the price condition on-chain before executing.
    /// @param policyId The policy to execute.
    function executePolicy(uint256 policyId) external {
        Policy storage policy = policies[policyId];
        if (policy.owner == address(0)) revert PolicyDoesNotExist();
        if (policy.executed) revert PolicyAlreadyExecuted();

        //  1. Read current pool price
        (uint160 currentPrice,,,) = poolManager.getSlot0(policy.poolId);

        //  2. Validate trigger condition ON-CHAIN
        if (policy.triggerAbove) {
            if (currentPrice < policy.triggerPrice) revert TriggerConditionNotMet();
        } else {
            if (currentPrice > policy.triggerPrice) revert TriggerConditionNotMet();
        }

        //  3. Mark executed BEFORE external call (CEI)
        policy.executed = true;

        //  4. Execute swap via PoolManager unlock -> callback
        bytes memory result = poolManager.unlock(abi.encode(policyId));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        emit PolicyExecuted(policyId, delta.amount0(), delta.amount1());
    }

    /// @dev Called by PoolManager during unlock().  Performs the swap and settles
    ///      all currency deltas atomically.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        uint256 policyId = abi.decode(data, (uint256));
        Policy memory policy = policies[policyId];
        PoolKey memory key = _poolKeys[policy.poolId];

        // Perform swap
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: policy.zeroForOne,
                amountSpecified: -int256(uint256(policy.inputAmount)), // exact input
                sqrtPriceLimitX96: policy.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Slippage check: ensure output meets the user's minimum
        if (policy.minOutput > 0) {
            // Output is the positive delta (what the hook receives from the pool)
            int128 outputDelta = policy.zeroForOne ? delta.amount1() : delta.amount0();
            if (outputDelta < 0 || uint128(outputDelta) < policy.minOutput) {
                revert SlippageExceeded();
            }
        }

        // Settle every non-zero delta
        _settleDelta(key.currency0, delta.amount0(), policy.owner);
        _settleDelta(key.currency1, delta.amount1(), policy.owner);

        return abi.encode(delta);
    }

    /// @dev Settle a single currency delta.
    ///      Negative → we owe the pool (pay from hook holdings).
    ///      Positive → pool owes us  (take to policy owner).
    function _settleDelta(Currency currency, int128 deltaAmount, address recipient) internal {
        if (deltaAmount < 0) {
            uint256 amount = uint256(uint128(-deltaAmount));
            if (currency.isAddressZero()) {
                poolManager.settle{value: amount}();
            } else {
                poolManager.sync(currency);
                currency.transfer(address(poolManager), amount);
                poolManager.settle();
            }
        } else if (deltaAmount > 0) {
            uint256 amount = uint256(uint128(deltaAmount));
            poolManager.take(currency, recipient, amount);
        }
    }

    /// @notice Read the current sqrtPriceX96 of a registered pool.
    function getCurrentPrice(PoolId poolId) external view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
    }

    /// @notice Retrieve the stored PoolKey for an initialized pool.
    function getPoolKey(PoolId poolId) external view returns (PoolKey memory) {
        return _poolKeys[poolId];
    }

    /// @dev Safe ERC-20 transferFrom that reverts on failure or missing return data.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFromFailed();
        }
    }

    // Allow receiving ETH for native-currency pools
    receive() external payable {}
}
