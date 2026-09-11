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
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";

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

    /// @dev Salted variant so a single test function can ship several otherwise-identical gated
    /// strategies (each with its own fresh, undepleted pool) without their `strategyHash`es
    /// colliding -- `Controls._salt` is a verified pure no-op, so this changes nothing about the
    /// program's actual behavior.
    function gatedProgram(uint16 maxBps, uint16 haltBps, uint16 maxStaleness, bytes1 salt) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                ExposureGate._exposureGate1D,
                ExposureGateArgsBuilder.build(address(oracle), maxBps, haltBps, maxStaleness)
            ),
            p.build(Controls._salt, abi.encodePacked(salt))
        );
    }

    /// @dev Salted variant of `baselineProgram`, for the same reason as above.
    function baselineProgram(bytes1 salt) internal view returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(p.build(XYCSwap._xycSwapXD), p.build(Controls._salt, abi.encodePacked(salt)));
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

    // ===== named boundary-value tests =====
    //
    // The fuzz tests below cover the full input space as a property, but boundary values are
    // exactly where off-by-one errors hide, so each edge of the three bands (<=max / between /
    // >=halt) gets its own explicit, readable test rather than relying on the fuzzer to happen to
    // land on them.

    function test_PassThrough_AtZeroExposure() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, 0);

        (, uint256 baselineOut) = performSwap(baseline, 100e18, true);
        (, uint256 gatedOut) = performSwap(gated, 100e18, true);

        assertEq(gatedOut, baselineOut, "zero exposure must be a pure no-op");
    }

    function test_PassThrough_AtExactlyMaxThreshold() public {
        // exposureBps == maxExposureBps is specified as still within the no-op band ("at/below
        // this: no adjustment") -- this is the sharp edge of that band, not "well below" it.
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, MAX_BPS);

        (, uint256 baselineOut) = performSwap(baseline, 100e18, true);
        (, uint256 gatedOut) = performSwap(gated, 100e18, true);

        assertEq(gatedOut, baselineOut, "exposure exactly at maxExposureBps must still be untouched");
    }

    function test_Derate_JustAboveMaxThreshold() public {
        // maxExposureBps + 1 is the sharp edge of the OTHER side of that same boundary -- the
        // smallest possible derate, one bps into the band.
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, MAX_BPS + 1);

        (, uint256 baselineOut) = performSwap(baseline, 100e18, true);
        (, uint256 gatedOut) = performSwap(gated, 100e18, true);

        assertLt(gatedOut, baselineOut, "even one bps into the band must strictly derate");
    }

    function test_Derate_JustBelowHaltThreshold() public {
        // haltExposureBps - 1 is the sharp edge just before the hard revert -- the largest
        // possible derate that still fills at all, rather than reverting.
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, HALT_BPS - 1);

        (, uint256 baselineOut) = performSwap(baseline, 100e18, true);
        (, uint256 gatedOut) = performSwap(gated, 100e18, true);

        assertGt(gatedOut, 0, "one bps before halt must still produce a (heavily derated) fill");
        assertLt(gatedOut, baselineOut, "must still be strictly worse than the ungated baseline");
    }

    function test_Derate_WithTinyAmount() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, 7_000);

        (, uint256 baselineOut) = performSwap(baseline, 1e6, true);
        (, uint256 gatedOut) = performSwap(gated, 1e6, true);

        assertLe(gatedOut, baselineOut, "derate must hold even at dust-sized swap amounts");
    }

    function test_Derate_WithHugeAmount() public {
        ISwapVM.Order memory gated = createOrder(gatedProgram(MAX_BPS, HALT_BPS, NO_STALENESS_CHECK));
        ISwapVM.Order memory baseline = createOrder(baselineProgram());
        shipStrategy(gated);
        shipStrategy(baseline);

        oracle.pushExposure(maker, 7_000);

        // 900e18 against a 1_000e18-deep pool -- as large a swap as this maker's liquidity can
        // support, deliberately chosen to stress the derate math against near-maximal price impact.
        (, uint256 baselineOut) = performSwap(baseline, 900e18, true);
        (, uint256 gatedOut) = performSwap(gated, 900e18, true);

        assertLt(gatedOut, baselineOut, "derate must hold even at near-maximal swap amounts");
    }

    /// @notice Narrative walk-through of the exact claim in `ExposureGate.sol`'s contract-level
    /// comment: no matter what an oracle reports -- accurate, exaggerated, or an outright lie up
    /// to the maximum value `ExposureOracle` will even accept -- the fill for a FIXED swap amount
    /// against a FRESH, identically-sized pool never goes up as the reported exposure goes up, and
    /// past the halt threshold it stops filling at all rather than ever reversing direction. The
    /// final step shows staleness is enforced independently of the exposure value itself: a
    /// reading that would otherwise be perfectly safe (0%) is still rejected once it's too old to
    /// trust, rather than being assumed safe by default.
    function test_MaliciousOracle_CanOnlyEverMakeFillMoreConservative() public {
        uint16 maxStaleness = 60;
        uint256 amount = 1e18;

        // Step 1: 0% exposure -- the gate is a strict no-op, fill matches the ungated baseline.
        ISwapVM.Order memory gated0 = createOrder(gatedProgram(MAX_BPS, HALT_BPS, maxStaleness, hex"00"));
        ISwapVM.Order memory baseline0 = createOrder(baselineProgram(hex"01"));
        shipStrategy(gated0);
        shipStrategy(baseline0);
        oracle.pushExposure(maker, 0);
        (, uint256 baselineOut) = performSwap(baseline0, amount, true);
        (, uint256 outAt0) = performSwap(gated0, amount, true);
        assertEq(outAt0, baselineOut, "0%: untouched, matches the ungated baseline exactly");

        // Step 2: 70% exposure -- inside the derate band, strictly worse than the baseline, and
        // no better than step 1 (a "worse-looking" reading can only pull the fill down further).
        ISwapVM.Order memory gated70 = createOrder(gatedProgram(MAX_BPS, HALT_BPS, maxStaleness, hex"02"));
        shipStrategy(gated70);
        oracle.pushExposure(maker, 7_000);
        (, uint256 outAt70) = performSwap(gated70, amount, true);
        assertLt(outAt70, outAt0, "70%: must be strictly worse than the 0% fill");
        assertLt(outAt70, baselineOut, "70%: must be strictly worse than the ungated baseline");

        // Step 3: 90% exposure (the halt threshold) -- no fill at all, not even a very bad one.
        ISwapVM.Order memory gated90 = createOrder(gatedProgram(MAX_BPS, HALT_BPS, maxStaleness, hex"03"));
        shipStrategy(gated90);
        oracle.pushExposure(maker, HALT_BPS);
        vm.expectRevert(haltError(HALT_BPS));
        performSwap(gated90, amount, true);

        // Step 4: 10_000 bps (100%) -- the maximum value ExposureOracle will even accept (a
        // "malicious" keeper cannot report anything worse than this on-chain). Still just a
        // revert, never a fill, let alone a favorable one -- confirming there is no value the
        // oracle can report, however extreme, that ever lets the taker do better than step 1.
        ISwapVM.Order memory gatedMax = createOrder(gatedProgram(MAX_BPS, HALT_BPS, maxStaleness, hex"04"));
        shipStrategy(gatedMax);
        oracle.pushExposure(maker, 10_000);
        vm.expectRevert(haltError(10_000));
        performSwap(gatedMax, amount, true);

        // Step 5: a reading that would, on its face, be perfectly safe (0%) is still rejected once
        // stale -- an absent or frozen oracle fails closed (no fill) rather than defaulting to
        // "assume safe."
        ISwapVM.Order memory gatedStale = createOrder(gatedProgram(MAX_BPS, HALT_BPS, maxStaleness, hex"05"));
        shipStrategy(gatedStale);
        oracle.pushExposure(maker, 0);
        (, uint256 updatedAt) = oracle.exposureOf(maker);
        vm.warp(block.timestamp + maxStaleness + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ExposureGate.ExposureGateOracleStale.selector, block.timestamp, updatedAt, maxStaleness)
        );
        performSwap(gatedStale, amount, true);
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
