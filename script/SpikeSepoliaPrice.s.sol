// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Executes a live Sepolia swap against the demo pool to move price.
/// @dev Default direction is oneForZero exact-input, which raises the mUSD/WETH sqrtPriceX96.
contract SpikeSepoliaPrice is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant DEFAULT_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant DEFAULT_HOOK = 0x892D42B22Ac103C682e43b945c81C4572E269000;
    address internal constant DEFAULT_TOKEN0 = 0x5B753e64d1B87fBC350e9adC1758eecf52c32Ae5;
    address internal constant DEFAULT_TOKEN1 = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant DEFAULT_SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;

    struct Config {
        address poolManager;
        address hook;
        address tokenA;
        address tokenB;
        uint24 fee;
        int24 tickSpacing;
        address swapTestAddress;
        bool zeroForOne;
        uint128 amountIn;
    }

    function run() external returns (PoolId poolId, uint160 priceBefore, uint160 priceAfter) {
        Config memory cfg = _loadConfig();
        require(cfg.tokenA != cfg.tokenB, "SpikeSepoliaPrice: identical tokens");
        require(cfg.amountIn > 0, "SpikeSepoliaPrice: zero amount");

        (address token0, address token1) =
            cfg.tokenA < cfg.tokenB ? (cfg.tokenA, cfg.tokenB) : (cfg.tokenB, cfg.tokenA);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: cfg.fee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hook)
        });
        poolId = key.toId();

        IPoolManager manager = IPoolManager(cfg.poolManager);
        PoolSwapTest swapTest = PoolSwapTest(payable(cfg.swapTestAddress));
        (priceBefore,,,) = manager.getSlot0(poolId);

        address inputToken = cfg.zeroForOne ? token0 : token1;

        console2.log("PoolSwapTest:", cfg.swapTestAddress);
        console2.log("PoolManager:", cfg.poolManager);
        console2.log("poolId:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("zeroForOne:", cfg.zeroForOne);
        console2.log("inputToken:", inputToken);
        console2.log("amountIn:", cfg.amountIn);
        console2.log("priceBefore:", priceBefore);

        vm.startBroadcast();
        IERC20(inputToken).approve(cfg.swapTestAddress, type(uint256).max);
        swapTest.swap(
            key,
            SwapParams({
                zeroForOne: cfg.zeroForOne,
                amountSpecified: -int256(uint256(cfg.amountIn)),
                sqrtPriceLimitX96: cfg.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopBroadcast();

        (priceAfter,,,) = manager.getSlot0(poolId);
        console2.log("priceAfter:", priceAfter);
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        cfg.hook = vm.envOr("HOOK", DEFAULT_HOOK);
        cfg.tokenA = vm.envOr("TOKEN_A", DEFAULT_TOKEN0);
        cfg.tokenB = vm.envOr("TOKEN_B", DEFAULT_TOKEN1);
        cfg.fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        cfg.tickSpacing = int24(int256(vm.envOr("TICK_SPACING", int256(60))));
        cfg.swapTestAddress = vm.envOr("POOL_SWAP_TEST", DEFAULT_SWAP_TEST);
        cfg.zeroForOne = vm.envOr("ZERO_FOR_ONE", false);
        cfg.amountIn = uint128(vm.envUint("SWAP_AMOUNT"));
    }
}
