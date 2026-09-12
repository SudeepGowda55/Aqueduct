// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
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
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";
import { AquaV4Hook } from "../src/hooks/AquaV4Hook.sol";

/**
 * @title CrossVenueConsistencyTest
 * @notice The central Uniswap-track claim, proven directly rather than argued: the SAME maker,
 *         reading the SAME exposure oracle, gets the SAME fill outcome whether the swap runs
 *         directly through SwapVM or through a Uniswap v4 pool backed by AquaV4Hook. Not "both
 *         venues work" -- both venues produce IDENTICAL numbers for identical inputs, because
 *         they both bottom out in the exact same `_exposureGate1D` opcode execution.
 *
 * @dev Two separate Aqua strategies back the two venues (`orderDirect` for a plain `swapVM.swap`
 *      call, `orderV4` for the pool AquaV4Hook is bound to) rather than one shared strategy,
 *      specifically so a swap on one venue can never shift the pool balances the other venue's
 *      comparison depends on -- each strategy is shipped with identical initial balances and
 *      swapped exactly once per test, so any difference in output could only come from the gate
 *      treating the two venues differently. `orderDirect` and `orderV4` differ only by a trailing
 *      `Controls._salt` byte (a documented no-op in swap-vm's own instruction set, used the same
 *      way in 1inch's own tests purely to force two otherwise-identical programs to hash
 *      differently) -- everything that affects pricing or gating is byte-for-byte identical.
 */
