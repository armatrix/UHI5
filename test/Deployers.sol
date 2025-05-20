// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapRouterNoChecks} from "@uniswap/v4-core/src/test/SwapRouterNoChecks.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolNestedActionsTest} from "@uniswap/v4-core/src/test/PoolNestedActionsTest.sol";
import {PoolTakeTest} from "@uniswap/v4-core/src/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";
import {ActionsRouter} from "@uniswap/v4-core/src/test/ActionsRouter.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract Deployers is Test {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // Helpful test constants
    bytes constant ZERO_BYTES = Constants.ZERO_BYTES;
    uint160 constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;
    uint160 constant SQRT_PRICE_1_2 = Constants.SQRT_PRICE_1_2;
    uint160 constant SQRT_PRICE_2_1 = Constants.SQRT_PRICE_2_1;
    uint160 constant SQRT_PRICE_1_4 = Constants.SQRT_PRICE_1_4;
    uint160 constant SQRT_PRICE_4_1 = Constants.SQRT_PRICE_4_1;

    uint160 public constant SQRT_PRICE_3000_1 = 4339505179874779700000000000000; // mock eth

    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    ModifyLiquidityParams public LIQUIDITY_PARAMS =
        ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
    ModifyLiquidityParams public REMOVE_LIQUIDITY_PARAMS =
        ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
    SwapParams public SWAP_PARAMS =
        SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2});

    // Global variables
    Currency ethCurrency = Currency.wrap(address(0));
    Currency internal currency0;
    Currency internal currency1;
    IPoolManager poolManager;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolModifyLiquidityTestNoChecks modifyLiquidityNoChecks;
    SwapRouterNoChecks swapRouterNoChecks;
    PoolSwapTest swapRouter;
    PoolDonateTest donateRouter;
    PoolTakeTest takeRouter;
    ActionsRouter actionsRouter;

    PoolClaimsTest claimsRouter;
    PoolNestedActionsTest nestedActionRouter;
    address feeController;

    PoolKey key;
    PoolKey nativeKey;
    PoolKey uninitializedKey;
    PoolKey uninitializedNativeKey;

    // Update this value when you add a new hook flag.
    uint160 hookPermissionCount = 14;
    uint160 clearAllHookPermissionsMask = ~uint160(0) << (hookPermissionCount);

    modifier noIsolate() {
        if (msg.sender != address(this)) {
            (bool success,) = address(this).call(msg.data);
            require(success);
        } else {
            _;
        }
    }

    function deployFreshManager() internal virtual {
        poolManager = new PoolManager(address(this));
    }

    function deployFreshManagerAndRouters() internal {
        deployFreshManager();
        swapRouter = new PoolSwapTest(poolManager);
        swapRouterNoChecks = new SwapRouterNoChecks(poolManager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        modifyLiquidityNoChecks = new PoolModifyLiquidityTestNoChecks(poolManager);
        donateRouter = new PoolDonateTest(poolManager);
        takeRouter = new PoolTakeTest(poolManager);
        claimsRouter = new PoolClaimsTest(poolManager);
        nestedActionRouter = new PoolNestedActionsTest(poolManager);
        feeController = makeAddr("feeController");
        actionsRouter = new ActionsRouter(poolManager);

        poolManager.setProtocolFeeController(feeController);
    }

    function deployMintAndApproveCurrency(uint8 decimals) internal returns (Currency currency) {
        MockERC20 token = deployTokens(1, 2 ** 255, decimals)[0];

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }

    function deployAndMint2Currencies(uint8 decimals0, uint8 decimals1) internal returns (Currency, Currency) {
        MockERC20[] memory tokens = new MockERC20[](2);
        tokens[0] = new MockERC20("TEST", "TEST", 18);
        tokens[1] = new MockERC20("TEST", "TEST", 18);

        (Currency _currency0, Currency _currency1) = SortTokens.sort(tokens[0], tokens[1]);

        vm.store(Currency.unwrap(_currency0), bytes32(uint256(2)), bytes32(uint256(decimals0)));
        vm.store(Currency.unwrap(_currency1), bytes32(uint256(2)), bytes32(uint256(decimals1)));

        string memory name0 = string.concat("Token0-", vm.toString(decimals0));
        string memory name1 = string.concat("Token1-", vm.toString(decimals1));
        string memory symbol0 = string.concat("T0-", vm.toString(decimals0));
        string memory symbol1 = string.concat("T1-", vm.toString(decimals1));

        vm.store(Currency.unwrap(_currency0), bytes32(uint256(0)), keccak256(bytes(name0)));
        vm.store(Currency.unwrap(_currency1), bytes32(uint256(0)), keccak256(bytes(name1)));

        vm.store(Currency.unwrap(_currency0), bytes32(uint256(1)), keccak256(bytes(symbol0)));
        vm.store(Currency.unwrap(_currency1), bytes32(uint256(1)), keccak256(bytes(symbol1)));

        tokens[0].mint(address(this), 2 ** 255);
        tokens[1].mint(address(this), 2 ** 255);
        return (_currency0, _currency1);
    }

    // You must have first initialized the routers with deployFreshManagerAndRouters
    // If you only need the currencies (and not approvals) call deployAndMint2Currencies
    function deployMintAndApprove2Currencies(uint8 decimals0, uint8 decimals1) internal returns (Currency, Currency) {
        (Currency _currency0, Currency _currency1) = deployAndMint2Currencies(decimals0, decimals1);
        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            MockERC20(Currency.unwrap(_currency0)).approve(toApprove[i], Constants.MAX_UINT256);
            MockERC20(Currency.unwrap(_currency1)).approve(toApprove[i], Constants.MAX_UINT256);
        }

        return (_currency0, _currency1);
    }

    function deployTokens(uint8 count, uint256 totalSupply) internal returns (MockERC20[] memory tokens) {
        tokens = new MockERC20[](count);
        string memory name;
        string memory symbol;
        for (uint8 i = 0; i < count; i++) {
            name = string.concat("Token", vm.toString(i), "-18");
            symbol = string.concat("T", vm.toString(i), "-18");
            tokens[i] = new MockERC20(name, symbol, 18);
            tokens[i].mint(address(this), totalSupply);
        }
    }

    function deployTokens(uint8 count, uint256 totalSupply, uint8 decimals)
        internal
        returns (MockERC20[] memory tokens)
    {
        tokens = new MockERC20[](count);
        string memory name;
        string memory symbol;
        for (uint8 i = 0; i < count; i++) {
            name = string.concat("Token", vm.toString(i), "-", vm.toString(decimals));
            symbol = string.concat("T", vm.toString(i), "-", vm.toString(decimals));
            tokens[i] = new MockERC20(name, symbol, decimals);
            tokens[i].mint(address(this), totalSupply);
        }
    }

    function deployTokens(uint8[] memory decimals) internal returns (MockERC20[] memory tokens) {
        tokens = new MockERC20[](decimals.length);
        string memory name;
        string memory symbol;
        uint8 decimal;
        for (uint8 i = 0; i < decimals.length; i++) {
            decimal = decimals[i];
            name = string.concat("Token", vm.toString(i), "-", vm.toString(decimal));
            symbol = string.concat("T", vm.toString(i), "-", vm.toString(decimal));
            tokens[i] = new MockERC20(name, symbol, decimal);
            tokens[i].mint(address(this), 2 ** 255);
        }
    }

    function initPool(Currency _currency0, Currency _currency1, IHooks hooks, uint24 fee, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory _key, PoolId id)
    {
        _key = PoolKey(_currency0, _currency1, fee, fee.isDynamicFee() ? int24(60) : int24(fee / 100 * 2), hooks);
        id = _key.toId();
        poolManager.initialize(_key, sqrtPriceX96);
    }

    function initPool(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory _key, PoolId id) {
        _key = PoolKey(_currency0, _currency1, fee, tickSpacing, hooks);
        id = _key.toId();
        poolManager.initialize(_key, sqrtPriceX96);
    }

    function initPoolAndAddLiquidity(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory _key, PoolId id) {
        (_key, id) = initPool(_currency0, _currency1, hooks, fee, sqrtPriceX96);
        modifyLiquidityRouter.modifyLiquidity{value: msg.value}(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function initPoolAndAddLiquidityETH(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        uint160 sqrtPriceX96,
        uint256 msgValue
    ) internal returns (PoolKey memory _key, PoolId id) {
        (_key, id) = initPool(_currency0, _currency1, hooks, fee, sqrtPriceX96);
        modifyLiquidityRouter.modifyLiquidity{value: msgValue}(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // Deploys the manager, all test routers, and sets up 2 pools: with and without native
    function initializeManagerRoutersAndPoolsWithLiq(IHooks hooks, uint8 decimals0, uint8 decimals1) internal {
        deployFreshManagerAndRouters();
        // sets the global currencies and key
        deployMintAndApprove2Currencies(decimals0, decimals1);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, hooks, 3000, SQRT_PRICE_1_1);
        nestedActionRouter.executor().setKey(key);
        (nativeKey,) =
            initPoolAndAddLiquidityETH(CurrencyLibrary.ADDRESS_ZERO, currency1, hooks, 3000, SQRT_PRICE_1_1, 1 ether);
        uninitializedKey = key;
        uninitializedNativeKey = nativeKey;
        uninitializedKey.fee = 100;
        uninitializedNativeKey.fee = 100;
    }

    /// @notice Helper function for a simple ERC20 swaps that allows for unlimited price impact
    function swap(PoolKey memory _key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        // allow native input for exact-input, guide users to the `swapNativeInput` function
        bool isNativeInput = zeroForOne && _key.currency0.isAddressZero();
        if (isNativeInput) require(0 > amountSpecified, "Use swapNativeInput() for native-token exact-output swaps");

        uint256 value = isNativeInput ? uint256(-amountSpecified) : 0;

        return swapRouter.swap{value: value}(
            _key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Helper function to increase balance of pool manager.
    /// Uses default LIQUIDITY_PARAMS range.
    function seedMoreLiquidity(PoolKey memory _key, uint256 amount0, uint256 amount1) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_key.toId());
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(LIQUIDITY_PARAMS.tickLower),
            TickMath.getSqrtPriceAtTick(LIQUIDITY_PARAMS.tickUpper),
            amount0,
            amount1
        );

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: LIQUIDITY_PARAMS.tickLower,
            tickUpper: LIQUIDITY_PARAMS.tickUpper,
            liquidityDelta: int128(liquidityDelta),
            salt: 0
        });

        modifyLiquidityRouter.modifyLiquidity(_key, params, ZERO_BYTES);
    }

    /// @notice Helper function for a simple Native-token swap that allows for unlimited price impact
    function swapNativeInput(
        PoolKey memory _key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData,
        uint256 msgValue
    ) internal returns (BalanceDelta) {
        require(_key.currency0.isAddressZero(), "currency0 is not native. Use swap() instead");
        if (zeroForOne == false) require(msgValue == 0, "msgValue must be 0 for oneForZero swaps");

        return swapRouter.swap{value: msgValue}(
            _key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // to receive refunds of spare eth from test helpers
    receive() external payable {}
}
