// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {Planner, Plan} from "v4-periphery/test/shared/Planner.sol";

/// @notice Seeds a full-range v4 position into the Sepolia demo pool.
/// @dev Requires the caller to already hold both assets, unless WRAP_WETH=true for the WETH leg.
contract AddSepoliaLiquidity is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant DEFAULT_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address internal constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant DEFAULT_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    struct Config {
        address hook;
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        address positionManager;
        address permit2;
        address weth;
        bool wrapWeth;
        uint256 deadline;
    }

    struct SortedInputs {
        address token0;
        address token1;
        uint256 amount0Desired;
        uint256 amount1Desired;
    }

    function run() external returns (PoolId poolId, uint256 tokenId) {
        Config memory cfg = _loadConfig();
        SortedInputs memory sorted = _sortInputs(cfg);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(sorted.token0),
            currency1: Currency.wrap(sorted.token1),
            fee: cfg.fee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.hook)
        });
        poolId = key.toId();

        int24 tickLower = TickMath.minUsableTick(cfg.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(cfg.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            cfg.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            sorted.amount0Desired,
            sorted.amount1Desired
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.MINT_POSITION,
            abi.encode(
                key,
                tickLower,
                tickUpper,
                liquidity,
                uint128(sorted.amount0Desired),
                uint128(sorted.amount1Desired),
                ActionConstants.MSG_SENDER,
                bytes("")
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(key);

        IPositionManager posm = IPositionManager(cfg.positionManager);
        tokenId = posm.nextTokenId();

        console2.log("PositionManager:", cfg.positionManager);
        console2.log("Permit2:", cfg.permit2);
        console2.log("Hook:", cfg.hook);
        console2.log("token0:", sorted.token0);
        console2.log("token1:", sorted.token1);
        console2.log("amount0Desired:", sorted.amount0Desired);
        console2.log("amount1Desired:", sorted.amount1Desired);
        console2.log("tickLower:", tickLower);
        console2.log("tickUpper:", tickUpper);
        console2.log("liquidity:", liquidity);
        console2.log("poolId:");
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("nextTokenId:", tokenId);

        vm.startBroadcast();

        if (cfg.wrapWeth) {
            if (cfg.tokenA == cfg.weth) {
                IWETH9(cfg.weth).deposit{value: cfg.amountA}();
            }
            if (cfg.tokenB == cfg.weth) {
                IWETH9(cfg.weth).deposit{value: cfg.amountB}();
            }
        }

        IERC20(sorted.token0).approve(cfg.permit2, type(uint256).max);
        IERC20(sorted.token1).approve(cfg.permit2, type(uint256).max);

        IAllowanceTransfer(cfg.permit2).approve(sorted.token0, cfg.positionManager, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(cfg.permit2).approve(sorted.token1, cfg.positionManager, type(uint160).max, type(uint48).max);

        posm.modifyLiquidities(actions, cfg.deadline);

        vm.stopBroadcast();

        console2.log("Minted position tokenId:", tokenId);
    }

    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.hook = vm.envAddress("HOOK");
        cfg.tokenA = vm.envAddress("TOKEN_A");
        cfg.tokenB = vm.envAddress("TOKEN_B");
        cfg.amountA = vm.envUint("TOKEN_A_AMOUNT");
        cfg.amountB = vm.envUint("TOKEN_B_AMOUNT");
        cfg.fee = uint24(vm.envUint("POOL_FEE"));
        cfg.tickSpacing = int24(int256(vm.envInt("TICK_SPACING")));
        cfg.sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        cfg.positionManager = vm.envOr("POSITION_MANAGER", DEFAULT_POSITION_MANAGER);
        cfg.permit2 = vm.envOr("PERMIT2", DEFAULT_PERMIT2);
        cfg.weth = vm.envOr("WETH", DEFAULT_WETH);
        cfg.wrapWeth = vm.envOr("WRAP_WETH", false);
        cfg.deadline = block.timestamp + vm.envOr("DEADLINE_BUFFER", uint256(20 minutes));
    }

    function _sortInputs(Config memory cfg) internal pure returns (SortedInputs memory sorted) {
        require(cfg.tokenA != cfg.tokenB, "AddSepoliaLiquidity: identical tokens");
        require(cfg.amountA > 0 && cfg.amountB > 0, "AddSepoliaLiquidity: zero amount");

        if (cfg.tokenA < cfg.tokenB) {
            sorted.token0 = cfg.tokenA;
            sorted.token1 = cfg.tokenB;
            sorted.amount0Desired = cfg.amountA;
            sorted.amount1Desired = cfg.amountB;
        } else {
            sorted.token0 = cfg.tokenB;
            sorted.token1 = cfg.tokenA;
            sorted.amount0Desired = cfg.amountB;
            sorted.amount1Desired = cfg.amountA;
        }
    }
}
