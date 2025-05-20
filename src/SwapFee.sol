// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {console} from "forge-std/console.sol";
import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SwapFee is BaseHook {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    uint16 public immutable feeBps;
    address payable public immutable feeRecipient;
    bool public feeEnabled;

    event FeeEnabledChanged(bool enabled);
    event FeeCollected(Currency currency, uint256 amount);

    constructor(IPoolManager _poolManager, address payable _feeRecipient, uint16 _feeBps) BaseHook(_poolManager) {
        require(_feeBps <= 10_000, "MAX_BPS");
        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
        feeEnabled = true;
    }

    function toggleFee() external {
        feeEnabled = !feeEnabled;
        emit FeeEnabledChanged(feeEnabled);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!feeEnabled) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 swapAmount =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 feeAmount = (swapAmount * feeBps) / 10_000;
        Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        poolManager.take(feeCurrency, feeRecipient, feeAmount);
        emit FeeCollected(feeCurrency, feeAmount);

        BeforeSwapDelta returnDelta = toBeforeSwapDelta(
            int128(int256(feeAmount)), // Specified delta (fee amount)
            0 // Unspecified delta (no change)
        );
        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }
}
