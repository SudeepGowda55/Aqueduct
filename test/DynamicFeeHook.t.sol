// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import { dynamic } from "@1inch/swap-vm/test/utils/Dynamic.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";
import { AquaV4Hook } from "../src/hooks/AquaV4Hook.sol";

/**
 * @title DynamicFeeHookTest
 * @notice Proves `AquaV4Hook`'s second, independent Uniswap v4 capability: a swap fee that scales
 *         with the maker's live exposure via v4's own `LPFeeLibrary`/`updateDynamicLPFee`
 *         mechanism -- entirely separate from, and additive on top of, the SwapVM-side
 *         `_exposureGate1D` derate. This is opt-in per pool (gated on the pool's own `fee` field
 *         carrying `LPFeeLibrary.DYNAMIC_FEE_FLAG`), so every static-fee pool elsewhere in this
 *         repo -- including the one `CrossVenueConsistencyTest` proves bit-for-bit identical to
 *         the direct SwapVM path -- is completely unaffected, proven directly here rather than
 *         merely inferred from that suite staying green.
 */
contract DynamicFeeHookTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant INITIAL_BALANCE = 1_000_000e18;
    uint256 internal constant SWAP_AMOUNT = 10e18;
    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant ONE = 1e18;

    // Mirrors AquaV4Hook's own private constants exactly.
    uint24 internal constant MIN_FEE_PIPS = 500;
    uint24 internal constant MAX_FEE_PIPS = 10_000;
    uint16 internal constant FEE_SATURATION_BPS = 9_000;

    Aqua public immutable aqua = new Aqua();
    IPoolManager public poolManager;
    ExposureAwareAquaRouter public swapVM;
    ExposureOracle public oracle;
    PoolSwapTest public swapRouter;
    TokenMock public token0;
    TokenMock public token1;
    AquaV4Hook public hook;
    address public maker;
    PoolKey public poolKey;
    ISwapVM.Order public order;

    constructor() ExposureAquaOpcodes(address(aqua)) { }

    function setUp() public {
        poolManager = IPoolManager(vm.deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapVM = new ExposureAwareAquaRouter(address(aqua), address(0), address(this), "Aqueduct", "1.0.0");
        oracle = new ExposureOracle(address(this), address(this));
        maker = makeAddr("maker");

        TokenMock a = new TokenMock("Token A", "TKA");
        TokenMock b = new TokenMock("Token B", "TKB");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(address(oracle), MAX_BPS, HALT_BPS, 0))
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: true,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, aqua, swapVM, oracle, order);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AquaV4Hook).creationCode, constructorArgs);
        hook = new AquaV4Hook{ salt: salt }(poolManager, aqua, swapVM, oracle, order);
        assertEq(address(hook), hookAddress, "hook address mismatch");

        // THE difference from every other v4 pool in this repo: dynamic, not static, fee.
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        swapRouter = new PoolSwapTest(poolManager);

        token0.mint(maker, INITIAL_BALANCE);
        token1.mint(maker, INITIAL_BALANCE);
        vm.startPrank(maker);
        token0.approve(address(aqua), type(uint256).max);
        token1.approve(address(aqua), type(uint256).max);
        aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(token0), address(token1)]),
            dynamic([INITIAL_BALANCE, INITIAL_BALANCE])
        );
        vm.stopPrank();

        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Working-capital float for the hook, same as every other AquaV4Hook pool in this repo.
        token0.mint(address(hook), 100_000e18);
        token1.mint(address(hook), 100_000e18);
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

    /// @dev The pool's reserves are exactly INITIAL_BALANCE on both sides before the first (and,
    /// in every test below, only) swap -- mirrors `SophisticatedPosition.t.sol`'s own `_xycOut`.
    function _xycOut() internal pure returns (uint256) {
        return (SWAP_AMOUNT * INITIAL_BALANCE) / (INITIAL_BALANCE + SWAP_AMOUNT);
    }

    /// @dev Mirrors `_exposureGate1D`'s exact-in derate formula precisely (see ExposureGate.sol).
    function _predictGated(uint256 amountOut, uint64 exposureBps) internal pure returns (uint256) {
        if (exposureBps <= MAX_BPS) return amountOut;
        uint256 overage = exposureBps - MAX_BPS;
        uint256 band = HALT_BPS - MAX_BPS;
        uint256 derateFactor = ONE - (overage * ONE) / band;
        return (amountOut * derateFactor) / ONE;
    }

    /// @dev Mirrors `AquaV4Hook._riskFeePips` precisely.
    function _expectedFeePips(uint64 exposureBps) internal pure returns (uint24) {
        uint256 capped = exposureBps > FEE_SATURATION_BPS ? FEE_SATURATION_BPS : exposureBps;
        return uint24(MIN_FEE_PIPS + (uint256(MAX_FEE_PIPS - MIN_FEE_PIPS) * capped) / FEE_SATURATION_BPS);
    }

    function test_MinimumFeeAtZeroExposure() public {
        // exposureOf(maker) is the honest (0, 0) "never reported" reading before any keeper push;
        // the fee curve treats that identically to a genuine 0% reading.
        uint24 expectedFee = _expectedFeePips(0);
        assertEq(expectedFee, MIN_FEE_PIPS, "sanity: 0% exposure must map to the floor fee");

        uint256 rawOut = _xycOut(); // gate is a no-op at 0% exposure
        BalanceDelta delta = _swap(true, SWAP_AMOUNT);

        uint256 expectedFeeAmount = (rawOut * expectedFee) / LPFeeLibrary.MAX_LP_FEE;
        assertEq(
            uint256(int256(delta.amount1())), rawOut - expectedFeeAmount, "v4 output must reflect the floor fee exactly"
        );

        // The per-swap override (returned from `beforeSwap`, OR'd with `OVERRIDE_FEE_FLAG`) is
        // transient -- it prices THIS swap without writing through to persisted pool state. That's
        // real v4 behavior, not a gap: `refreshFee`/`updateDynamicLPFee` is the separate, correct
        // mechanism for persisted visibility, proven independently in the test below.
        (,,, uint24 persistedFee) = poolManager.getSlot0(poolKey.toId());
        assertEq(persistedFee, 0, "a per-swap fee override must not leak into persisted pool state");
    }

    function test_FeeScalesWithExposure_ExactFormula() public {
        oracle.pushExposure(maker, 4_000); // 40% -- still within the gate's own no-op band
        uint24 expectedFee = _expectedFeePips(4_000);
        assertGt(expectedFee, MIN_FEE_PIPS, "sanity: fee must have moved off the floor");
        assertLt(expectedFee, MAX_FEE_PIPS, "sanity: fee must not yet be saturated");

        uint256 rawOut = _xycOut(); // gate still a no-op at 40% (<= MAX_BPS)
        BalanceDelta delta = _swap(true, SWAP_AMOUNT);

        uint256 expectedFeeAmount = (rawOut * expectedFee) / LPFeeLibrary.MAX_LP_FEE;
        assertEq(
            uint256(int256(delta.amount1())),
            rawOut - expectedFeeAmount,
            "output must match the exact fee formula, not an approximation"
        );
    }

    function test_FeeAppliesOnTopOfTheGateDerate_NotInsteadOfIt() public {
        uint64 exposureBps = 7_000; // squarely in the gate's own derate band
        oracle.pushExposure(maker, exposureBps);

        uint256 gatedOut = _predictGated(_xycOut(), exposureBps);
        uint24 expectedFee = _expectedFeePips(exposureBps);
        uint256 expectedFinal = gatedOut - (gatedOut * expectedFee) / LPFeeLibrary.MAX_LP_FEE;

        BalanceDelta delta = _swap(true, SWAP_AMOUNT);
        assertEq(
            uint256(int256(delta.amount1())),
            expectedFinal,
            "the v4 fee must compound on top of the already-derated SwapVM output"
        );
        assertLt(expectedFinal, gatedOut, "the fee must strictly reduce what the derate alone would have given");
    }

    function test_FeeSaturatesApproachingHalt_ButNeverExceedsCeiling() public {
        uint64 exposureBps = HALT_BPS - 1; // the riskiest reading that still fills at all
        oracle.pushExposure(maker, exposureBps);
        uint24 expectedFee = _expectedFeePips(exposureBps);
        assertLe(expectedFee, MAX_FEE_PIPS, "fee must never exceed the documented ceiling");
        assertApproxEqAbs(uint256(expectedFee), uint256(MAX_FEE_PIPS), 2, "fee must be at its ceiling just below halt");

        uint256 gatedOut = _predictGated(_xycOut(), exposureBps);
        uint256 expectedFinal = gatedOut - (gatedOut * expectedFee) / LPFeeLibrary.MAX_LP_FEE;

        BalanceDelta delta = _swap(true, SWAP_AMOUNT);
        assertEq(uint256(int256(delta.amount1())), expectedFinal, "output must match the exact formula at saturation");
    }

    function test_RefreshFeeUpdatesPersistedFeeWithoutASwap() public {
        (,,, uint24 initial) = poolManager.getSlot0(poolKey.toId());
        assertEq(initial, 0, "a freshly initialized dynamic-fee pool starts at lpFee == 0 per LPFeeLibrary");

        oracle.pushExposure(maker, 6_000);
        hook.refreshFee();

        (,,, uint24 refreshed) = poolManager.getSlot0(poolKey.toId());
        assertEq(refreshed, _expectedFeePips(6_000), "refreshFee must push the current risk fee with no swap involved");
    }

    /// @notice A second pool, bound to a SEPARATE hook instance backed by the exact same maker
    /// strategy and oracle, but initialized with the plain static fee every other pool in this
    /// repo uses. Proves the dynamic-fee logic is opt-in per pool, not a global behavior change to
    /// `AquaV4Hook` -- the same source powering `CrossVenueConsistencyTest`'s bit-for-bit proof.
    function test_StaticFeePoolIsCompletelyUnaffected() public {
        address altDeployer = makeAddr("altDeployer");
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, aqua, swapVM, oracle, order);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(altDeployer, flags, type(AquaV4Hook).creationCode, constructorArgs);

        vm.prank(altDeployer);
        AquaV4Hook staticHook = new AquaV4Hook{ salt: salt }(poolManager, aqua, swapVM, oracle, order);
        assertEq(address(staticHook), hookAddress, "hook address mismatch");

        PoolKey memory staticPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(staticHook))
        });
        poolManager.initialize(staticPoolKey, TickMath.getSqrtPriceAtTick(0));
        token0.mint(address(staticHook), 100_000e18);
        token1.mint(address(staticHook), 100_000e18);

        // Zero exposure -> gate is a no-op -> the ONLY thing that could change the output from
        // plain XYC pricing is a fee. On a static-fee pool there must be none whatsoever.
        BalanceDelta delta = swapRouter.swap(
            staticPoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(SWAP_AMOUNT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        assertEq(
            uint256(int256(delta.amount1())), _xycOut(), "a static-fee pool must be byte-for-byte unaffected"
        );

        (,,, uint24 persistedFee) = poolManager.getSlot0(staticPoolKey.toId());
        assertEq(persistedFee, 0, "a static-fee pool's lpFee must never move");
    }
}
