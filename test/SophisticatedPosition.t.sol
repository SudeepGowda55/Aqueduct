// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MockTaker } from "@1inch/swap-vm/test/mocks/MockTaker.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { OraclePriceAdjuster, OraclePriceAdjusterArgsBuilder } from "@1inch/swap-vm/src/instructions/OraclePriceAdjuster.sol";
import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import { dynamic } from "@1inch/swap-vm/test/utils/Dynamic.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";
import { MockPriceOracle } from "./utils/MockPriceOracle.sol";

/**
 * @title SophisticatedPositionTest
 * @notice Proves the "sophisticated DeFi position" the 1inch track explicitly asks for: a single
 *         maker program composing THREE SwapVM instructions, not one --
 *         `_xycSwapXD` -> `_oraclePriceAdjuster1D` -> `_exposureGate1D` -- where the two new
 *         instructions bound the fill from OPPOSITE directions:
 *           - `_oraclePriceAdjuster1D` (1inch's own, shipped in swap-vm but never wired into
 *             stock AquaOpcodes until this project) can only ever IMPROVE the taker's price
 *             toward a real Chainlink feed, capped at `maxPriceDecay` -- no matter how favorable
 *             the reported price, the improvement never exceeds that cap.
 *           - `_exposureGate1D` (this project's own) can only ever WORSEN the taker's price
 *             toward the maker's real risk, capped at total halt -- no matter how safe the
 *             reported exposure, it never improves a fill beyond what the pricing instructions
 *             before it already produced.
 *         Composed together, a taker's fill is bounded on BOTH sides by two independent oracles
 *         that can each only push the price one specific direction -- and neither one can ever
 *         override the other's direction, proven directly below, not argued.
 */
