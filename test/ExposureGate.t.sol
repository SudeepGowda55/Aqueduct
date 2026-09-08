// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { MockTaker } from "@1inch/swap-vm/test/mocks/MockTaker.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";

import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import { dynamic } from "@1inch/swap-vm/test/utils/Dynamic.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";

/// @title ExposureGateTest
/// @notice Proves the central safety claim of the `_exposureGate1D` opcode: it can only ever
///         shrink a taker's fill (or halt it entirely) relative to what the underlying SwapVM
///         program would have produced without it. It can never improve a fill. The fuzz tests
///         at the bottom check this as a property across the whole exposure/amount input space,
///         not just at a handful of example points.
/// @dev Test contract inherits ExposureAquaOpcodes purely to get compile-time access to the named
///      internal instruction functions (XYCSwap._xycSwapXD, ExposureGate._exposureGate1D, etc.)
///      for ProgramBuilder -- the actual router under test is deployed separately, exactly the
///      pattern 1inch's own AquaAccounting.t.sol uses.
contract ExposureGateTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant INITIAL_BALANCE = 1_000e18;
    uint16 internal constant MAX_BPS = 5_000; // 50%: below this, no adjustment
    uint16 internal constant HALT_BPS = 9_000; // 90%: at/above this, hard revert
    uint16 internal constant NO_STALENESS_CHECK = 0;

    Aqua public immutable aqua = new Aqua();
    ExposureAwareAquaRouter public swapVM;
    ExposureOracle public oracle;
    TokenMock public tokenIn;
    TokenMock public tokenOut;
    MockTaker public taker;
    address public maker;

    constructor() ExposureAquaOpcodes(address(aqua)) { }

    function setUp() public {
        tokenIn = new TokenMock("Token In", "TIN");
        tokenOut = new TokenMock("Token Out", "TOUT");

        swapVM = new ExposureAwareAquaRouter(address(aqua), address(0), address(this), "Aqueduct", "1.0.0");
        oracle = new ExposureOracle(address(this), address(this));

        maker = makeAddr("maker");
        taker = new MockTaker(aqua, swapVM, address(this));

        // Minted generously: near the halt boundary the derate factor can shrink to roughly
        // 1/4000th (the finest step of a uint16 bps band), so a fuzzed exact-out swap can
        // legitimately require several thousand times the nominal swap amount as tokenIn.
        tokenIn.mint(address(taker), 1e33);
        tokenOut.mint(address(taker), 1e33);
    }

    // ===== program builders =====

    function baselineProgram() internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return p.build(XYCSwap._xycSwapXD);
    }

    function gatedProgram(uint16 maxBps, uint16 haltBps, uint16 maxStaleness) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                ExposureGate._exposureGate1D,
                ExposureGateArgsBuilder.build(address(oracle), maxBps, haltBps, maxStaleness)
            )
        );
    }

    // ===== order / strategy / swap helpers (mirrors 1inch's own AquaAccounting.t.sol) =====

    function createOrder(bytes memory program) internal view returns (ISwapVM.Order memory) {
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

    function shipStrategy(ISwapVM.Order memory order) internal returns (bytes32 orderHash) {
        orderHash = swapVM.hash(order);

        tokenIn.mint(maker, INITIAL_BALANCE);
        tokenOut.mint(maker, INITIAL_BALANCE);

        vm.startPrank(maker);
        tokenIn.approve(address(aqua), type(uint256).max);
        tokenOut.approve(address(aqua), type(uint256).max);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([INITIAL_BALANCE, INITIAL_BALANCE])
        );
        vm.stopPrank();

        assertEq(strategyHash, orderHash, "strategy hash mismatch");
    }

    function performSwap(ISwapVM.Order memory order, uint256 amount, bool isExactIn) internal returns (uint256 amountIn, uint256 amountOut) {
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));

        return taker.swap(order, address(tokenIn), address(tokenOut), amount, takerData);
    }

    function haltError(uint256 exposureBps) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, uint64(exposureBps), HALT_BPS
        );
    }

    // ===== example-based tests =====

    function test_PassThrough_WhenExposureBelowMax() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, 1_000); // 10%, well below MAX_BPS

        (, uint256 baselineOut) = performSwap(baseline, 100e18, true);
        (, uint256 gatedOut) = performSwap(gated, 100e18, true);

        assertEq(gatedOut, baselineOut, "no adjustment expected below max exposure");
    }

    function test_Derate_WhenExposureBetweenMaxAndHalt_ExactIn() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, 7_000); // halfway through the 5000 -> 9000 band

        (, uint256 baselineOut) = performSwap(baseline, 100e18, true);
        (, uint256 gatedOut) = performSwap(gated, 100e18, true);

        // derateFactor = 1e18 - (2000 * 1e18) / 4000 = 0.5e18
        uint256 expected = (baselineOut * 5e17) / 1e18;
        assertEq(gatedOut, expected, "derate math mismatch");
        assertLt(gatedOut, baselineOut, "derated fill must be strictly worse for the taker");
    }

    function test_Derate_WhenExposureBetweenMaxAndHalt_ExactOut() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, 7_000);

        (uint256 baselineIn,) = performSwap(baseline, 100e18, false);
        (uint256 gatedIn,) = performSwap(gated, 100e18, false);

        uint256 expected = Math.ceilDiv(baselineIn * 1e18, 5e17);
        assertEq(gatedIn, expected, "derate math mismatch (exact-out)");
        assertGt(gatedIn, baselineIn, "derated fill must require strictly more input from the taker");
    }

    function test_Reverts_WhenExposureAtHaltThreshold() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        shipStrategy(gated);

        oracle.pushExposure(maker, HALT_BPS);

        vm.expectRevert(haltError(HALT_BPS));
        performSwap(gated, 100e18, true);
    }

    function test_Reverts_WhenExposureAboveHalt() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        shipStrategy(gated);

        oracle.pushExposure(maker, 10_000);

        vm.expectRevert(haltError(10_000));
        performSwap(gated, 100e18, true);
    }

    function test_Reverts_WhenOracleReadingStale() public {
        uint16 maxStaleness = 60;
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, maxStaleness));
        shipStrategy(gated);

        oracle.pushExposure(maker, 1_000);
        (, uint256 updatedAt) = oracle.exposureOf(maker);
        vm.warp(block.timestamp + maxStaleness + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ExposureGate.ExposureGateOracleStale.selector, block.timestamp, updatedAt, maxStaleness)
        );
        performSwap(gated, 100e18, true);
    }

    // ===== property test: the load-bearing claim =====
    //
    // Across the entire exposure/amount input space, the gated fill is never better for the
    // taker than the ungated baseline: exact-in output never goes up, exact-out required input
    // never goes down, and above the halt threshold it reverts outright. A wrong, stale (were it
    // not already blocked above), or even maliciously-signed oracle reading therefore cannot be
    // used to make a maker over-quote -- only to make it (needlessly) more conservative.

    function testFuzz_GatedNeverBeatsBaseline_ExactIn(uint256 exposureBpsSeed, uint256 swapAmountSeed) public {
        uint16 exposureBps = uint16(bound(exposureBpsSeed, 0, 10_000));
        uint256 swapAmount = bound(swapAmountSeed, 1e6, 400e18);

        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        (, uint256 baselineOut) = performSwap(baseline, swapAmount, true);

        oracle.pushExposure(maker, exposureBps);

        if (exposureBps >= HALT_BPS) {
            vm.expectRevert(haltError(exposureBps));
            performSwap(gated, swapAmount, true);
        } else {
            (, uint256 gatedOut) = performSwap(gated, swapAmount, true);
            assertLe(gatedOut, baselineOut, "gate must never give the taker more than the ungated baseline");
        }
    }

    function testFuzz_GatedNeverBeatsBaseline_ExactOut(uint256 exposureBpsSeed, uint256 swapAmountSeed) public {
        uint16 exposureBps = uint16(bound(exposureBpsSeed, 0, 10_000));
        uint256 swapAmount = bound(swapAmountSeed, 1e6, 400e18);

        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        (uint256 baselineIn,) = performSwap(baseline, swapAmount, false);

        oracle.pushExposure(maker, exposureBps);

        if (exposureBps >= HALT_BPS) {
            vm.expectRevert(haltError(exposureBps));
            performSwap(gated, swapAmount, false);
        } else {
            (uint256 gatedIn,) = performSwap(gated, swapAmount, false);
            assertGe(gatedIn, baselineIn, "gate must never require the taker to pay less than the ungated baseline");
        }
    }
}
