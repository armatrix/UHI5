// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "./Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LiquidityCustody} from "../src/liquidityCustody.sol";

contract LiquidityCustodyTest is Deployers {
    LiquidityCustody hook;
    PoolId poolId;
    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        // Initialize manager and routers
        deployFreshManagerAndRouters();
        // Deploy and mint test tokens
        (currency0, currency1) = deployMintAndApprove2Currencies(18, 18);
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // Deploy the hook
        address hookAddress = address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
        deployCodeTo("LiquidityCustody.sol", abi.encode(poolManager), hookAddress);
        hook = LiquidityCustody(hookAddress);

        // Initialize pool with hook
        (key, poolId) = initPool(currency0, currency1, hook, 3000, TickMath.getSqrtPriceAtTick(0));
    }

    function test_AddLiquidity() public {
        // Setup test parameters
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e18;

        // Calculate liquidity
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);

        // Create modify liquidity params
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        // Add liquidity through the router
        modifyLiquidityRouter.modifyLiquidity(key, params, "");

        // Verify position data
        bytes32 positionKey = hook.getPositionKey(poolId, tickLower, tickUpper);
        (uint256 totalLiquidity, uint256 totalShares, uint256 lastUpdateTimestamp) = hook.positions(positionKey);
        assertEq(totalLiquidity, uint256(liquidity));
        assertEq(totalShares, uint256(liquidity));
        assertEq(lastUpdateTimestamp, block.timestamp);
    }

    function test_RemoveLiquidity() public {
        // First add liquidity
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e18;

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);

        // Add liquidity
        ModifyLiquidityParams memory addParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, addParams, "");

        // Now remove half of the liquidity
        uint256 halfLiquidity = uint256(liquidity) / 2;
        ModifyLiquidityParams memory removeParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(halfLiquidity),
            salt: bytes32(0)
        });

        // Remove liquidity through the router
        modifyLiquidityRouter.modifyLiquidity(key, removeParams, "");

        // Verify position data
        bytes32 positionKey = hook.getPositionKey(poolId, tickLower, tickUpper);
        (uint256 totalLiquidity, uint256 totalShares, uint256 lastUpdateTimestamp) = hook.positions(positionKey);
        assertApproxEqAbs(totalLiquidity, halfLiquidity, 1);
        assertApproxEqAbs(totalShares, halfLiquidity, 1);
        assertEq(lastUpdateTimestamp, block.timestamp);
    }

    function test_MultipleUsersAddLiquidity() public {
        // Setup test parameters
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e18;

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);

        // First user adds liquidity
        address user1 = makeAddr("user1");
        vm.startPrank(user1);
        // Mint tokens for user1
        token0.mint(user1, amount0);
        token1.mint(user1, amount1);
        // Approve tokens
        token0.approve(address(modifyLiquidityRouter), amount0);
        token1.approve(address(modifyLiquidityRouter), amount1);

        ModifyLiquidityParams memory params1 = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, params1, "");
        vm.stopPrank();

        // Second user adds liquidity
        address user2 = makeAddr("user2");
        vm.startPrank(user2);
        // Mint tokens for user2
        token0.mint(user2, amount0);
        token1.mint(user2, amount1);
        // Approve tokens
        token0.approve(address(modifyLiquidityRouter), amount0);
        token1.approve(address(modifyLiquidityRouter), amount1);

        ModifyLiquidityParams memory params2 = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        modifyLiquidityRouter.modifyLiquidity(key, params2, "");
        vm.stopPrank();

        // Verify position data
        bytes32 positionKey = hook.getPositionKey(poolId, tickLower, tickUpper);
        (uint256 totalLiquidity, uint256 totalShares,) = hook.positions(positionKey);
        assertEq(totalLiquidity, uint256(liquidity) * 2);
        assertEq(totalShares, uint256(liquidity) * 2);
    }
}
