// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {MimosaHook} from "../src/MimosaHook.sol";

/// @title MimosaHookTest
/// @notice End-to-end tests demonstrating the event-driven automation primitive.
///         Follows the demo narrative:
///           1. Policy registered
///           2. Condition not met -> revert
///           3. Price moves (external event)
///           4. Reactive triggers execution
///           5. Swap executes
///           6. Policy marked executed
contract MimosaHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MimosaHook public hook;

    PoolKey poolKey;
    PoolId poolId;

    // Actors
    address policyOwner = makeAddr("policyOwner");

    // Constants
    uint128 constant DEPOSIT_AMOUNT = 10e18;
    uint128 constant POLICY_AMOUNT = 0.1e18;
    int256 constant BIG_SWAP = -50e18; // exact-input to move price

    function setUp() public {
        // 1. Deploy manager & routers
        deployFreshManagerAndRouters();

        // 2. Deploy two ERC-20 test tokens & approve routers
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // 3. Deploy MimosaHook at address with AFTER_INITIALIZE bit
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        address hookAddr = address(uint160(type(uint160).max & clearAllHookPermissionsMask | flags));
        deployCodeTo("MimosaHook", abi.encode(manager), hookAddr);
        hook = MimosaHook(payable(hookAddr));

        // 4. Initialize pool at 1:1 price
        (poolKey, poolId) = initPool(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1);
        assertTrue(hook.poolInitialized(poolId), "pool should be initialized after init");

        // 5. Add moderate liquidity — enough for swaps but low enough that
        //    a 50e18 swap meaningfully moves the price past trigger thresholds.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 50e18, salt: 0}),
            ZERO_BYTES
        );

        // 6. Fund policy owner with tokens & approve hook
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token0.mint(policyOwner, 100e18);
        token1.mint(policyOwner, 100e18);

        vm.startPrank(policyOwner);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Full demo narrative.
    ///   Policy: "When price drops to SQRT_PRICE_1_2, buy token0 with token1."
    ///   Swap direction is *opposite* to price movement so there is always room.
    function test_fullDemoFlow() public {
        // Step 1: Deposit token1 & register policy
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        assertEq(hook.deposits(policyOwner, currency1), DEPOSIT_AMOUNT);

        // zeroForOne=false => swap token1->token0 (buy token0 when cheap)
        uint256 policyId = hook.registerPolicy({
            poolId: poolId,
            triggerPrice: SQRT_PRICE_1_2, // fire when price <= 1:2
            triggerAbove: false,
            zeroForOne: false,
            inputAmount: POLICY_AMOUNT,
            minOutput: 0,
            expiry: 0,
            executorTip: 0
        });
        vm.stopPrank();

        // Verify storage
        MimosaHook.Policy memory p = hook.getPolicy(policyId);
        assertEq(p.owner, policyOwner);
        assertEq(PoolId.unwrap(p.poolId), PoolId.unwrap(poolId));
        assertEq(p.triggerPrice, SQRT_PRICE_1_2);
        assertFalse(p.triggerAbove);
        assertFalse(p.zeroForOne);
        assertEq(p.inputAmount, POLICY_AMOUNT);
        assertEq(p.minOutput, 0);
        assertEq(p.expiry, 0);
        assertEq(p.executorTip, 0);
        assertFalse(p.executed);

        // Step 2: Condition NOT met -> revert
        vm.expectRevert(MimosaHook.TriggerConditionNotMet.selector);
        hook.executePolicy(policyId);

        // Step 3: Large sell pushes price down past trigger
        _movePriceDown();
        uint160 priceAfter = hook.getCurrentPrice(poolId);
        assertLt(priceAfter, SQRT_PRICE_1_2, "Price should be below trigger");

        // Step 4: Execute policy (permissionless — anyone can trigger)
        uint256 token0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(policyOwner);

        hook.executePolicy(policyId);

        // Step 5: Policy owner received output token (token0)
        uint256 token0After = MockERC20(Currency.unwrap(currency0)).balanceOf(policyOwner);
        assertGt(token0After, token0Before, "Policy owner should have received token0");

        // Step 6: Policy marked executed
        assertTrue(hook.getPolicy(policyId).executed, "Policy should be marked executed");

        // Step 7: Double execution reverts
        vm.expectRevert(MimosaHook.PolicyAlreadyExecuted.selector);
        hook.executePolicy(policyId);
    }

    function test_deposit_and_withdraw() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency0, 1e18);
        assertEq(hook.deposits(policyOwner, currency0), 1e18);

        hook.withdraw(currency0, 0.5e18);
        assertEq(hook.deposits(policyOwner, currency0), 0.5e18);
        vm.stopPrank();
    }

    function test_registerPolicy_insufficientDeposit() public {
        vm.prank(policyOwner);
        vm.expectRevert(MimosaHook.InsufficientDeposit.selector);
        hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, true, POLICY_AMOUNT, 0, 0, 0);
    }

    function test_registerPolicy_zeroAmount() public {
        vm.prank(policyOwner);
        vm.expectRevert(MimosaHook.InvalidAmount.selector);
        hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, true, 0, 0, 0, 0);
    }

    function test_executePolicy_nonexistent() public {
        vm.expectRevert(MimosaHook.PolicyDoesNotExist.selector);
        hook.executePolicy(999);
    }

    function test_executePolicy_permissionless() public {
        // Deposit token1, buy token0 when price drops
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        _movePriceDown();

        // Anyone can call
        address random = makeAddr("random");
        vm.prank(random);
        hook.executePolicy(policyId);

        assertTrue(hook.getPolicy(policyId).executed);
    }

    function test_triggerAbove_direction() public {
        // Policy: "When price goes ABOVE SQRT_PRICE_2_1, sell token0 for token1."
        vm.startPrank(policyOwner);
        hook.deposit(currency0, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy({
            poolId: poolId,
            triggerPrice: SQRT_PRICE_2_1,
            triggerAbove: true,
            zeroForOne: true, // sell token0 when price is high
            inputAmount: POLICY_AMOUNT,
            minOutput: 0,
            expiry: 0,
            executorTip: 0
        });
        vm.stopPrank();

        // Condition not met (price = 1:1 < 2:1)
        vm.expectRevert(MimosaHook.TriggerConditionNotMet.selector);
        hook.executePolicy(policyId);

        // Push price up
        _movePriceUp();
        uint160 priceAfter = hook.getCurrentPrice(poolId);
        assertGt(priceAfter, SQRT_PRICE_2_1, "Price should be above trigger");

        // Execution succeeds
        hook.executePolicy(policyId);
        assertTrue(hook.getPolicy(policyId).executed);
    }

    function test_getCurrentPrice() public view {
        uint160 price = hook.getCurrentPrice(poolId);
        assertEq(price, SQRT_PRICE_1_1, "Initial price should be 1:1");
    }

    function test_multiplePolicies_differentThresholds() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);

        // A: triggers at SQRT_PRICE_1_2 (moderate drop)
        uint256 idA = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        // B: triggers at SQRT_PRICE_1_4 (large drop -- may not be reached)
        uint256 idB = hook.registerPolicy(poolId, SQRT_PRICE_1_4, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        _movePriceDown();
        uint160 price = hook.getCurrentPrice(poolId);

        // A should be executable
        if (price <= SQRT_PRICE_1_2) {
            hook.executePolicy(idA);
            assertTrue(hook.getPolicy(idA).executed, "Policy A should execute");
        }

        // B may not be reachable
        if (price > SQRT_PRICE_1_4) {
            vm.expectRevert(MimosaHook.TriggerConditionNotMet.selector);
            hook.executePolicy(idB);
        }
    }

    function _movePriceDown() internal {
        swap(poolKey, true, BIG_SWAP, ZERO_BYTES);
    }

    function _movePriceUp() internal {
        swap(poolKey, false, BIG_SWAP, ZERO_BYTES);
    }

    function test_cancelPolicy_refundsDeposit() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);

        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);

        // Deposit was reduced by POLICY_AMOUNT
        uint256 depositAfterRegister = hook.deposits(policyOwner, currency1);
        assertEq(depositAfterRegister, DEPOSIT_AMOUNT - POLICY_AMOUNT);

        // Cancel → tokens return to deposit balance
        hook.cancelPolicy(policyId);

        uint256 depositAfterCancel = hook.deposits(policyOwner, currency1);
        assertEq(depositAfterCancel, DEPOSIT_AMOUNT, "Full deposit should be restored");

        // Policy is marked executed (preventing re-cancel / re-execute)
        assertTrue(hook.getPolicy(policyId).executed, "Cancelled policy should be marked executed");
        vm.stopPrank();
    }

    function test_cancelPolicy_notOwner() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency0, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, true, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(MimosaHook.PolicyNotOwner.selector);
        hook.cancelPolicy(policyId);
    }

    function test_cancelPolicy_alreadyExecuted() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        _movePriceDown();
        hook.executePolicy(policyId);

        vm.prank(policyOwner);
        vm.expectRevert(MimosaHook.PolicyAlreadyExecuted.selector);
        hook.cancelPolicy(policyId);
    }

    function test_cancelPolicy_nonexistent() public {
        vm.expectRevert(MimosaHook.PolicyDoesNotExist.selector);
        hook.cancelPolicy(999);
    }

    function test_cancelPolicy_thenWithdraw() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);

        // Cancel to reclaim, then withdraw everything
        hook.cancelPolicy(policyId);
        hook.withdraw(currency1, uint128(DEPOSIT_AMOUNT));

        assertEq(hook.deposits(policyOwner, currency1), 0, "Deposit should be zero after full withdraw");
        assertEq(
            MockERC20(Currency.unwrap(currency1)).balanceOf(policyOwner),
            100e18, // original minted amount fully returned
            "Token balance should be fully restored"
        );
        vm.stopPrank();
    }

    function test_registerPolicy_poolNotInitialized() public {
        // Use a PoolId for a pool that was never initialized on our hook
        PoolId fakePoolId = PoolId.wrap(keccak256("nonexistent"));

        vm.prank(policyOwner);
        vm.expectRevert(MimosaHook.PoolNotInitialized.selector);
        hook.registerPolicy(fakePoolId, SQRT_PRICE_1_2, false, true, POLICY_AMOUNT, 0, 0, 0);
    }

    function test_multiPool() public {
        // Initialize a second pool with a different fee tier
        (PoolKey memory key2, PoolId poolId2) =
            initPool(currency0, currency1, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        assertTrue(hook.poolInitialized(poolId2), "Second pool should be initialized");

        // Add liquidity to pool 2
        modifyLiquidityRouter.modifyLiquidity(
            key2,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 50e18, salt: 0}),
            ZERO_BYTES
        );

        // Register a policy on pool 2
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 pId = hook.registerPolicy(poolId2, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        // Policy should reference pool 2
        assertEq(PoolId.unwrap(hook.getPolicy(pId).poolId), PoolId.unwrap(poolId2), "Policy should reference pool 2");

        // Move price on pool 2 only
        swap(key2, true, BIG_SWAP, ZERO_BYTES);
        uint160 price2 = hook.getCurrentPrice(poolId2);
        assertLt(price2, SQRT_PRICE_1_2, "Pool 2 price should be below trigger");

        // Original pool price should be unaffected
        uint160 price1 = hook.getCurrentPrice(poolId);
        assertEq(price1, SQRT_PRICE_1_1, "Pool 1 price should be unchanged");

        // Execute policy on pool 2
        hook.executePolicy(pId);
        assertTrue(hook.getPolicy(pId).executed, "Policy on pool 2 should be executed");
    }

    function test_slippage_protection_passes() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);

        // Set a very low minOutput that should easily be met
        uint256 policyId = hook.registerPolicy({
            poolId: poolId,
            triggerPrice: SQRT_PRICE_1_2,
            triggerAbove: false,
            zeroForOne: false,
            inputAmount: POLICY_AMOUNT,
            minOutput: 1, // extremely low, will always pass
            expiry: 0,
            executorTip: 0
        });
        vm.stopPrank();

        _movePriceDown();

        uint256 token0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(policyOwner);
        hook.executePolicy(policyId);
        uint256 token0After = MockERC20(Currency.unwrap(currency0)).balanceOf(policyOwner);
        assertGt(token0After, token0Before, "Should receive output tokens");
    }

    function test_slippage_protection_reverts() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);

        // Set an outrageously high minOutput that can never be met
        uint256 policyId = hook.registerPolicy({
            poolId: poolId,
            triggerPrice: SQRT_PRICE_1_2,
            triggerAbove: false,
            zeroForOne: false,
            inputAmount: POLICY_AMOUNT,
            minOutput: type(uint128).max, // impossible to achieve
            expiry: 0,
            executorTip: 0
        });
        vm.stopPrank();

        _movePriceDown();

        // Execution should revert inside the unlock callback (SlippageExceeded),
        // which propagates up through the PoolManager.
        vm.expectRevert();
        hook.executePolicy(policyId);
    }

    function test_deposit_and_withdraw_nativeETH() public {
        Currency ethCurrency = Currency.wrap(address(0));
        vm.deal(policyOwner, 10 ether);

        vm.startPrank(policyOwner);
        hook.deposit{value: 1 ether}(ethCurrency, 1e18);
        assertEq(hook.deposits(policyOwner, ethCurrency), 1e18, "ETH deposit recorded");

        uint256 balBefore = policyOwner.balance;
        hook.withdraw(ethCurrency, 0.5e18);
        assertEq(hook.deposits(policyOwner, ethCurrency), 0.5e18, "Half withdrawn");
        assertEq(policyOwner.balance, balBefore + 0.5e18, "ETH returned");
        vm.stopPrank();
    }

    function test_deposit_nativeETH_incorrectValue() public {
        Currency ethCurrency = Currency.wrap(address(0));
        vm.deal(policyOwner, 10 ether);

        vm.prank(policyOwner);
        vm.expectRevert("Incorrect ETH");
        hook.deposit{value: 0.5 ether}(ethCurrency, 1e18);
    }

    function test_activePolicy_index() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 id0 = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        uint256 id1 = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        uint256 id2 = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        // All 3 should be active
        uint256[] memory active = hook.getActivePolicies(poolId);
        assertEq(active.length, 3);
        assertEq(hook.getActivePoliciesCount(poolId), 3);

        // Cancel id1 (middle) — swap-and-pop should keep id0 and id2
        vm.prank(policyOwner);
        hook.cancelPolicy(id1);
        active = hook.getActivePolicies(poolId);
        assertEq(active.length, 2);

        // Move price down and execute id0
        _movePriceDown();
        hook.executePolicy(id0);
        active = hook.getActivePolicies(poolId);
        assertEq(active.length, 1);
        assertEq(active[0], id2, "Only id2 should remain");
    }

    function test_expiry_revertsWhenExpired() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint64 expiryTime = uint64(block.timestamp + 1 hours);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, expiryTime, 0);
        vm.stopPrank();

        _movePriceDown();

        // Warp past expiry
        vm.warp(expiryTime + 1);
        vm.expectRevert(MimosaHook.PolicyIsExpired.selector);
        hook.executePolicy(policyId);
    }

    function test_expiry_executesBeforeDeadline() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint64 expiryTime = uint64(block.timestamp + 1 hours);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, expiryTime, 0);
        vm.stopPrank();

        _movePriceDown();

        // Execute before expiry — should succeed
        hook.executePolicy(policyId);
        assertTrue(hook.getPolicy(policyId).executed);
    }

    function test_expirePolicy_refunds() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint64 expiryTime = uint64(block.timestamp + 1 hours);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, expiryTime, 0);
        vm.stopPrank();

        uint256 depositBefore = hook.deposits(policyOwner, currency1);

        // Warp past expiry
        vm.warp(expiryTime + 1);

        // Anyone can call expirePolicy
        address random = makeAddr("random");
        vm.prank(random);
        hook.expirePolicy(policyId);

        // Refund goes to policy owner's deposits
        uint256 depositAfter = hook.deposits(policyOwner, currency1);
        assertEq(depositAfter, depositBefore + POLICY_AMOUNT, "Owner deposit should be restored");

        // Policy is marked executed
        assertTrue(hook.getPolicy(policyId).executed);

        // Active policies should be empty
        assertEq(hook.getActivePoliciesCount(poolId), 0);
    }

    function test_expirePolicy_notExpiredYet() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint64 expiryTime = uint64(block.timestamp + 1 hours);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, expiryTime, 0);
        vm.stopPrank();

        // Try to expire before deadline
        vm.expectRevert(MimosaHook.PolicyNotExpired.selector);
        hook.expirePolicy(policyId);
    }

    function test_expirePolicy_noExpirySet() public {
        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        // expiry = 0 means no expiry
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, 0);
        vm.stopPrank();

        // Should revert because expiry == 0
        vm.expectRevert(MimosaHook.PolicyNotExpired.selector);
        hook.expirePolicy(policyId);
    }

    function test_executorTip_paidToExecutor() public {
        uint128 tipAmount = 0.01e18;

        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, tipAmount);
        vm.stopPrank();

        // Deposit should be reduced by inputAmount + tip
        assertEq(hook.deposits(policyOwner, currency1), DEPOSIT_AMOUNT - POLICY_AMOUNT - tipAmount);

        _movePriceDown();

        address executor = makeAddr("executor");
        uint256 executorBalBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(executor);

        vm.prank(executor);
        hook.executePolicy(policyId);

        uint256 executorBalAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(executor);
        assertEq(executorBalAfter - executorBalBefore, tipAmount, "Executor should receive tip");
    }

    function test_executorTip_cancelRefundsFull() public {
        uint128 tipAmount = 0.01e18;

        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint256 policyId = hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, 0, tipAmount);

        uint256 depositAfterRegister = hook.deposits(policyOwner, currency1);

        // Cancel should refund inputAmount + tip
        hook.cancelPolicy(policyId);

        uint256 depositAfterCancel = hook.deposits(policyOwner, currency1);
        assertEq(
            depositAfterCancel,
            depositAfterRegister + POLICY_AMOUNT + tipAmount,
            "Cancel should refund inputAmount + executorTip"
        );
        vm.stopPrank();
    }

    function test_expirePolicy_refundsTipAndInput() public {
        uint128 tipAmount = 0.01e18;

        vm.startPrank(policyOwner);
        hook.deposit(currency1, DEPOSIT_AMOUNT);
        uint64 expiryTime = uint64(block.timestamp + 1 hours);
        uint256 policyId =
            hook.registerPolicy(poolId, SQRT_PRICE_1_2, false, false, POLICY_AMOUNT, 0, expiryTime, tipAmount);
        vm.stopPrank();

        uint256 depositBefore = hook.deposits(policyOwner, currency1);

        vm.warp(expiryTime + 1);
        hook.expirePolicy(policyId);

        uint256 depositAfter = hook.deposits(policyOwner, currency1);
        assertEq(
            depositAfter, depositBefore + POLICY_AMOUNT + tipAmount, "Expire should refund inputAmount + executorTip"
        );
    }
}
