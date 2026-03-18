// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";

/// @notice Initializes a Uniswap v4 pool on Sepolia using the deployed v4 PositionManager.
/// @dev This is enough for MimosaHook to learn the pool through afterInitialize.
contract InitSepoliaPool is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant DEFAULT_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;

    function run() external returns (PoolId poolId) {
        address hook = vm.envAddress("HOOK");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint24 fee = uint24(vm.envUint("POOL_FEE"));
        int24 tickSpacing = int24(int256(vm.envInt("TICK_SPACING")));
        uint160 sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        address positionManager = vm.envOr("POSITION_MANAGER", DEFAULT_POSITION_MANAGER);

        require(tokenA != tokenB, "InitSepoliaPool: identical tokens");

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        poolId = key.toId();

        console2.log("PositionManager:", positionManager);
        console2.log("Hook:", hook);
        console2.log("token0:", token0);
        console2.log("token1:", token1);
        console2.log("fee:", fee);
        console2.log("tickSpacing:", tickSpacing);
        console2.log("sqrtPriceX96:", sqrtPriceX96);
        console2.log("poolId:");
        console2.logBytes32(PoolId.unwrap(poolId));

        vm.startBroadcast();
        IPoolInitializer_v4(positionManager).initializePool(key, sqrtPriceX96);
        vm.stopBroadcast();
    }
}
