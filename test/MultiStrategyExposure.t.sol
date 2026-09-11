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
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";

import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import { dynamic } from "@1inch/swap-vm/test/utils/Dynamic.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";

/**
 * @title MultiStrategyExposureTest
 * @notice Proves the actual thesis of this whole project -- Aqua's "multiplier effect" -- rather
 *         than just the opcode's local math. One maker wallet ships THREE separate Aqua
 *         strategies against the same pair of tokens: $400, $300 and $200 worth of committed
 *         liquidity, all backed by the exact same $1,000 real wallet balance (Aqua's balances are
 *         allowance-style commitments, not custody -- `ship()` moves no tokens, so nothing
 *         on-chain stops a maker from over-committing this way, see `Aqua.ship` and the README's
 *         Graph section). Nothing about any ONE strategy looks dangerous in isolation -- the
 *         smallest, strategy C, only ever claims 20% of the wallet. The risk only exists in
 *         aggregate: $400 + $300 + $200 = $900 committed against a $1,000 wallet is 90% exposure,
 *         and that number does not belong to any single strategy, it belongs to the maker.
 *
 * @dev The on-chain contracts here don't compute that aggregate themselves -- by design, that
 *      aggregation is the off-chain Graph pipeline's job (see the README's "The Graph pipeline"
 *      section and `keeper/pushExposure.ts`, which does exactly this sum-across-strategies
 *      computation for real against subgraph data). What this test proves on-chain is the other
 *      half of the claim: once that aggregate is pushed to `ExposureOracle` for the maker, EVERY
 *      strategy that maker has shipped is gated by it identically -- including the smallest one
 *      that, judged on its own commitment alone, would look perfectly safe. The three committed
 *      amounts and the wallet balance below are deliberately the same $400/$300/$200/$1,000
 *      figures used to motivate the opcode in the README and the original project pitch.
 */