contract CrossVenueConsistencyTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant INITIAL_BALANCE = 1_000e18;
    uint256 internal constant SWAP_AMOUNT = 10e18;
    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;
    int24 internal constant TICK_SPACING = 60;
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

    ISwapVM.Order public orderDirect;
    ISwapVM.Order public orderV4;
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

        orderDirect = _buildOrder(hex"00");
        orderV4 = _buildOrder(hex"01");
        assertTrue(swapVM.hash(orderDirect) != swapVM.hash(orderV4), "sanity: the two strategies must be distinct");
        // The equality this test proves below must come from the gate treating both venues
        // identically, not from an accident of test setup (e.g. two strategies that just happen
        // to be configured the same way). This asserts it directly rather than leaving it as a
        // prose claim in the contract-level comment: the two orders' program bytes are IDENTICAL
        // except for the single trailing salt byte Aqua's immutability check forces us to vary.
        _assertProgramsIdenticalExceptTrailingSalt(orderDirect.data, orderV4.data);

        _shipStrategy(orderDirect);
        _shipStrategy(orderV4);

        // ---- Wire up the v4 pool, bound to orderV4's strategy only. ----
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(poolManager, aqua, swapVM, oracle, orderV4);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AquaV4Hook).creationCode, constructorArgs);
        hook = new AquaV4Hook{ salt: salt }(poolManager, aqua, swapVM, oracle, orderV4);
        assertEq(address(hook), hookAddress, "hook address mismatch");
        // The equality isn't just "two implementations that happen to agree" -- the hook's
        // beforeSwap literally calls into THIS SAME `ExposureAwareAquaRouter` instance the direct
        // path also calls (see AquaV4Hook.sol's `swapVM.swap(...)` call), so both venues execute
        // the identical deployed `_exposureGate1D` bytecode, not two copies of it.
        assertEq(address(hook.swapVM()), address(swapVM), "hook must call into the identical SwapVM router as the direct path");

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

        // ---- Fund this test contract as a plain EOA-style taker for the direct SwapVM leg. ----
        tokenIn.mint(address(this), 1_000_000e18);
        tokenOut.mint(address(this), 1_000_000e18);
        tokenIn.approve(address(swapVM), type(uint256).max);
        tokenIn.approve(address(swapRouter), type(uint256).max);
    }

    function _buildOrder(bytes memory distinguishingSalt) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                ExposureGate._exposureGate1D,
                ExposureGateArgsBuilder.build(address(oracle), MAX_BPS, HALT_BPS, 0)
            ),
            p.build(Controls._salt, distinguishingSalt)
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

    /// @dev Independently verifies the "identical apart from the salt" claim byte-for-byte,
    /// rather than trusting that `_buildOrder`'s two calls happened to produce comparable output.
    function _assertProgramsIdenticalExceptTrailingSalt(bytes memory dataA, bytes memory dataB) internal pure {
        assertEq(dataA.length, dataB.length, "orders must be the same length to differ only in the trailing salt byte");
        for (uint256 i = 0; i < dataA.length - 1; i++) {
            assertEq(dataA[i], dataB[i], "orders must be byte-for-byte identical except the trailing salt byte");
        }
        assertTrue(
            dataA[dataA.length - 1] != dataB[dataB.length - 1],
            "sanity: the trailing salt byte must actually differ, or the two strategyHashes couldn't be distinct"
        );
    }

    function _shipStrategy(ISwapVM.Order memory order) internal {
        bytes32 orderHash = swapVM.hash(order);
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
        assertEq(strategyHash, orderHash, "strategy hash mismatch");
    }

    /// @dev Swaps SWAP_AMOUNT directly through SwapVM as a plain EOA taker (no contract needed --
    /// see AquaV4Hook's/the frontend's own use of this exact flag combination).
    function _swapDirect() internal returns (uint256 amountOut) {
        (, amountOut,) = swapVM.swap(orderDirect, address(tokenIn), address(tokenOut), SWAP_AMOUNT, EOA_TAKER_DATA);
    }

    /// @dev Swaps SWAP_AMOUNT through the v4 pool, sourced entirely from orderV4's Aqua strategy.
    function _swapV4() internal returns (uint256 amountOut) {
        uint256 before = tokenOut.balanceOf(address(this));
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(SWAP_AMOUNT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        amountOut = tokenOut.balanceOf(address(this)) - before;
    }

    function _wrappedHaltRevert(bytes4 hookSelector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookSelector,
            abi.encodeWithSelector(
                ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, uint64(HALT_BPS), HALT_BPS
            ),
            hex"a9e35b2f"
        );
    }

    /// @dev The heart of the claim: run both venues at the same exposure and assert their outputs
    /// are not merely close, but bit-for-bit identical -- both strategies started from identical
    /// balances and are swapped exactly once, so the *only* thing that can affect the outcome is
    /// the gate itself, and it must have treated both venues the same way.
    function test_ConsistentAcrossVenues_Safe_10pct() public {
        oracle.pushExposure(maker, 1_000);

        uint256 outDirect = _swapDirect();
        uint256 outV4 = _swapV4();

        assertGt(outDirect, 0, "sanity: direct swap should fill");
        assertEq(outDirect, outV4, "both venues must produce the identical fill at the same exposure");
    }

    function test_ConsistentAcrossVenues_Derated_70pct() public {
        oracle.pushExposure(maker, 7_000);

        uint256 outDirect = _swapDirect();
        uint256 outV4 = _swapV4();

        assertGt(outDirect, 0, "sanity: derated swap should still fill");
        assertEq(outDirect, outV4, "both venues must apply the identical derate at the same exposure");
    }

    function test_ConsistentAcrossVenues_Halted_90pct() public {
        oracle.pushExposure(maker, HALT_BPS);

        vm.expectRevert(
            abi.encodeWithSelector(ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, uint64(HALT_BPS), HALT_BPS)
        );
        this.callSwapDirect();

        vm.expectRevert(_wrappedHaltRevert(IHooks.beforeSwap.selector));
        this.callSwapV4();
    }

    // external wrappers so vm.expectRevert (which only catches the NEXT call) can target each
    // swap precisely, since _swapDirect/_swapV4 are internal.
    function callSwapDirect() external returns (uint256) {
        return _swapDirect();
    }

    function callSwapV4() external returns (uint256) {
        return _swapV4();
    }
}
