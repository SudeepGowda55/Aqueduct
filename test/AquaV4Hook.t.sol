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
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";
import { AquaV4Hook } from "../src/hooks/AquaV4Hook.sol";

/// @title AquaV4HookTest
/// @notice Proves AquaV4Hook actually sources a real Uniswap v4 swap from a real Aqua-backed
///         SwapVM maker strategy end-to-end, and that the exposure gate composed into that
///         strategy's program can halt the v4 swap itself -- not just a direct SwapVM call.
contract AquaV4HookTest is Test, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant INITIAL_BALANCE = 1_000e18;
    uint256 internal constant SWAP_AMOUNT = 10e18;
    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;
    int24 internal constant TICK_SPACING = 60;

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
        poolManager =
            IPoolManager(vm.deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapVM = new ExposureAwareAquaRouter(address(aqua), address(0), address(this), "Aqueduct", "1.0.0");
        oracle = new ExposureOracle(address(this), address(this));
        maker = makeAddr("maker");

        TokenMock a = new TokenMock("Token A", "TKA");
        TokenMock b = new TokenMock("Token B", "TKB");
        (token0, token1) =
            address(a) < address(b) ? (a, b) : (b, a);

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                ExposureGate._exposureGate1D,
                ExposureGateArgsBuilder.build(address(oracle), MAX_BPS, HALT_BPS, 0)
            )
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
        bytes memory constructorArgs = abi.encode(poolManager, aqua, swapVM, order);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(AquaV4Hook).creationCode, constructorArgs);

        hook = new AquaV4Hook{ salt: salt }(poolManager, aqua, swapVM, order);
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

        // Ship the maker's Aqua strategy backing this pool.
        bytes32 orderHash = swapVM.hash(order);
        token0.mint(maker, INITIAL_BALANCE);
        token1.mint(maker, INITIAL_BALANCE);
        vm.startPrank(maker);
        token0.approve(address(aqua), type(uint256).max);
        token1.approve(address(aqua), type(uint256).max);
        bytes32 strategyHash = aqua.ship(
            address(swapVM), abi.encode(order), dynamic([address(token0), address(token1)]), dynamic([INITIAL_BALANCE, INITIAL_BALANCE])
        );
        vm.stopPrank();
        assertEq(strategyHash, orderHash, "strategy hash mismatch");

        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // Seed the hook's working-capital float (see AquaV4Hook's contract-level comment): a
        // plain ERC20 transfer, no special deposit function needed.
        token0.mint(address(hook), 1_000e18);
        token1.mint(address(hook), 1_000e18);
    }

    /// @dev Every hook-callback revert is wrapped by Hooks.sol's CustomRevert before it bubbles
    /// up to the caller (see AquaV4Hook's contract-level comment on WrappedError), so tests must
    /// match the wrapped form -- this mirrors the exact pattern uniswap-hooks' own tests use.
    function _wrappedRevert(bytes4 hookSelector, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(hook), hookSelector, reason, hex"a9e35b2f");
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

    function test_SwapIsSourcedFromAquaLiquidity_ZeroForOne() public {
        uint256 token1BalanceBefore = token1.balanceOf(address(this));

        BalanceDelta delta = _swap(true, SWAP_AMOUNT);

        assertEq(delta.amount0(), -int256(SWAP_AMOUNT), "taker should pay exactly the specified input");
        assertGt(delta.amount1(), 0, "taker should receive output sourced from Aqua");
        assertEq(
            token1.balanceOf(address(this)), token1BalanceBefore + uint256(int256(delta.amount1())),
            "taker's real token1 balance should reflect the Aqua-sourced fill"
        );

        // The maker's Aqua balance should reflect the same swap that ran through SwapVM.
        (uint256 makerBalance0, uint256 makerBalance1) =
            aqua.safeBalances(maker, address(swapVM), swapVM.hash(order), address(token0), address(token1));
        assertEq(makerBalance0, INITIAL_BALANCE + SWAP_AMOUNT, "maker's token0 balance should have grown by the input");
        assertEq(
            makerBalance1, INITIAL_BALANCE - uint256(int256(delta.amount1())),
            "maker's token1 balance should have shrunk by exactly what the taker received"
        );
    }

    function test_SwapIsSourcedFromAquaLiquidity_OneForZero() public {
        BalanceDelta delta = _swap(false, SWAP_AMOUNT);

        assertEq(delta.amount1(), -int256(SWAP_AMOUNT), "taker should pay exactly the specified input");
        assertGt(delta.amount0(), 0, "taker should receive output sourced from Aqua");
    }

    function test_Reverts_WhenMakerExposureAtHalt() public {
        oracle.pushExposure(maker, HALT_BPS);

        vm.expectRevert(
            _wrappedRevert(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(ExposureGate.ExposureGateExceedsHaltThreshold.selector, maker, HALT_BPS, HALT_BPS)
            )
        );
        _swap(true, SWAP_AMOUNT);
    }

    function test_ExactOutputReverts() public {
        vm.expectRevert(
            _wrappedRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(AquaV4Hook.ExactOutputNotSupported.selector))
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
            _wrappedRevert(IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(AquaV4Hook.LiquidityNotAllowed.selector))
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
}
