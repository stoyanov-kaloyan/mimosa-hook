// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @dev Mirror interfaces for compile-time event selector computation.
///      Uses canonical ABI types (bytes32 for PoolId) so selectors match
///      the actual on-chain events without importing v4-core dependencies.
interface PoolManagerEvents {
    event Swap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );
}

interface MimosaHookEvents {
    event PolicyRegistered(
        uint256 indexed policyId,
        address indexed owner,
        bytes32 indexed poolId,
        uint160 triggerPrice,
        bool triggerAbove,
        bool zeroForOne,
        uint128 inputAmount,
        uint128 minOutput,
        uint64 expiry,
        uint128 executorTip
    );

    event PolicyExecuted(uint256 indexed policyId, int128 amount0, int128 amount1);
    event PolicyCancelled(uint256 indexed policyId, address indexed owner, uint256 refundedAmount);
    event PolicyExpired(uint256 indexed policyId, address indexed owner, uint256 refundedAmount);
}

/// @title MimosaReactive
/// @notice Reactive Network contract that monitors Uniswap v4 Swap events and
///         automatically triggers MimosaHook policy execution when price
///         thresholds are crossed.
///
/// @dev Deployed on Reactive Network. Subscribes to:
///   1. Swap events on the v4 PoolManager (to detect price changes)
///   2. Policy lifecycle events on MimosaHook (to track active policies)
///
///   When a Swap moves the price past a policy's trigger, the contract emits
///   a Callback event that Reactive Network delivers as a transaction to
///   MimosaCallback on the destination chain.
///
///   Policy state is reconstructed entirely from events — no RPC reads needed.
///   Iteration over policies per pool is gas-free inside the ReactVM.
contract MimosaReactive is IReactive, AbstractReactive {
    // ── Event Topics (set from .selector in constructor) ───────────

    uint256 internal immutable SWAP_TOPIC;
    uint256 internal immutable POLICY_REGISTERED_TOPIC;
    uint256 internal immutable POLICY_EXECUTED_TOPIC;
    uint256 internal immutable POLICY_CANCELLED_TOPIC;
    uint256 internal immutable POLICY_EXPIRED_TOPIC;

    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    // ── Deployment Configuration ─────────────────────────────────────

    uint256 public originChainId;
    address public poolManager;
    address public mimosaHook;
    address public callbackContract;
    address public owner;
    bool public hookSubscriptionsActive;
    bool public swapSubscriptionActive;

    // ── ReactVM Policy Tracking ──────────────────────────────────────

    struct TrackedPolicy {
        bytes32 poolId;
        uint160 triggerPrice;
        bool triggerAbove;
        bool active;
    }

    mapping(uint256 => TrackedPolicy) public trackedPolicies;

    /// @dev Active policy IDs per pool, with swap-and-pop for O(1) removal.
    mapping(bytes32 => uint256[]) internal _poolPolicies;
    mapping(uint256 => uint256) internal _policyIndex;

    // ── Events (ReactVM-local, for debugging / indexing) ─────────────

    event PolicyTracked(uint256 indexed policyId, bytes32 indexed poolId);
    event PolicyUntracked(uint256 indexed policyId);
    event SwapDetected(bytes32 indexed poolId, uint160 sqrtPriceX96);
    event PolicyTriggered(uint256 indexed policyId, uint160 sqrtPriceX96);
    event HookSubscriptionsActivated();
    event SwapSubscriptionActivated();

    error Unauthorized();
    error HookSubscriptionsAlreadyActive();
    error SwapSubscriptionAlreadyActive();

    constructor(uint256 _originChainId, address _poolManager, address _mimosaHook, address _callbackContract) payable {
        // Derive event topic hashes from mirror interface selectors.
        // This avoids hardcoded hex strings while keeping the code verifiable.
        SWAP_TOPIC = uint256(PoolManagerEvents.Swap.selector);
        POLICY_REGISTERED_TOPIC = uint256(MimosaHookEvents.PolicyRegistered.selector);
        POLICY_EXECUTED_TOPIC = uint256(MimosaHookEvents.PolicyExecuted.selector);
        POLICY_CANCELLED_TOPIC = uint256(MimosaHookEvents.PolicyCancelled.selector);
        POLICY_EXPIRED_TOPIC = uint256(MimosaHookEvents.PolicyExpired.selector);

        originChainId = _originChainId;
        poolManager = _poolManager;
        mimosaHook = _mimosaHook;
        callbackContract = _callbackContract;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Activate origin-chain subscriptions after deployment.
    /// @dev Done post-deploy instead of in the constructor because the Reactive
    ///      system contract can reject subscriptions from contracts still being created.
    function activateHookSubscriptions() external rnOnly onlyOwner {
        if (hookSubscriptionsActive) revert HookSubscriptionsAlreadyActive();
        // 2. Policy lifecycle events on MimosaHook
        service.subscribe(originChainId, mimosaHook, POLICY_REGISTERED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(originChainId, mimosaHook, POLICY_EXECUTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(originChainId, mimosaHook, POLICY_CANCELLED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(originChainId, mimosaHook, POLICY_EXPIRED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        hookSubscriptionsActive = true;
        emit HookSubscriptionsActivated();
    }

    function activateSwapSubscription() external rnOnly onlyOwner {
        if (swapSubscriptionActive) revert SwapSubscriptionAlreadyActive();
        service.subscribe(originChainId, poolManager, SWAP_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        swapSubscriptionActive = true;
        emit SwapSubscriptionActivated();
    }

    function activateSubscriptions() external rnOnly onlyOwner {
        if (!hookSubscriptionsActive) {
            this.activateHookSubscriptions();
        }
        if (!swapSubscriptionActive) {
            this.activateSwapSubscription();
        }
    }

    // ── IReactive ────────────────────────────────────────────────────

    /// @notice Entry point called by Reactive Network for every subscribed event.
    function react(LogRecord calldata log) external vmOnly {
        uint256 topic = log.topic_0;
        if (topic == POLICY_REGISTERED_TOPIC) {
            _onPolicyRegistered(log);
        } else if (topic == POLICY_EXECUTED_TOPIC || topic == POLICY_CANCELLED_TOPIC || topic == POLICY_EXPIRED_TOPIC) {
            _onPolicyRemoved(log);
        } else if (topic == SWAP_TOPIC) {
            _onSwap(log);
        }
    }

    // ── Internal Handlers ────────────────────────────────────────────

    function _onPolicyRegistered(LogRecord calldata log) internal {
        uint256 policyId = log.topic_1;

        // Idempotent: skip if already tracked (duplicate event delivery)
        if (trackedPolicies[policyId].active) return;

        bytes32 poolId = bytes32(log.topic_3);

        // Decode non-indexed fields: triggerPrice, triggerAbove, ...
        (uint160 triggerPrice, bool triggerAbove,,,,,) =
            abi.decode(log.data, (uint160, bool, bool, uint128, uint128, uint64, uint128));

        trackedPolicies[policyId] =
            TrackedPolicy({poolId: poolId, triggerPrice: triggerPrice, triggerAbove: triggerAbove, active: true});

        _addPolicy(poolId, policyId);
        emit PolicyTracked(policyId, poolId);
    }

    function _onPolicyRemoved(LogRecord calldata log) internal {
        uint256 policyId = log.topic_1;
        TrackedPolicy storage policy = trackedPolicies[policyId];

        if (policy.active) {
            policy.active = false;
            _removePolicy(policy.poolId, policyId);
            emit PolicyUntracked(policyId);
        }
    }

    function _onSwap(LogRecord calldata log) internal {
        bytes32 poolId = bytes32(log.topic_1);

        // Decode sqrtPriceX96 (3rd data field) from Swap event
        (,, uint160 sqrtPriceX96,,,) = abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));

        emit SwapDetected(poolId, sqrtPriceX96);

        // Check every active policy for this pool
        uint256[] storage ids = _poolPolicies[poolId];
        for (uint256 i; i < ids.length; ++i) {
            uint256 policyId = ids[i];
            TrackedPolicy storage policy = trackedPolicies[policyId];

            bool triggered;
            if (policy.triggerAbove) {
                triggered = sqrtPriceX96 >= policy.triggerPrice;
            } else {
                triggered = sqrtPriceX96 <= policy.triggerPrice;
            }

            if (triggered) {
                emit PolicyTriggered(policyId, sqrtPriceX96);

                // Encode callback: first arg (address(0)) is replaced by
                // Reactive Network with the ReactVM ID at delivery time.
                bytes memory payload = abi.encodeWithSignature("executeCallback(address,uint256)", address(0), policyId);

                emit Callback(originChainId, callbackContract, CALLBACK_GAS_LIMIT, payload);
            }
        }
    }

    // ── Policy Index (swap-and-pop) ──────────────────────────────────

    function _addPolicy(bytes32 poolId, uint256 policyId) internal {
        _policyIndex[policyId] = _poolPolicies[poolId].length;
        _poolPolicies[poolId].push(policyId);
    }

    function _removePolicy(bytes32 poolId, uint256 policyId) internal {
        uint256[] storage arr = _poolPolicies[poolId];
        uint256 index = _policyIndex[policyId];
        uint256 lastIndex = arr.length - 1;
        if (index != lastIndex) {
            uint256 lastId = arr[lastIndex];
            arr[index] = lastId;
            _policyIndex[lastId] = index;
        }
        arr.pop();
        delete _policyIndex[policyId];
    }

    // ── View Helpers (for testing / debugging) ───────────────────────

    function getPoolPolicies(bytes32 poolId) external view returns (uint256[] memory) {
        return _poolPolicies[poolId];
    }

    function getPoolPoliciesCount(bytes32 poolId) external view returns (uint256) {
        return _poolPolicies[poolId].length;
    }
}