contract MultiStrategyExposureTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant WALLET_BALANCE = 1_000e18;
    uint256 internal constant STRATEGY_A_COMMITMENT = 400e18;
    uint256 internal constant STRATEGY_B_COMMITMENT = 300e18;
    uint256 internal constant STRATEGY_C_COMMITMENT = 200e18;
    uint256 internal constant SWAP_AMOUNT = 10e18;

    uint16 internal constant MAX_BPS = 5_000; // 50%: below this, no adjustment
    uint16 internal constant HALT_BPS = 9_000; // 90%: at/above this, hard revert

    Aqua public immutable aqua = new Aqua();
    ExposureAwareAquaRouter public swapVM;
    ExposureOracle public oracle;
    TokenMock public tokenIn;
    TokenMock public tokenOut;
    MockTaker public taker;
    address public maker;

    ISwapVM.Order public orderA;
    ISwapVM.Order public orderB;
    ISwapVM.Order public orderC;
    bytes32 public hashA;
    bytes32 public hashB;
    bytes32 public hashC;

    constructor() ExposureAquaOpcodes(address(aqua)) { }

    function setUp() public {
        tokenIn = new TokenMock("Token In", "TIN");
        tokenOut = new TokenMock("Token Out", "TOUT");

        swapVM = new ExposureAwareAquaRouter(address(aqua), address(0), address(this), "Aqueduct", "1.0.0");
        oracle = new ExposureOracle(address(this), address(this));

        maker = makeAddr("maker");
        taker = new MockTaker(aqua, swapVM, address(this));
        tokenIn.mint(address(taker), 1e33);
        tokenOut.mint(address(taker), 1e33);

        // The maker's one, real, actual wallet balance -- not per-strategy, just what they hold.
        tokenIn.mint(maker, WALLET_BALANCE);
        tokenOut.mint(maker, WALLET_BALANCE);
        vm.startPrank(maker);
        tokenIn.approve(address(aqua), type(uint256).max);
        tokenOut.approve(address(aqua), type(uint256).max);
        vm.stopPrank();

        orderA = _order(hex"0a");
        orderB = _order(hex"0b");
        orderC = _order(hex"0c");
        hashA = _ship(orderA, STRATEGY_A_COMMITMENT);
        hashB = _ship(orderB, STRATEGY_B_COMMITMENT);
        hashC = _ship(orderC, STRATEGY_C_COMMITMENT);
    }

    function _order(bytes1 salt) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(address(oracle), MAX_BPS, HALT_BPS, 0)),
            p.build(Controls._salt, abi.encodePacked(salt))
        );

        return _build(program);
    }

    /// @dev No exposure gate at all -- used only as an ungated price reference at the SAME pool
    /// depth as the strategy it's being compared against, so a comparison isolates the gate's
    /// effect from ordinary XYC price impact (which depends on pool depth, not exposure).
    function _ungatedOrder(bytes1 salt) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(p.build(XYCSwap._xycSwapXD), p.build(Controls._salt, abi.encodePacked(salt)));
        return _build(program);
    }

    function _build(bytes memory program) internal view returns (ISwapVM.Order memory) {
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

    function _swap(ISwapVM.Order memory order, uint256 amount) internal returns (uint256 amountIn, uint256 amountOut) {
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

        return taker.swap(order, address(tokenIn), address(tokenOut), amount, takerData);
    }

    function _haltError(uint64 exposureBps) internal view returns (bytes memory) {
        return abi.encodeWithSelector(ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, exposureBps, HALT_BPS);
    }

    /// @dev Mirrors keeper/pushExposure.ts's own aggregation math: sum of every active strategy's
    /// committed amount for this token, divided by the maker's real wallet balance of it.
    function _aggregateExposureBps(uint256 totalCommitted, uint256 walletBalance) internal pure returns (uint64) {
        return uint64((totalCommitted * 10_000) / walletBalance);
    }

    function test_MultiplierEffect_AggregateHaltsEvenTheSmallestLookingStrategy() public {
        uint64 aggregate =
            _aggregateExposureBps(STRATEGY_A_COMMITMENT + STRATEGY_B_COMMITMENT + STRATEGY_C_COMMITMENT, WALLET_BALANCE);
        assertEq(aggregate, 9_000, "sanity: (400+300+200)/1000 = 90%");
        oracle.pushExposure(maker, aggregate);

        // Strategy C alone only ever committed 200/1000 = 20% of the wallet -- in isolation, an
        // observer looking at just this strategy would call it safe. It is halted anyway, because
        // the gate reads the MAKER's aggregate exposure, not a per-strategy one.
        vm.expectRevert(_haltError(aggregate));
        _swap(orderC, SWAP_AMOUNT);

        // The larger strategies are halted by the exact same reading, for the same reason -- one
        // maker, one exposure number, every strategy they've shipped gated identically by it.
        vm.expectRevert(_haltError(aggregate));
        _swap(orderA, SWAP_AMOUNT);
        vm.expectRevert(_haltError(aggregate));
        _swap(orderB, SWAP_AMOUNT);
    }

    function test_MultiplierEffect_RemovingStrategiesDeratesThenSafes() public {
        // Start at the same 90% aggregate/halt as above, proven against strategy A this time.
        oracle.pushExposure(maker, _aggregateExposureBps(900e18, WALLET_BALANCE));
        vm.expectRevert(_haltError(9_000));
        _swap(orderA, SWAP_AMOUNT);

        // An ungated shadow strategy, started at the same fresh 400e18 depth as strategy A, to
        // isolate the gate's effect from ordinary XYC price impact (which depends on pool depth,
        // not exposure) at this first comparison point, where both pools are still equally fresh.
        ISwapVM.Order memory shadow = _ungatedOrder(hex"0d");
        _ship(shadow, STRATEGY_A_COMMITMENT);

        // Maker docks strategy C, the smallest one. The off-chain aggregate this maker's other
        // two strategies are judged against drops to (400+300)/1000 = 70% -- inside the derate
        // band now, not halted.
        _dock(hashC);
        uint64 seventyPct = _aggregateExposureBps(STRATEGY_A_COMMITMENT + STRATEGY_B_COMMITMENT, WALLET_BALANCE);
        assertEq(seventyPct, 7_000, "sanity: (400+300)/1000 = 70%");
        oracle.pushExposure(maker, seventyPct);
        (, uint256 deratedOut) = _swap(orderA, SWAP_AMOUNT);
        (, uint256 shadowOut1) = _swap(shadow, SWAP_AMOUNT); // both pools were equally fresh going in
        assertLt(deratedOut, shadowOut1, "70% aggregate must still derate strategy A's fill");
        assertGt(deratedOut, 0, "70% aggregate must still produce a fill, just a worse one");

        // Maker docks strategy B too. Only strategy A is left; aggregate drops to 400/1000 = 40%
        // -- back under the no-op threshold, fully safe again.
        //
        // Strategy A's pool is no longer fresh at this point (the derated swap above already drew
        // it down) -- and drew it down by LESS tokenOut than an ungated pool would have given up
        // for the same input, exactly because the gate reduced what actually left it. So `shadow`,
        // having given up the full undiscounted amount in the first swap, is no longer at the same
        // depth as A and can't be reused as a second comparison point. Instead, read A's own
        // ACTUAL remaining reserves straight from Aqua and ship a fresh, ungated strategy seeded
        // with exactly those reserves -- an apples-to-apples "what would THIS pool, as it stands
        // right now, give back if ungated" reference.
        _dock(hashB);
        uint64 fortyPct = _aggregateExposureBps(STRATEGY_A_COMMITMENT, WALLET_BALANCE);
        assertEq(fortyPct, 4_000, "sanity: 400/1000 = 40%");
        (uint256 remainingIn, uint256 remainingOut) =
            aqua.safeBalances(maker, address(swapVM), hashA, address(tokenIn), address(tokenOut));
        ISwapVM.Order memory matchedShadow = _ungatedOrder(hex"0e");
        tokenIn.mint(maker, remainingIn);
        tokenOut.mint(maker, remainingOut);
        vm.prank(maker);
        aqua.ship(
            address(swapVM), abi.encode(matchedShadow), dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([remainingIn, remainingOut])
        );

        oracle.pushExposure(maker, fortyPct);
        (, uint256 safeOut) = _swap(orderA, SWAP_AMOUNT);
        (, uint256 matchedShadowOut) = _swap(matchedShadow, SWAP_AMOUNT);
        assertEq(safeOut, matchedShadowOut, "40% aggregate must be a pure no-op, exactly matching A's own reserves ungated");
    }
}
