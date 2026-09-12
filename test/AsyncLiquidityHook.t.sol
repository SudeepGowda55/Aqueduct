// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { AsyncLiquidityHook } from "../src/hooks/AsyncLiquidityHook.sol";
import { FixedRateAsyncHook } from "./mocks/FixedRateAsyncHook.sol";

/**
 * @title AsyncLiquidityHookTest
 * @notice Proves {AsyncLiquidityHook} is a genuinely reusable v4 base, not a private detail of
 *         `AquaV4Hook`: this suite wires up `FixedRateAsyncHook` -- a completely independent
 *         implementation with no Aqua, no SwapVM, no exposure gate, no shared state with the
 *         Aqueduct-specific hook -- against a REAL `PoolManager`, and shows the exact same
 *         claims-mint / float-fund / settle / sweep sequence documented on the base contract
 *         fills a real swap correctly. If this suite passes, the base contract's contract is
 *         proven for *any* external-liquidity source, not just this project's one.
 */
contract AsyncLiquidityHookTest is Test {
    uint256 internal constant SWAP_AMOUNT = 10e18;
    uint256 internal constant FLOAT = 1_000e18;
    int24 internal constant TICK_SPACING = 60;
    // 1 tokenIn -> 2 tokenOut, a rate no XYC curve would ever coincidentally produce, so a
    // passing test can only be explained by the fixed-rate hook actually running.
    uint256 internal constant RATE_NUMERATOR = 2;
    uint256 internal constant RATE_DENOMINATOR = 1;

    IPoolManager public poolManager;
    PoolSwapTest public swapRouter;
    TokenMock public token0;
    TokenMock public token1;
    FixedRateAsyncHook public hook;
    PoolKey public poolKey;

    function setUp() public {
        poolManager = IPoolManager(vm.deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));

        TokenMock a = new TokenMock("Token A", "TKA");
        TokenMock b = new TokenMock("Token B", "TKB");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, RATE_NUMERATOR, RATE_DENOMINATOR);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(FixedRateAsyncHook).creationCode, constructorArgs);
        hook = new FixedRateAsyncHook{ salt: salt }(poolManager, RATE_NUMERATOR, RATE_DENOMINATOR);
        assertEq(address(hook), hookAddress, "hook address mismatch");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        swapRouter = new PoolSwapTest(poolManager);

        // Seed the float with a plain ERC20 transfer -- exactly as documented on the base
        // contract, no bespoke deposit function.
        token0.mint(address(hook), FLOAT);
        token1.mint(address(hook), FLOAT);

        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
    }

    function test_FillsAtTheFixedRate_NotAnAmmCurve() public {
        uint256 token1BalanceBefore = token1.balanceOf(address(this));

        BalanceDelta delta = _swap(true, SWAP_AMOUNT);

        assertEq(delta.amount0(), -int256(SWAP_AMOUNT), "taker should pay exactly the specified input");
        assertEq(delta.amount1(), int256(SWAP_AMOUNT * RATE_NUMERATOR / RATE_DENOMINATOR), "output must match the fixed rate exactly, not an XYC curve");
        assertEq(
            token1.balanceOf(address(this)), token1BalanceBefore + uint256(int256(delta.amount1())),
            "taker's real token1 balance must reflect the fill"
        );
    }

    function test_WorksInBothDirections() public {
        BalanceDelta delta = _swap(false, SWAP_AMOUNT);
        assertEq(delta.amount1(), -int256(SWAP_AMOUNT), "taker should pay exactly the specified input");
        assertEq(delta.amount0(), int256(SWAP_AMOUNT * RATE_NUMERATOR / RATE_DENOMINATOR), "reverse direction must also fill at the fixed rate");
    }

    function test_ExactOutputReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(AsyncLiquidityHook.ExactOutputNotSupported.selector),
                hex"a9e35b2f"
            )
        );
        swapRouter.swap(
            poolKey,
            SwapParams({ zeroForOne: true, amountSpecified: int256(SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
    }

    function test_DirectLiquidityAdditionReverts() public {
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(AsyncLiquidityHook.LiquidityNotAllowed.selector),
                hex"a9e35b2f"
            )
        );
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @notice Proves {AsyncLiquidityHook.sweepClaims} -- shared, untouched base-contract code --
    /// works identically for this completely different implementation: after a real fill mints
    /// this hook claims, sweeping converts them back into real tokens once the pool holds enough.
    function test_SweepClaimsConvertsAccumulatedClaimsBackToRealTokens() public {
        _swap(true, SWAP_AMOUNT);

        // The currency actually taken as claims in _beforeSwap for a zeroForOne swap: token0
        // (the "specified" side of an exact-in, zeroForOne trade).
        Currency specified = poolKey.currency0;
        uint256 claimBalance = poolManager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(specified))));
        assertGt(claimBalance, 0, "sanity: the swap must have minted this hook real ERC-6909 claims");

        uint256 realBefore = token0.balanceOf(address(hook));
        hook.sweepClaims(specified, claimBalance);
        uint256 realAfter = token0.balanceOf(address(hook));

        assertEq(realAfter - realBefore, claimBalance, "sweeping must convert exactly the claimed amount into real tokens");
        assertEq(poolManager.balanceOf(address(hook), uint256(uint160(Currency.unwrap(specified)))), 0, "claims must be fully burned");
    }
}
