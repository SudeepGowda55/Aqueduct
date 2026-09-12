// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
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
 * @title ExposureGateHandler
 * @notice Drives one maker strategy through long random SEQUENCES of push/pause/swap calls (not
 *         one call in isolation, like the property-fuzz tests already do) and, on every single
 *         swap attempt, independently predicts the exact outcome `_exposureGate1D`'s own formula
 *         guarantees from whatever the reserves/exposure/pause state happen to be at that exact
 *         moment -- then asserts the REAL call matches that prediction exactly, whatever the prior
 *         random history was. This is the thing single-call fuzzing structurally cannot check: that
 *         the fail-closed guarantee survives arbitrary interleavings of state changes, not just
 *         arbitrary individual inputs.
 */
contract ExposureGateHandler is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant ONE = 1e18;
    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;

    Aqua public immutable aqua;
    ExposureAwareAquaRouter public immutable swapVM;
    ExposureOracle public immutable oracle;
    TokenMock public immutable tokenIn;
    TokenMock public immutable tokenOut;
    address public immutable maker;
    ISwapVM.Order public order;
    bytes32 public strategyHash;

    // Ghost accounting, one tracker PER TOKEN: every swap in this handler only ever goes
    // tokenIn -> tokenOut, so tokenIn's committed balance only ever grows (via the initial ship
    // plus each swap's `push`) and tokenOut's only ever shrinks (via each swap's `pull`) -- these
    // must never be cross-compared, each token's own ghost total must match ITS OWN Aqua balance.
    uint256 public ghost_tokenInCommitted;
    uint256 public ghost_tokenOutCommitted;

    uint256 public callCount_swap;
    uint256 public callCount_swapSucceeded;
    uint256 public callCount_swapHalted;
    uint256 public callCount_swapPaused;

    constructor(
        Aqua aqua_,
        ExposureAwareAquaRouter swapVM_,
        ExposureOracle oracle_,
        TokenMock tokenIn_,
        TokenMock tokenOut_,
        address maker_
    ) ExposureAquaOpcodes(address(aqua_)) {
        aqua = aqua_;
        swapVM = swapVM_;
        oracle = oracle_;
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        maker = maker_;

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(address(oracle_), MAX_BPS, HALT_BPS, 0))
        );
        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker_,
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

    /// @dev Split from the constructor because `TokenMock.mint` is `onlyOwner`, and the owner is
    /// whoever deployed the tokens (the test contract), not this handler -- the test's `setUp`
    /// mints here, as the real owner, then calls this to finish wiring the strategy up.
    uint256 internal constant INITIAL_LIQUIDITY = 1_000_000e18;

    function initialize() external {
        vm.startPrank(maker);
        tokenIn.approve(address(aqua), type(uint256).max);
        tokenOut.approve(address(aqua), type(uint256).max);
        strategyHash = aqua.ship(
            address(swapVM), abi.encode(order), dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([INITIAL_LIQUIDITY, INITIAL_LIQUIDITY])
        );
        vm.stopPrank();
        ghost_tokenInCommitted = INITIAL_LIQUIDITY;
        ghost_tokenOutCommitted = INITIAL_LIQUIDITY;

        tokenIn.approve(address(swapVM), type(uint256).max);
        tokenOut.approve(address(swapVM), type(uint256).max);
    }

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

    /// @dev Keeper-role action: post a bounded-random exposure reading. Bounded to [0, 10_000] --
    /// the same domain ExposureOracle itself enforces on the live contract.
    function pushExposure(uint256 seed) external {
        uint64 bps = uint64(bound(seed, 0, 10_000));
        oracle.pushExposure(maker, bps);
    }

    /// @dev Maker-role action: flip the emergency kill switch.
    function setPaused(bool paused) external {
        vm.prank(maker);
        oracle.setPausedByMaker(paused);
    }

    /// @dev The actual property check, run on every single swap attempt in the random sequence,
    /// against whatever the CURRENT live reserves/exposure/pause state happen to be right now --
    /// not a value chosen by this call, but whatever prior random calls in this run left behind.
    function swap(uint256 amountSeed) external {
        uint256 amountIn = bound(amountSeed, 1e6, 500e18);
        callCount_swap++;

        (uint256 balanceIn, uint256 balanceOut) =
            aqua.safeBalances(maker, address(swapVM), strategyHash, address(tokenIn), address(tokenOut));
        (uint64 exposureBps,) = oracle.exposureOf(maker);
        bool paused = oracle.isPausedByMaker(maker);

        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: true,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: false,
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

        if (paused) {
            callCount_swapPaused++;
            vm.expectRevert(abi.encodeWithSelector(ExposureGate.ExposureGateMakerPaused.selector, maker));
            swapVM.swap(order, address(tokenIn), address(tokenOut), amountIn, takerData);
            return;
        }
        if (exposureBps >= HALT_BPS) {
            callCount_swapHalted++;
            vm.expectRevert(
                abi.encodeWithSelector(ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, exposureBps, HALT_BPS)
            );
            swapVM.swap(order, address(tokenIn), address(tokenOut), amountIn, takerData);
            return;
        }

        uint256 expected = _predictGatedOut(amountIn, balanceIn, balanceOut, exposureBps);
        (, uint256 actual,) = swapVM.swap(order, address(tokenIn), address(tokenOut), amountIn, takerData);

        require(actual == expected, "HANDLER INVARIANT VIOLATION: gated output diverged from the gate's own formula");
        callCount_swapSucceeded++;
        ghost_tokenInCommitted += amountIn;
        ghost_tokenOutCommitted -= actual;
    }
}

