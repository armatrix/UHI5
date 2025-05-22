// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// u need to think about
// how to handle fee
// how to handle native token etc.
// Liquidity Mining, Liquidity Insurance, Liquidity Options(ref Black-Scholes model), Liquidity Tiers, Liquidity Aggregator
contract LiquidityCustody is BaseHook {
    using StateLibrary for IPoolManager;

    struct LiquidityPosition {
        uint256 totalLiquidity;
        uint256 totalShares;
        mapping(address => uint256) userShares;
        uint256 lastUpdateTimestamp;
    }

    struct PositionKey {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
    }

    mapping(bytes32 => LiquidityPosition) public positions;

    event LiquidityAdded(
        address indexed user, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint256 liquidity, uint256 shares
    );

    event LiquidityRemoved(
        address indexed user, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint256 liquidity, uint256 shares
    );

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
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

    function getPositionKey(PoolId poolId, int24 tickLower, int24 tickUpper) public pure returns (bytes32) {
        return keccak256(abi.encode(poolId, tickLower, tickUpper));
    }

    // u can merge most func in _modifyLiquidity func
    // impl if liquidity > 0, then add liquidity
    // impl if liquidity < 0, then remove liquidity
    // call modifyLiquidity in _beforeAddLiquidity and _beforeRemoveLiquidity
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        require(sender != address(0), "Invalid sender address");
        require(params.liquidityDelta > 0, "Invalid liquidity delta");

        PoolId poolId = key.toId();
        bytes32 positionKey = getPositionKey(poolId, params.tickLower, params.tickUpper);
        LiquidityPosition storage position = positions[positionKey];

        uint256 absLiquidityDelta = uint256(params.liquidityDelta);
        uint256 shares;

        if (position.totalLiquidity == 0) {
            shares = absLiquidityDelta;
        } else {
            // round problem
            // Ref full math lib
            shares = ((absLiquidityDelta * position.totalShares) / position.totalLiquidity);
        }

        position.totalLiquidity += absLiquidityDelta;
        position.totalShares += shares;
        position.userShares[sender] += shares;
        position.lastUpdateTimestamp = block.timestamp;

        emit LiquidityAdded(sender, poolId, params.tickLower, params.tickUpper, absLiquidityDelta, shares);

        return (BaseHook.beforeAddLiquidity.selector);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        require(sender != address(0), "Invalid sender address");
        require(params.liquidityDelta < 0, "Invalid liquidity delta");

        PoolId poolId = key.toId();
        bytes32 positionKey = getPositionKey(poolId, params.tickLower, params.tickUpper);
        LiquidityPosition storage position = positions[positionKey];

        uint256 absLiquidityDelta = uint256(-params.liquidityDelta);
        uint256 shares = ((absLiquidityDelta * position.totalShares) / position.totalLiquidity);

        require(position.userShares[sender] >= shares, "Insufficient shares");
        require(position.totalLiquidity >= absLiquidityDelta, "Insufficient liquidity");

        position.totalLiquidity -= absLiquidityDelta;
        position.totalShares -= shares;
        position.userShares[sender] -= shares;
        position.lastUpdateTimestamp = block.timestamp;

        emit LiquidityRemoved(sender, poolId, params.tickLower, params.tickUpper, absLiquidityDelta, shares);

        return (BaseHook.beforeRemoveLiquidity.selector);
    }
}
