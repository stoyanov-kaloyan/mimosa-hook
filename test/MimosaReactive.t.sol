// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {MimosaHook} from "../src/MimosaHook.sol";
import {MimosaReactive, PoolManagerEvents, MimosaHookEvents} from "../src/MimosaReactive.sol";
import {MimosaCallback} from "../src/MimosaCallback.sol";

/// @title MimosaReactiveTest
/// @notice Tests for the Reactive Network integration layer:
///         MimosaReactive (event monitoring + callback emission) and
///         MimosaCallback (destination-chain callback receiver).
contract MimosaReactiveTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    MimosaReactive public reactive;
    MimosaCallback public callback;
    MimosaHook public hook;

    PoolKey poolKey;
    PoolId poolId;

    address policyOwner = makeAddr("policyOwner");
    address callbackProxy = makeAddr("callbackProxy");

    uint128 constant DEPOSIT_AMOUNT = 10e18;
    uint128 constant POLICY_AMOUNT = 0.1e18;
    int256 constant BIG_SWAP = -50e18;

    function setUp() public {
        // 1. Deploy v4 infrastructure
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // 2. Deploy MimosaHook at correct address
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        address hookAddr = address(uint160(type(uint160).max & clearAllHookPermissionsMask | flags));
        deployCodeTo("MimosaHook", abi.encode(manager), hookAddr);
        hook = MimosaHook(payable(hookAddr));

        // 3. Initialize pool
        (poolKey, poolId) = initPool(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);

        // 4. Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 50e18, salt: 0}),
            ZERO_BYTES
        );

        // 5. Fund policy owner
        MockERC20(Currency.unwrap(currency0)).mint(policyOwner, 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(policyOwner, 100e18);
        vm.startPrank(policyOwner);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // 6. Deploy MimosaReactive (in Forge, detectVm() sets vm=true → subscriptions skipped)
        reactive = new MimosaReactive(
            block.chainid,
            address(manager),
            address(hook),
            address(0xCAFE) // placeholder callback contract for unit tests
        );

        // 7. Deploy MimosaCallback (deployer = address(this) → rvm_id = address(this))
        callback = new MimosaCallback(address(hook), callbackProxy);
    }

    function test_reactive_tracksPolicyOnRegistered() public {
        bytes32 pId = PoolId.unwrap(poolId);

        _feedPolicyRegistered(42, pId, SQRT_PRICE_1_2, false);

        (bytes32 trackedPoolId, uint160 triggerPrice, bool triggerAbove, bool active) = reactive.trackedPolicies(42);
        assertEq(trackedPoolId, pId);
        assertEq(triggerPrice, SQRT_PRICE_1_2);
        assertFalse(triggerAbove);
        assertTrue(active);

        // Should be in the pool's active list
        assertEq(reactive.getPoolPoliciesCount(pId), 1);
        assertEq(reactive.getPoolPolicies(pId)[0], 42);
    }

    function test_reactive_tracksDuplicateIdempotent() public {
        bytes32 pId = PoolId.unwrap(poolId);

        _feedPolicyRegistered(42, pId, SQRT_PRICE_1_2, false);
        _feedPolicyRegistered(42, pId, SQRT_PRICE_1_2, false); // duplicate

        // Should still have only one entry
        assertEq(reactive.getPoolPoliciesCount(pId), 1);
    }

    function test_reactive_untracksPolicyOnExecuted() public {
        bytes32 pId = PoolId.unwrap(poolId);
        _feedPolicyRegistered(42, pId, SQRT_PRICE_1_2, false);

        _feedPolicyRemoved(42, uint256(MimosaHookEvents.PolicyExecuted.selector));

        (,,, bool active) = reactive.trackedPolicies(42);
        assertFalse(active);
        assertEq(reactive.getPoolPoliciesCount(pId), 0);
    }

    function test_reactive_untracksPolicyOnCancelled() public {
        bytes32 pId = PoolId.unwrap(poolId);
        _feedPolicyRegistered(42, pId, SQRT_PRICE_1_2, false);

        _feedPolicyRemoved(42, uint256(MimosaHookEvents.PolicyCancelled.selector));

        (,,, bool active) = reactive.trackedPolicies(42);
        assertFalse(active);
        assertEq(reactive.getPoolPoliciesCount(pId), 0);
    }

    function test_reactive_untracksPolicyOnExpired() public {
        bytes32 pId = PoolId.unwrap(poolId);
        _feedPolicyRegistered(42, pId, SQRT_PRICE_1_2, false);

        _feedPolicyRemoved(42, uint256(MimosaHookEvents.PolicyExpired.selector));

        (,,, bool active) = reactive.trackedPolicies(42);
        assertFalse(active);
    }

    function test_reactive_emitsCallbackOnSwap() public {
        bytes32 pId = PoolId.unwrap(poolId);

        // Register: trigger when price drops to/below SQRT_PRICE_1_2
        _feedPolicyRegistered(0, pId, SQRT_PRICE_1_2, false);

        // Simulate Swap with price below trigger
        IReactive.LogRecord memory log = _swapLog(pId, SQRT_PRICE_1_2 - 1);

        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasCallbackEvent(logs), "Should emit Callback event");
    }

    function test_reactive_noCallbackWhenConditionNotMet() public {
        bytes32 pId = PoolId.unwrap(poolId);

        // Register: trigger when price goes ABOVE SQRT_PRICE_2_1
        _feedPolicyRegistered(0, pId, SQRT_PRICE_2_1, true);

        // Swap event with price at 1:1 (below trigger)
        IReactive.LogRecord memory log = _swapLog(pId, SQRT_PRICE_1_1);

        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_hasCallbackEvent(logs), "Should NOT emit Callback event");
    }

    function test_reactive_multipleTriggersInOneSwap() public {
        bytes32 pId = PoolId.unwrap(poolId);

        // Two policies at different thresholds, both below current price
        _feedPolicyRegistered(0, pId, SQRT_PRICE_1_2, false);
        _feedPolicyRegistered(1, pId, SQRT_PRICE_1_4, false);

        // Swap drops price below both thresholds
        IReactive.LogRecord memory log = _swapLog(pId, SQRT_PRICE_1_4 - 1);

        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 callbackCount = _countCallbackEvents(logs);
        assertEq(callbackCount, 2, "Should emit 2 Callback events");
    }

    function test_reactive_triggerAbove() public {
        bytes32 pId = PoolId.unwrap(poolId);

        // Trigger when price goes above SQRT_PRICE_2_1
        _feedPolicyRegistered(0, pId, SQRT_PRICE_2_1, true);

        // Swap with price above trigger
        IReactive.LogRecord memory log = _swapLog(pId, SQRT_PRICE_2_1 + 1);

        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(_hasCallbackEvent(logs), "Should trigger above");
    }

    function test_reactive_ignoresUnrelatedPool() public {
        bytes32 pId = PoolId.unwrap(poolId);
        bytes32 otherPool = keccak256("otherPool");

        _feedPolicyRegistered(0, pId, SQRT_PRICE_1_2, false);

        // Swap on a DIFFERENT pool
        IReactive.LogRecord memory log = _swapLog(otherPool, SQRT_PRICE_1_2 - 1);

        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_hasCallbackEvent(logs), "Should not trigger for unrelated pool");
    }

    function test_callback_executesPolicy() public {
        // Setup: register a triggered policy
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        // Move price down on the real pool
        swap(poolKey, true, BIG_SWAP, ZERO_BYTES);

        // Simulate callback from the Callback Proxy
        // rvm_id = address(this) because this test contract deployed MimosaCallback
        vm.prank(callbackProxy);
        callback.executeCallback(address(this), policyId);

        assertTrue(hook.getPolicy(policyId).executed, "Policy should be executed via callback");
    }

    function test_callback_unauthorizedSenderReverts() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert("Authorized sender only");
        callback.executeCallback(address(this), 0);
    }

    function test_callback_wrongRvmIdReverts() public {
        address wrongRvm = makeAddr("wrongRvm");
        vm.prank(callbackProxy);
        vm.expectRevert("Authorized RVM ID only");
        callback.executeCallback(wrongRvm, 0);
    }

    function test_callback_failedExecutionDoesNotRevert() public {
        // Policy 999 doesn't exist — should NOT revert
        vm.prank(callbackProxy);
        callback.executeCallback(address(this), 999);
        // Test passes if no revert
    }

    function test_callback_emitsExecutionForwarded() public {
        vm.prank(callbackProxy);

        vm.expectEmit(true, false, false, true);
        emit MimosaCallback.ExecutionForwarded(999, false);

        callback.executeCallback(address(this), 999);
    }

    function test_endToEnd_reactive_triggers_callback() public {
        // 1. Register a real policy on MimosaHook
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        // 2. Feed the PolicyRegistered event to MimosaReactive
        _feedPolicyRegistered(policyId, PoolId.unwrap(poolId), SQRT_PRICE_1_2, false);

        // 3. Move the real pool price down
        swap(poolKey, true, BIG_SWAP, ZERO_BYTES);
        uint160 priceAfterSwap = hook.getCurrentPrice(poolId);
        assertLt(priceAfterSwap, SQRT_PRICE_1_2, "Price should be below trigger");

        // 4. Feed the Swap event to MimosaReactive
        IReactive.LogRecord memory swapLog = _swapLog(PoolId.unwrap(poolId), priceAfterSwap);

        vm.recordLogs();
        reactive.react(swapLog);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 5. Verify Callback was emitted
        assertTrue(_hasCallbackEvent(logs), "Reactive should emit Callback");

        // 6. Deliver the callback to MimosaCallback
        vm.prank(callbackProxy);
        callback.executeCallback(address(this), policyId);

        // 7. Verify the policy was executed on MimosaHook
        assertTrue(hook.getPolicy(policyId).executed, "Policy should be executed end-to-end");
    }

    function _feedPolicyRegistered(uint256 policyId, bytes32 pId, uint160 triggerPrice, bool triggerAbove) internal {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(hook),
            topic_0: uint256(MimosaHookEvents.PolicyRegistered.selector),
            topic_1: policyId,
            topic_2: uint256(uint160(policyOwner)),
            topic_3: uint256(pId),
            data: abi.encode(
                triggerPrice,
                triggerAbove,
                false, // zeroForOne
                POLICY_AMOUNT, // inputAmount
                uint128(0), // minOutput
                uint64(0), // expiry
                uint128(0) // executorTip
            ),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        reactive.react(log);
    }

    function _feedPolicyRemoved(uint256 policyId, uint256 eventTopic) internal {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(hook),
            topic_0: eventTopic,
            topic_1: policyId,
            topic_2: uint256(uint160(policyOwner)),
            topic_3: 0,
            data: abi.encode(int128(0), int128(0)), // minimal data
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        reactive.react(log);
    }

    function _swapLog(bytes32 pId, uint160 sqrtPriceX96) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: block.chainid,
            _contract: address(manager),
            topic_0: uint256(PoolManagerEvents.Swap.selector),
            topic_1: uint256(pId),
            topic_2: uint256(uint160(address(this))),
            topic_3: 0,
            data: abi.encode(int128(0), int128(0), sqrtPriceX96, uint128(0), int24(0), uint24(0)),
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _hasCallbackEvent(Vm.Log[] memory logs) internal pure returns (bool) {
        bytes32 callbackSig = IReactive.Callback.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == callbackSig) {
                return true;
            }
        }
        return false;
    }

    function _countCallbackEvents(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 callbackSig = IReactive.Callback.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == callbackSig) {
                ++count;
            }
        }
    }
}