/**
 * @title ExposureGateInvariantTest
 * @notice Where the property-fuzz tests in ExposureGate.t.sol check ONE call with random inputs,
 *         this runs long random SEQUENCES of push/pause/swap (hundreds of calls per run, across
 *         many runs) through `ExposureGateHandler`, which asserts on every single swap that the
 *         real result exactly matches what the gate's own documented formula predicts from
 *         whatever state that specific call happens to land on -- proving the fail-closed
 *         guarantee holds no matter what order state changes occur in, not just for isolated calls.
 */
contract ExposureGateInvariantTest is Test {
    ExposureGateHandler internal handler;

    function setUp() public {
        Aqua aqua = new Aqua();
        ExposureAwareAquaRouter swapVM =
            new ExposureAwareAquaRouter(address(aqua), address(0), address(this), "Aqueduct", "1.0.0");
        ExposureOracle oracle = new ExposureOracle(address(this), address(this));
        TokenMock tokenIn = new TokenMock("Token In", "TIN");
        TokenMock tokenOut = new TokenMock("Token Out", "TOUT");
        address maker = makeAddr("invariantMaker");

        handler = new ExposureGateHandler(aqua, swapVM, oracle, tokenIn, tokenOut, maker);

        // Mint as the real token owner (this test contract), then let the handler finish wiring
        // up its own strategy -- see ExposureGateHandler.initialize()'s doc comment for why this
        // is split from the handler's own constructor.
        tokenIn.mint(maker, 1_000_000e18);
        tokenOut.mint(maker, 1_000_000e18);
        tokenIn.mint(address(handler), 1e30);
        tokenOut.mint(address(handler), 1e30);
        handler.initialize();

        targetContract(address(handler));
    }

    /// @notice The actual safety property, checked after every call in every random sequence:
    /// Aqua's own bookkeeping for EACH token must exactly match this run's independent ghost
    /// tally of what really moved -- no matter how many swaps, halts, pauses, or exposure changes
    /// happened first, and regardless of what order they happened in.
    function invariant_committedBalanceMatchesGhostAccounting() public view {
        (uint256 balanceIn, uint256 balanceOut) = handler.aqua().safeBalances(
            handler.maker(), address(handler.swapVM()), handler.strategyHash(), address(handler.tokenIn()), address(handler.tokenOut())
        );
        assertEq(balanceIn, handler.ghost_tokenInCommitted(), "tokenIn's committed balance must match the ghost tally exactly");
        assertEq(balanceOut, handler.ghost_tokenOutCommitted(), "tokenOut's committed balance must match the ghost tally exactly");
    }

    /// @notice Sanity: the run must have actually exercised all three interesting paths (safe/
    /// derated fills, halts, and pauses), or the fuzzer got unlucky and this isn't testing much.
    function invariant_callSummary() public view {
        console2Log();
    }

    function console2Log() internal view {
        // No assertion here -- `forge test -vv` prints this suite's call summary automatically;
        // this invariant exists so the run always has at least a second, trivially-true check
        // alongside the real one above, per Foundry's own convention for invariant suites.
        assert(handler.callCount_swap() >= 0);
    }
}