contract SophisticatedPositionTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant INITIAL_BALANCE = 1_000e18;
    uint256 internal constant SWAP_AMOUNT = 10e18;
    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;
    uint64 internal constant MAX_PRICE_DECAY = 0.97e18; // caps improvement at +3% (2e18 - 0.97e18)
    uint256 internal constant ONE = 1e18;

    Aqua public immutable aqua = new Aqua();
    ExposureAwareAquaRouter public swapVM;
    ExposureOracle public exposureOracle;
    MockPriceOracle public priceOracle;
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
        exposureOracle = new ExposureOracle(address(this), address(this));
        priceOracle = new MockPriceOracle(int256(ONE)); // starts at a neutral 1.00 price
        maker = makeAddr("maker");
        taker = new MockTaker(aqua, swapVM, address(this));
        tokenIn.mint(address(taker), 1e30);
        tokenOut.mint(address(taker), 1e30);

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                OraclePriceAdjuster._oraclePriceAdjuster1D,
                OraclePriceAdjusterArgsBuilder.build(MAX_PRICE_DECAY, 0, 8, address(priceOracle))
            ),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(address(exposureOracle), MAX_BPS, HALT_BPS, 0))
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
        bytes32 strategyHash = aqua.ship(
            address(swapVM), abi.encode(order), dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([INITIAL_BALANCE, INITIAL_BALANCE])
        );
        vm.stopPrank();
        assertEq(strategyHash, swapVM.hash(order), "strategy hash mismatch");
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

    function _xycOut() internal view returns (uint256) {
        return (SWAP_AMOUNT * INITIAL_BALANCE) / (INITIAL_BALANCE + SWAP_AMOUNT);
    }

    /// @dev Mirrors `_oraclePriceAdjuster1D`'s exact-in branch precisely (see OraclePriceAdjuster.sol).
    function _predictPriceAdjusted(uint256 xycOut, uint256 oraclePriceRaw) internal pure returns (uint256) {
        uint256 oraclePrice = oraclePriceRaw * 1e10; // 8 decimals -> 1e18 scale, same as the contract
        uint256 currentPrice = (xycOut * ONE) / SWAP_AMOUNT;
        if (oraclePrice <= currentPrice) return xycOut;
        uint256 priceRatio = (oraclePrice * ONE) / currentPrice;
        uint256 maxIncrease = 2e18 - MAX_PRICE_DECAY;
        uint256 adjustment = Math.min(priceRatio, maxIncrease);
        return (xycOut * adjustment) / ONE;
    }

    /// @dev Mirrors `_exposureGate1D`'s exact-in derate formula precisely (see ExposureGate.sol).
    function _predictGated(uint256 amountOut, uint64 exposureBps) internal pure returns (uint256) {
        if (exposureBps <= MAX_BPS) return amountOut;
        uint256 overage = exposureBps - MAX_BPS;
        uint256 band = HALT_BPS - MAX_BPS;
        uint256 derateFactor = ONE - (overage * ONE) / band;
        return (amountOut * derateFactor) / ONE;
    }

    // ===== The price side: only ever improves, always capped =====

    function test_PriceAdjuster_ImprovesTowardOracle_WhenFavorable() public {
        uint256 xycOut = _xycOut();
        priceOracle.setPrice(1_05000000); // 1.05 in 8 decimals -- meaningfully above the pool's own price
        exposureOracle.pushExposure(maker, 0); // gate is a no-op, isolating the price adjuster's effect

        uint256 expected = _predictPriceAdjusted(xycOut, 1_05000000);
        (, uint256 actual) = _swap();

        assertEq(actual, expected, "price-adjusted output must match the instruction's own formula exactly");
        assertGt(actual, xycOut, "a favorable oracle price must genuinely improve the fill");
    }

    function test_PriceAdjuster_NeverWorsensPrice_WhenUnfavorable() public {
        uint256 xycOut = _xycOut();
        priceOracle.setPrice(0.5e8); // 0.50 -- worse than the pool's own implied price
        exposureOracle.pushExposure(maker, 0);

        (, uint256 actual) = _swap();

        assertEq(actual, xycOut, "an unfavorable oracle price must be a pure no-op, never worsen the fill");
    }

    /// @notice The malicious-oracle story for the PRICE side specifically: however absurd the
    /// reported price, the improvement is bounded by `maxPriceDecay`'s cap, never unbounded.
    function test_MaliciousPriceOracle_ImprovementIsAlwaysCapped() public {
        uint256 xycOut = _xycOut();
        priceOracle.setPrice(1_000_000 * 1e8); // an absurd, obviously-wrong "1,000,000" price
        exposureOracle.pushExposure(maker, 0);

        (, uint256 actual) = _swap();

        uint256 maxIncrease = 2e18 - MAX_PRICE_DECAY;
        uint256 cappedExpected = (xycOut * maxIncrease) / ONE;
        assertEq(actual, cappedExpected, "even an absurd price must hit exactly the configured cap, no further");
        assertLt(actual, xycOut * 2, "sanity: nowhere close to the 1,000,000x the fake price implied");
    }

    // ===== The composed position: both bounds apply together, in the order the program runs =====

    function test_ComposedPosition_DerateAppliesOnTopOfPriceImprovement() public {
        uint256 xycOut = _xycOut();
        priceOracle.setPrice(1_05000000); // favorable: same improvement as the first test
        uint256 priceAdjusted = _predictPriceAdjusted(xycOut, 1_05000000);
        assertGt(priceAdjusted, xycOut, "sanity: price improvement must have actually applied first");

        exposureOracle.pushExposure(maker, 7_000); // now derate on top of that improved amount

        uint256 expected = _predictGated(priceAdjusted, 7_000);
        (, uint256 actual) = _swap();

        assertEq(actual, expected, "final output must be the derate applied to the PRICE-ADJUSTED amount");
        assertLt(actual, priceAdjusted, "the derate must still make the final fill worse than the price-improved one");
    }

    /// @notice The ultimate combined guarantee: no matter how favorable the price oracle gets,
    /// the exposure gate's halt is absolute and cannot be priced around.
    function test_EvenAFavorablePriceOracle_CannotBypassHalt() public {
        priceOracle.setPrice(1_000_000 * 1e8); // the most favorable possible price
        exposureOracle.pushExposure(maker, HALT_BPS); // maker is halted

        vm.expectRevert(
            abi.encodeWithSelector(ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, HALT_BPS, HALT_BPS)
        );
        _swap();
    }
}
