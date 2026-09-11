// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import { dynamic } from "@1inch/swap-vm/test/utils/Dynamic.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";
import { AquaV4Hook } from "../src/hooks/AquaV4Hook.sol";

/**
 * @title EndToEndAggregateExposureTest
 * @notice The single, connected chain every other test in this repo only proves one link of at a
 *         time, wired together here end to end:
 *
 *           Strategy A ($400) ─┐
 *           Strategy B ($300) ─┼─► aggregate exposure ─► ExposureOracle ─┬─► SwapVM  ─► derated/halt
 *           Strategy C ($200) ─┘        (900/1000=90%)                   └─► Uniswap v4 ─► SAME result
 *
 *         `test/MultiStrategyExposure.t.sol` proves the aggregation step in isolation (multiple
 *         strategies -> one exposure number). `test/CrossVenueConsistency.t.sol` proves the
 *         venue-consistency step in isolation (one exposure number -> two venues, identical
 *         result). This test proves they compose: strategy A is the SAME Aqua strategy backing
 *         BOTH a direct SwapVM integration and a real Uniswap v4 pool, and the exposure number
 *         gating both of them is a genuine sum across A, B and C -- not a value invented for this
 *         test.
 *
 * @dev Because A's pool is shared (not isolated per venue, unlike CrossVenueConsistencyTest --
 *      here the point is literally that ONE strategy backs both venues), a swap on one venue
 *      changes the reserves the other venue's next swap prices against. Rather than sidestep that
 *      with a second matched-depth pool, this test computes the OTHER kind of proof: at each step,
 *      the actual output on each venue is checked against the exact value `_exposureGate1D`'s own
 *      documented formula (XYC pricing, then the derate factor) predicts from that venue's own
 *      live, just-read reserves -- so both venues are independently proven to obey the identical
 *      formula, driven by the identical oracle reading, regardless of which one happened to run
 *      first and shift the shared pool underneath the other.
 */
contract EndToEndAggregateExposureTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant WALLET_BALANCE = 1_000e18;
    uint256 internal constant STRATEGY_A = 400e18;
    uint256 internal constant STRATEGY_B = 300e18;
    uint256 internal constant STRATEGY_C = 200e18;
    uint256 internal constant SWAP_AMOUNT = 10e18;

    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant ONE = 1e18;
    bytes internal constant EOA_TAKER_DATA = hex"00000000000000000000000000000000000000000041";

    Aqua public immutable aqua = new Aqua();
    IPoolManager public poolManager;
    ExposureAwareAquaRouter public swapVM;
    ExposureOracle public oracle;
    PoolSwapTest public swapRouter;
    TokenMock public tokenIn;
    TokenMock public tokenOut;
    AquaV4Hook public hook;
    address public maker;

    ISwapVM.Order public orderA;
    bytes32 public hashA;
    bytes32 public hashB;
    bytes32 public hashC;
    PoolKey public poolKey;

    constructor() ExposureAquaOpcodes(address(aqua)) { }

    function setUp() public {
        poolManager = IPoolManager(vm.deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapVM = new ExposureAwareAquaRouter(address(aqua), address(0), address(this), "Aqueduct", "1.0.0");
        oracle = new ExposureOracle(address(this), address(this));
        maker = makeAddr("maker");

        TokenMock a = new TokenMock("Token A", "TKA");
        TokenMock b = new TokenMock("Token B", "TKB");
        (tokenIn, tokenOut) = address(a) < address(b) ? (a, b) : (b, a);

        // The maker's one real wallet balance -- Aqua's commitments below are allowance-style, so
        // nothing stops A+B+C's commitments from summing to more than this (see
        // MultiStrategyExposure.t.sol's contract-level comment for why that's the actual point).
        tokenIn.mint(maker, WALLET_BALANCE);
        tokenOut.mint(maker, WALLET_BALANCE);
        vm.startPrank(maker);
        tokenIn.approve(address(aqua), type(uint256).max);
        tokenOut.approve(address(aqua), type(uint256).max);
        vm.stopPrank();

        orderA = _order(hex"0a");
        hashA = _ship(orderA, STRATEGY_A);
        hashB = _ship(_order(hex"0b"), STRATEGY_B);
        hashC = _ship(_order(hex"0c"), STRATEGY_C);

        // ---- Wire a real Uniswap v4 pool backed by strategy A -- the SAME strategy the direct
        //      SwapVM leg below also swaps against. ----
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, aqua, swapVM, orderA);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AquaV4Hook).creationCode, constructorArgs);
        hook = new AquaV4Hook{ salt: salt }(poolManager, aqua, swapVM, orderA);
        assertEq(address(hook), hookAddress, "hook address mismatch");

        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenIn)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        swapRouter = new PoolSwapTest(poolManager);
        tokenIn.mint(address(hook), 1_000e18);
        tokenOut.mint(address(hook), 1_000e18);

        tokenIn.mint(address(this), 1_000_000e18);
        tokenOut.mint(address(this), 1_000_000e18);
        tokenIn.approve(address(swapVM), type(uint256).max);
        tokenIn.approve(address(swapRouter), type(uint256).max);
    }

    function _order(bytes1 salt) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(address(oracle), MAX_BPS, HALT_BPS, 0)),
            p.build(Controls._salt, abi.encodePacked(salt))
        );
        return MakerTraitsLib.build(MakerTraitsLib.Args({
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
    }

    function _ship(ISwapVM.Order memory order, uint256 commitment) internal returns (bytes32 strategyHash) {
        bytes32 orderHash = swapVM.hash(order);
        vm.prank(maker);
        strategyHash = aqua.ship(
            address(swapVM), abi.encode(order), dynamic([address(tokenIn), address(tokenOut)]), dynamic([commitment, commitment])
        );
        assertEq(strategyHash, orderHash, "strategy hash mismatch");
    }

    function _dock(bytes32 strategyHash) internal {
        vm.prank(maker);
        aqua.dock(address(swapVM), strategyHash, dynamic([address(tokenIn), address(tokenOut)]));
    }

    /// @dev The aggregation `keeper/pushExposure.ts` performs for real: sum of every active
    /// strategy's committed amount for this token, divided by the maker's real wallet balance.
    function _aggregateExposureBps(uint256 totalCommitted) internal pure returns (uint64) {
        return uint64((totalCommitted * 10_000) / WALLET_BALANCE);
    }

    /// @dev Exactly `_exposureGate1D`'s own documented formula (see ExposureGate.sol): price via
    /// the XYC curve first, then apply the linear derate factor. Used to independently predict
    /// each venue's output from ITS OWN live reserves, rather than assuming the two venues' pools
    /// are at matching depth.
    function _predictGatedOut(uint256 amountIn, uint256 balanceIn, uint256 balanceOut, uint64 exposureBps)
        internal
        pure
        returns (uint256)
    {
        uint256 xycOut = (amountIn * balanceOut) / (balanceIn + amountIn);
        if (exposureBps <= MAX_BPS) return xycOut;
        uint256 overage = exposureBps - MAX_BPS;
        uint256 band = HALT_BPS - MAX_BPS;
        uint256 derateFactor = ONE - (overage * ONE) / band;
        return (xycOut * derateFactor) / ONE;
    }

    function _reservesA() internal view returns (uint256 balanceIn, uint256 balanceOut) {
        return aqua.safeBalances(maker, address(swapVM), hashA, address(tokenIn), address(tokenOut));
    }

    function _swapDirect(uint256 amount) internal returns (uint256 amountOut) {
        (, amountOut,) = swapVM.swap(orderA, address(tokenIn), address(tokenOut), amount, EOA_TAKER_DATA);
    }

    function _swapV4(uint256 amount) internal returns (uint256 amountOut) {
        uint256 before = tokenOut.balanceOf(address(this));
        swapRouter.swap(
            poolKey,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        amountOut = tokenOut.balanceOf(address(this)) - before;
    }

    function _haltError(uint64 exposureBps) internal view returns (bytes memory) {
        return abi.encodeWithSelector(ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, exposureBps, HALT_BPS);
    }

    function _wrappedHaltError(uint64 exposureBps) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector, address(hook), IHooks.beforeSwap.selector, _haltError(exposureBps), hex"a9e35b2f"
        );
    }

    /// @notice The full chain, step by step: three real Aqua strategies combine into one
    /// aggregate exposure number; that number is pushed to the one oracle both venues read; and
    /// at every exposure band (halt, derate, safe) the SAME strategy A produces the mechanically
    /// correct, formula-predicted result on BOTH the direct SwapVM path and the real Uniswap v4
    /// pool backing it.
    function test_MultiStrategyAggregate_GatesBothVenuesIdentically() public {
        // ---- Step 1: 900/1000 = 90% aggregate (A+B+C) -> HALT on both venues. ----
        uint64 haltAggregate = _aggregateExposureBps(STRATEGY_A + STRATEGY_B + STRATEGY_C);
        assertEq(haltAggregate, 9_000, "sanity: (400+300+200)/1000 = 90%");
        oracle.pushExposure(maker, haltAggregate);

        vm.expectRevert(_haltError(haltAggregate));
        _swapDirect(SWAP_AMOUNT);

        // Calls `swapRouter.swap` directly rather than through `_swapV4` -- `vm.expectRevert`
        // only catches the very NEXT call, and `_swapV4`'s own `balanceOf` pre-read (needed to
        // compute a delta on a SUCCESSFUL swap) would otherwise be mistaken for it.
        vm.expectRevert(_wrappedHaltError(haltAggregate));
        swapRouter.swap(
            poolKey,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );

        // ---- Step 2: dock C -> (400+300)/1000 = 70% aggregate -> DERATE on both venues. ----
        _dock(hashC);
        uint64 derateAggregate = _aggregateExposureBps(STRATEGY_A + STRATEGY_B);
        assertEq(derateAggregate, 7_000, "sanity: (400+300)/1000 = 70%");
        oracle.pushExposure(maker, derateAggregate);

        (uint256 balIn, uint256 balOut) = _reservesA();
        uint256 expectedDirect = _predictGatedOut(SWAP_AMOUNT, balIn, balOut, derateAggregate);
        uint256 actualDirect = _swapDirect(SWAP_AMOUNT);
        assertEq(actualDirect, expectedDirect, "direct leg must match the gate's own formula exactly at 70% aggregate");
        assertLt(actualDirect, (SWAP_AMOUNT * balOut) / (balIn + SWAP_AMOUNT), "70% must still derate vs the ungated curve");

        // Re-read: the direct swap above just changed strategy A's own reserves.
        (balIn, balOut) = _reservesA();
        uint256 expectedV4 = _predictGatedOut(SWAP_AMOUNT, balIn, balOut, derateAggregate);
        uint256 actualV4 = _swapV4(SWAP_AMOUNT);
        assertEq(actualV4, expectedV4, "v4 leg must match the SAME gate formula exactly, from ITS OWN current reserves");

        // ---- Step 3: dock B too -> 400/1000 = 40% aggregate -> SAFE (no-op) on both venues. ----
        _dock(hashB);
        uint64 safeAggregate = _aggregateExposureBps(STRATEGY_A);
        assertEq(safeAggregate, 4_000, "sanity: 400/1000 = 40%");
        oracle.pushExposure(maker, safeAggregate);

        (balIn, balOut) = _reservesA();
        uint256 expectedDirectSafe = _predictGatedOut(SWAP_AMOUNT, balIn, balOut, safeAggregate);
        uint256 actualDirectSafe = _swapDirect(SWAP_AMOUNT);
        assertEq(actualDirectSafe, expectedDirectSafe, "direct leg must be an exact no-op at 40% aggregate");
        assertEq(
            actualDirectSafe, (SWAP_AMOUNT * balOut) / (balIn + SWAP_AMOUNT), "40% aggregate must match the raw ungated curve exactly"
        );

        (balIn, balOut) = _reservesA();
        uint256 expectedV4Safe = _predictGatedOut(SWAP_AMOUNT, balIn, balOut, safeAggregate);
        uint256 actualV4Safe = _swapV4(SWAP_AMOUNT);
        assertEq(actualV4Safe, expectedV4Safe, "v4 leg must ALSO be an exact no-op at the same 40% aggregate");
    }
}
