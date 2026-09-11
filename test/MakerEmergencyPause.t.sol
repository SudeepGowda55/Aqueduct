// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

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

/**
 * @title MakerEmergencyPauseTest
 * @notice Proves the maker's own kill switch (`ExposureOracle.setPausedByMaker`): if a maker
 *         distrusts the exposure feed itself -- not just one bad reading, but the pipeline or the
 *         keeper key behind it -- they can halt every strategy they've shipped against that oracle
 *         themselves, immediately, with no dependency on the keeper, this project's deployer, or
 *         staleness ever catching up. This is a THIRD, independent layer on top of keeper
 *         authorization (only the keeper can post readings) and gate monotonicity (even an
 *         authorized-but-wrong reading can only derate, never improve, a fill) -- see the
 *         contract-level comment on `ExposureGate` for how the three fit together.
 */
contract MakerEmergencyPauseTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant INITIAL_BALANCE = 1_000e18;
    uint256 internal constant SWAP_AMOUNT = 10e18;
    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;

    Aqua public immutable aqua = new Aqua();
    ExposureAwareAquaRouter public swapVM;
    ExposureOracle public oracle;
    TokenMock public tokenIn;
    TokenMock public tokenOut;
    MockTaker public taker;
    address public maker;
    ISwapVM.Order public order;

    constructor() ExposureAquaOpcodes(address(aqua)) { }

    function setUp() public {
        tokenIn = new TokenMock("Token In", "TIN");
        tokenOut = new TokenMock("Token Out", "TOUT");
        swapVM = new ExposureAwareAquaRouter(address(aqua), address(0), address(this), "Aqueduct", "1.0.0");
        oracle = new ExposureOracle(address(this), address(this));
        maker = makeAddr("maker");
        taker = new MockTaker(aqua, swapVM, address(this));
        tokenIn.mint(address(taker), 1e30);
        tokenOut.mint(address(taker), 1e30);

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

        tokenIn.mint(maker, INITIAL_BALANCE);
        tokenOut.mint(maker, INITIAL_BALANCE);
        vm.startPrank(maker);
        tokenIn.approve(address(aqua), type(uint256).max);
        tokenOut.approve(address(aqua), type(uint256).max);
        aqua.ship(
            address(swapVM), abi.encode(order), dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([INITIAL_BALANCE, INITIAL_BALANCE])
        );
        vm.stopPrank();
    }

    function _swap() internal returns (uint256 amountIn, uint256 amountOut) {
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
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
        return taker.swap(order, address(tokenIn), address(tokenOut), SWAP_AMOUNT, takerData);
    }

    function test_MakerCanPauseTheirOwnStrategyEvenAtZeroExposure() public {
        // 0% exposure -- ordinarily a complete no-op, the safest possible reading.
        oracle.pushExposure(maker, 0);
        (, uint256 outBeforePause) = _swap();
        assertGt(outBeforePause, 0, "sanity: unpaused, safe exposure fills normally");

        // The maker pauses themselves -- nothing about the exposure reading changed, it's still
        // 0%. Every fill against this oracle must now halt anyway.
        vm.prank(maker);
        oracle.setPausedByMaker(true);

        vm.expectRevert(abi.encodeWithSelector(ExposureGate.ExposureGateMakerPaused.selector, maker));
        _swap();
    }

    function test_PauseOverridesEvenAFreshSafeReading() public {
        vm.prank(maker);
        oracle.setPausedByMaker(true);

        // Keeper keeps posting perfectly fresh, perfectly safe readings -- doesn't matter. The
        // maker's own kill switch is checked first and wins regardless.
        oracle.pushExposure(maker, 0);
        vm.expectRevert(abi.encodeWithSelector(ExposureGate.ExposureGateMakerPaused.selector, maker));
        _swap();
    }

    function test_UnpauseRestoresNormalGating() public {
        vm.prank(maker);
        oracle.setPausedByMaker(true);
        oracle.pushExposure(maker, 1_000);
        vm.expectRevert(abi.encodeWithSelector(ExposureGate.ExposureGateMakerPaused.selector, maker));
        _swap();

        vm.prank(maker);
        oracle.setPausedByMaker(false);
        (, uint256 amountOut) = _swap();
        assertGt(amountOut, 0, "unpausing must restore normal exposure-gated behavior");
    }

    function test_OnlyTheMakerThemselvesCanPauseTheirOwnStrategy() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        oracle.setPausedByMaker(true);

        // The attacker paused THEIR OWN (nonexistent) strategy, not the maker's -- msg.sender
        // scoping means there is no code path for anyone but the maker to pause the maker.
        assertFalse(oracle.isPausedByMaker(maker), "an attacker must not be able to pause someone else's strategy");

        oracle.pushExposure(maker, 0);
        (, uint256 amountOut) = _swap();
        assertGt(amountOut, 0, "maker's strategy must be entirely unaffected by another address's pause flag");
    }
}
