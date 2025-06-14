// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

// A CSMM is a pricing curve that follows the invariant `x + y = k`
// instead of the invariant `x * y = k`
// This is a super simple CSMM PoC that hardcodes 1:1 swaps through a custom pricing curve hook

// This is theoretically the ideal curve for a stablecoin or pegged pairs (stETH/ETH)
// In practice, we don't usually see this in prod since depegs can happen and we dont want exact equal amounts
// But is a nice little NoOp hook example

contract CSMM is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook();

    event HookSwap(
        bytes32 indexed id, // v4 pool id
        address indexed sender, // router of the swap
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    event HookModifyLiquidity(
        bytes32 indexed id, // v4 pool id
        address indexed sender, // router address
        int128 amount0,
        int128 amount1
    );

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true, // Don't allow adding liquidity normally
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Disable adding liquidity through the PM
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );

        emit HookModifyLiquidity(
            PoolId.unwrap(key.toId()),
            address(this),
            int128(uint128(amountEach)),
            int128(uint128(amountEach))
        );
    }

    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amountEach` of each currency from the sender
        // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );
        callbackData.currency1.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amountEach` of each currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us
        // that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );

        return "";
    }

    // Swapping
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        bool isExactInput = params.amountSpecified < 0;

        /**
        BalanceDelta is a packed value of (currency0Amount, currency1Amount)

        BeforeSwapDelta varies such that it is not sorted by token0 and token1
        Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"

        Specified Currency => The currency in which the user is specifying the amount they're swapping for
        Unspecified Currency => The other currency

        For example, in an ETH/USDC pool, there are 4 possible swap cases:

        1. ETH for USDC with Exact Input for Output (amountSpecified = negative value representing ETH)
        2. ETH for USDC with Exact Output for Input (amountSpecified = positive value representing USDC)
        3. USDC for ETH with Exact Input for Output (amountSpecified = negative value representing USDC)
        4. USDC for ETH with Exact Output for Input (amountSpecified = positive value representing ETH)
        -------
        
        Assume zeroForOne = true (without loss of generality)
        Assume abs(amountSpecified) = 100

        For an exact input swap where amountSpecified is negative (-100)
            -> specified token = token0
            -> unspecified token = token1
            -> we set deltaSpecified = -(-100) = 100
            -> we set deltaUnspecified = -100
            -> i.e. hook is owed 100 specified token (token0) by PM (that comes from the user)
            -> and hook owes 100 unspecified token (token1) to PM (to go to the user)
    
        For an exact output swap where amountSpecified is positive (100)
            -> specified token = token1
            -> unspecified token = token0
            -> we set deltaSpecified = -100
            -> we set deltaUnspecified = 100
            -> i.e. hook owes 100 specified token (token1) to PM (to go to the user)
            -> and hook is owed 100 unspecified token (token0) by PM (that comes from the user)

        In either case, we can design BeforeSwapDelta as (-params.amountSpecified, params.amountSpecified)
        */

        int128 absInputAmount;
        int128 absOutputAmount;
        BeforeSwapDelta beforeSwapDelta;
        if (isExactInput) {
            absInputAmount = int128(-params.amountSpecified);
            absOutputAmount = absInputAmount; // exactly 1:1

            // If you wanted to charge fees here, reduce absOutputAmount a little bit
            // i.e. if user is giving you 100 A, "spot price" would have them get back 100 B.
            // Instead, if you give back 99B - that's effectively a 1% fee
            // absOutputAmount = (absOutputAmount * 99) / 100;

            beforeSwapDelta = toBeforeSwapDelta(
                absInputAmount, // abs(params.amountSpecified) of input token owed from uniswap to hook
                -absOutputAmount // -abs(params.amountSpecified) i.e. params.amountSpecified of output token owed from hook to uniswap
            );
        } else {
            absOutputAmount = int128(params.amountSpecified);
            absInputAmount = absOutputAmount; // exactly 1:1

            // If you wanted to charge fees here, increase absInputAmount a little bit
            // i.e. if user wants 100 B, "spot price" would have them give you 100 A.
            // Instead, if you take 101A - that's effectively a 1% fee
            // absInputAmount = (absInputAmount * 101) / 100;

            beforeSwapDelta = toBeforeSwapDelta(
                -absInputAmount, // -abs(params.amountSpecified) of output token owed from hook to uniswap
                absOutputAmount // abs(params.amountSpecified) of input token owed from uniswap to hook
            );
        }

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
            // We will take claim tokens for that Token 0 from the PM and keep it in the hook
            // and create an equivalent credit for that Token 0 since it is ours!
            key.currency0.take(
                poolManager,
                address(this),
                uint256(uint128(absInputAmount)),
                true
            );

            // They will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            // and create an equivalent debit for Token 1 since it is ours!
            key.currency1.settle(
                poolManager,
                address(this),
                uint256(uint128(absOutputAmount)),
                true
            );

            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                -absInputAmount,
                absOutputAmount,
                0,
                0
            );
        } else {
            key.currency0.settle(
                poolManager,
                address(this),
                uint256(uint128(absOutputAmount)),
                true
            );
            key.currency1.take(
                poolManager,
                address(this),
                uint256(uint128(absInputAmount)),
                true
            );

            emit HookSwap(
                PoolId.unwrap(key.toId()),
                sender,
                absOutputAmount,
                -absInputAmount,
                0,
                0
            );
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }
}