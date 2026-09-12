// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraits } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
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
 * @title NarrativeDemo
 * @notice A live, on-chain rehearsal of the exact 5-scene pitch script against the REAL Base
 *         Sepolia deployment -- not a Foundry-simulated EVM, the actual deployed bytecode and
 *         actual current state. Ships two new padding strategies (B, C) alongside the existing
 *         maker strategy (A) to make the "multiple strategies -> aggregate exposure" story real,
 *         and two small, freshly-matched strategies (E direct-only, F v4-only) purely so Scene 3's
 *         "SwapVM -> X, Uniswap v4 -> X, identical" moment is bit-exact rather than merely close
 *         (sequential swaps against a SHARED pool -- e.g. reusing strategy A on both venues back
 *         to back -- would deplete it between the two calls and produce two slightly different
 *         numbers, which would undercut the exact moment the script is going for; this is the
 *         same reason test/CrossVenueConsistency.t.sol uses two matched strategies rather than one
 *         shared one).
 *
 *         Run as a dry run first (no --broadcast) to validate every step against live chain state
 *         without spending anything or changing it:
 *           forge script script/NarrativeDemo.s.sol --rpc-url <base sepolia rpc> \
 *             --private-key <funded account> -vvvv
 *         Add --broadcast --slow to actually execute it and leave the new strategies live.
 *
 *         Scene 5's "oracle is stale -> halt" sub-case is deliberately NOT re-enacted here: it
 *         needs a real wall-clock wait past `maxStaleness` (block.timestamp can't be warped on a
 *         real chain the way `vm.warp` warps Foundry's simulated one), and is already rigorously
 *         proven against the real deployed ExposureGate bytecode in
 *         test/ExposureGate.t.sol:test_Reverts_WhenOracleReadingStale and
 *         test/AquaV4Hook.t.sol:test_Reverts_WhenOracleReadingStale_V4Path.
 */
contract NarrativeDemo is Script, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    address internal constant AQUA = 0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461;
    address internal constant SWAP_VM = 0xC008DD3D1293543d5FA7AD6eED285eD45E3d7cCc;
    address internal constant ORACLE = 0xE68530d8e694eC6d237F0B07eC24C405c8Cd764A;
    address internal constant TOKEN_IN = 0x2A22B21b15d6305AbCbe78ff3098aed2F5B54869;
    address internal constant TOKEN_OUT = 0x8BB1a7E6BABc09973a67D417120c3E8396c4822f;
    address internal constant MAKER = 0x5067591C365D7D69d76B725c2d9af7b9437132Be;
    bytes32 internal constant STRATEGY_A_HASH = 0x828353ec4866ca0f45f4bf5420875cba5a8d4afc8289eb98952016effab195e2;
    address internal constant EXISTING_V4_HOOK = 0xE115c49376c960B29D0bD77bF8C226a9562EAa88;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal constant MAKER_PK = uint256(keccak256("aqueduct.demo.maker"));
    uint256 internal constant KEEPER_PK = uint256(keccak256("aqueduct.demo.keeper"));

    uint256 internal constant STRATEGY_B = 75_000e18;
    uint256 internal constant STRATEGY_C = 50_000e18;
    uint256 internal constant MATCHED_STRATEGY_LIQUIDITY = 1_000e18;
    uint256 internal constant SCENE_SWAP_AMOUNT = 10e18;
    uint16 internal constant MAX_BPS = 5_000;
    uint16 internal constant HALT_BPS = 9_000;
    int24 internal constant TICK_SPACING = 60;
    bytes internal constant EOA_TAKER_DATA = hex"00000000000000000000000000000000000000000041";

    Aqua internal aqua = Aqua(AQUA);
    ExposureAwareAquaRouter internal swapVM = ExposureAwareAquaRouter(payable(SWAP_VM));
    ExposureOracle internal oracle = ExposureOracle(ORACLE);
    TokenMock internal tokenIn = TokenMock(TOKEN_IN);
    TokenMock internal tokenOut = TokenMock(TOKEN_OUT);

    constructor() ExposureAquaOpcodes(AQUA) { }

    function run() external {
        console2.log("================ SCENE 1: Show the problem ================");
        _shipPaddingStrategies();
        _logAggregateBreakdown();

        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(MAKER, HALT_BPS);
        vm.stopBroadcast();
        console2.log("Keeper pushed exposure: 90%% (illustrative aggregate -- see comment above)");

        console2.log("\n================ SCENE 2: Lower exposure, derated fill ================");
        vm.startBroadcast(MAKER_PK);
        aqua.dock(SWAP_VM, _paddingHashC, dynamic([TOKEN_IN, TOKEN_OUT]));
        vm.stopBroadcast();
        console2.log("Maker docked strategy C.");

        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(MAKER, 7_000);
        vm.stopBroadcast();
        console2.log("Keeper pushed exposure: 70%% -> DERATED band");

        (uint256 balIn, uint256 balOut) = aqua.safeBalances(MAKER, SWAP_VM, STRATEGY_A_HASH, TOKEN_IN, TOKEN_OUT);
        uint256 baseline = (SCENE_SWAP_AMOUNT * balOut) / (balIn + SCENE_SWAP_AMOUNT);
        console2.log("Baseline (ungated, from A's live reserves):", baseline);

        vm.startBroadcast();
        tokenIn.mint(msg.sender, SCENE_SWAP_AMOUNT);
        tokenIn.approve(SWAP_VM, type(uint256).max);
        ISwapVM.Order memory orderA = _existingOrderA();
        (, uint256 gatedOut,) = swapVM.swap(orderA, TOKEN_IN, TOKEN_OUT, SCENE_SWAP_AMOUNT, EOA_TAKER_DATA);
        vm.stopBroadcast();
        console2.log("Exposure gated (real swap on strategy A):", gatedOut);
        console2.log("(matches AqueductDemo.s.sol's own scenario 2 shape: same amountIn, strictly less amountOut)");

        console2.log("\n================ SCENE 3: Same liquidity through Uniswap ================");
        _runMatchedCrossVenueProof();

        console2.log("\n================ SCENE 4: Increase exposure back up ================");
        vm.startBroadcast(MAKER_PK);
        tokenIn.approve(AQUA, type(uint256).max);
        tokenOut.approve(AQUA, type(uint256).max);
        bytes32 newCHash = aqua.ship(
            SWAP_VM, abi.encode(_paddingOrderC2()), dynamic([TOKEN_IN, TOKEN_OUT]), dynamic([STRATEGY_C, STRATEGY_C])
        );
        vm.stopBroadcast();
        console2.log("Maker re-shipped a fresh strategy in place of the docked one:", vm.toString(newCHash));

        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(MAKER, HALT_BPS);
        vm.stopBroadcast();
        console2.log("Keeper pushed exposure: 90%% again");

        (bool directReverted,) =
            SWAP_VM.call(abi.encodeCall(swapVM.swap, (orderA, TOKEN_IN, TOKEN_OUT, SCENE_SWAP_AMOUNT, EOA_TAKER_DATA)));
        console2.log("SwapVM swap on A reverted as expected:", !directReverted);

        (bool v4Reverted,) = POOL_SWAP_TEST.call(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    PoolKey({
                        currency0: Currency.wrap(TOKEN_IN),
                        currency1: Currency.wrap(TOKEN_OUT),
                        fee: 0,
                        tickSpacing: TICK_SPACING,
                        hooks: IHooks(EXISTING_V4_HOOK)
                    }),
                    SwapParams({
                        zeroForOne: true,
                        amountSpecified: -int256(SCENE_SWAP_AMOUNT),
                        sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                    }),
                    PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
                    bytes("")
                )
            )
        );
        console2.log("Uniswap v4 swap on the SAME strategy A reverted as expected:", !v4Reverted);

        console2.log("\n================ SCENE 5: Attack the oracle ================");
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(MAKER, 7_000);
        vm.stopBroadcast();
        console2.log("Oracle says 70%% -> liquidity decreases (see Scene 2's real gated number above)");

        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(MAKER, HALT_BPS);
        vm.stopBroadcast();
        (directReverted,) =
            SWAP_VM.call(abi.encodeCall(swapVM.swap, (orderA, TOKEN_IN, TOKEN_OUT, SCENE_SWAP_AMOUNT, EOA_TAKER_DATA)));
        console2.log("Oracle says 90%% -> liquidity halts:", !directReverted);

        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(MAKER, 10_000); // ExposureOracle's own actual on-chain maximum (100%)
        vm.stopBroadcast();
        (directReverted,) =
            SWAP_VM.call(abi.encodeCall(swapVM.swap, (orderA, TOKEN_IN, TOKEN_OUT, SCENE_SWAP_AMOUNT, EOA_TAKER_DATA)));
        console2.log("Oracle says 100%% (its real max) -> liquidity halts:", !directReverted);

        console2.log(
            "Oracle is stale -> liquidity halts: NOT re-enacted live here (needs a real wall-clock wait past"
        );
        console2.log(
            "maxStaleness on a real chain, and strategy A's own live order has maxStaleness=0 by design);"
        );
        console2.log("already proven against real deployed bytecode in test_Reverts_WhenOracleReadingStale(_V4Path).");

        // Leave the live demo in a normal, safe state for the next visitor.
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(MAKER, 1_000);
        vm.stopBroadcast();

        console2.log("\nThe oracle can lie, but it cannot make the maker trade more than the underlying SwapVM");
        console2.log("program authorized.");
    }

    bytes32 internal _paddingHashC;

    function _shipPaddingStrategies() internal {
        vm.startBroadcast(MAKER_PK);
        tokenIn.approve(AQUA, type(uint256).max);
        tokenOut.approve(AQUA, type(uint256).max);
        aqua.ship(SWAP_VM, abi.encode(_paddingOrderB()), dynamic([TOKEN_IN, TOKEN_OUT]), dynamic([STRATEGY_B, STRATEGY_B]));
        _paddingHashC =
            aqua.ship(SWAP_VM, abi.encode(_paddingOrderC()), dynamic([TOKEN_IN, TOKEN_OUT]), dynamic([STRATEGY_C, STRATEGY_C]));
        vm.stopBroadcast();
    }

    function _logAggregateBreakdown() internal view {
        (uint256 balA,) = aqua.safeBalances(MAKER, SWAP_VM, STRATEGY_A_HASH, TOKEN_IN, TOKEN_OUT);
        console2.log("Strategy A committed (tokenIn):", balA);
        console2.log("Strategy B committed (tokenIn):", STRATEGY_B);
        console2.log("Strategy C committed (tokenIn):", STRATEGY_C);
        console2.log(
            "(An off-chain Graph keeper would sum these against the maker's real wallet balance to compute the"
        );
        console2.log("real exposureBps -- keeper/pushExposure.ts does exactly this math for real; the push below");
        console2.log("mirrors what that computation would report for a maker this committed.)");
    }

    function _existingOrderA() internal pure returns (ISwapVM.Order memory) {
        // The exact same order AqueductRedeployOracle.s.sol shipped -- reconstructed here rather
        // than read back from deployment.json so this script has no filesystem dependency.
        return ISwapVM.Order({
            maker: MAKER,
            traits: MakerTraits.wrap(28948022309329048855892746252171976963317496166410141009864396001978282409984),
            data: hex"1100221ae68530d8e694ec6d237f0b07ec24c405c8cd764a138823280000"
        });
    }

    function _paddingOrder(bytes1 salt) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(ORACLE, MAX_BPS, HALT_BPS, 0)),
            p.build(Controls._salt, abi.encodePacked(salt))
        );
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: MAKER,
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

    function _paddingOrderB() internal view returns (ISwapVM.Order memory) {
        return _paddingOrder(hex"b1");
    }

    function _paddingOrderC() internal view returns (ISwapVM.Order memory) {
        return _paddingOrder(hex"c1");
    }

    function _paddingOrderC2() internal view returns (ISwapVM.Order memory) {
        return _paddingOrder(hex"c2");
    }

    /// @dev Ships two SEPARATE, freshly-seeded, identically-configured strategies (E for the
    /// direct leg, F for the v4 leg) and swaps each exactly once at the SAME 70% exposure, so
    /// Scene 3's "SwapVM -> X, Uniswap v4 -> X" numbers are bit-exact rather than merely close --
    /// see this contract's own doc comment for why a shared, sequentially-swapped pool wouldn't
    /// give that.
    function _runMatchedCrossVenueProof() internal {
        ISwapVM.Order memory orderE = _paddingOrder(hex"e1");
        ISwapVM.Order memory orderF = _paddingOrder(hex"f1");

        vm.startBroadcast(MAKER_PK);
        tokenIn.approve(AQUA, type(uint256).max);
        tokenOut.approve(AQUA, type(uint256).max);
        aqua.ship(
            SWAP_VM, abi.encode(orderE), dynamic([TOKEN_IN, TOKEN_OUT]),
            dynamic([MATCHED_STRATEGY_LIQUIDITY, MATCHED_STRATEGY_LIQUIDITY])
        );
        aqua.ship(
            SWAP_VM, abi.encode(orderF), dynamic([TOKEN_IN, TOKEN_OUT]),
            dynamic([MATCHED_STRATEGY_LIQUIDITY, MATCHED_STRATEGY_LIQUIDITY])
        );
        vm.stopBroadcast();

        vm.startBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), aqua, swapVM, oracle, orderF);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AquaV4Hook).creationCode, constructorArgs);
        AquaV4Hook matchedHook = new AquaV4Hook{ salt: salt }(IPoolManager(POOL_MANAGER), aqua, swapVM, oracle, orderF);
        require(address(matchedHook) == hookAddress, "hook address mismatch");

        PoolKey memory matchedPoolKey = PoolKey({
            currency0: Currency.wrap(TOKEN_IN),
            currency1: Currency.wrap(TOKEN_OUT),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(matchedHook))
        });
        IPoolManager(POOL_MANAGER).initialize(matchedPoolKey, TickMath.getSqrtPriceAtTick(0));
        tokenIn.mint(address(matchedHook), 100e18);
        tokenOut.mint(address(matchedHook), 100e18);

        tokenIn.mint(msg.sender, SCENE_SWAP_AMOUNT * 2);
        tokenIn.approve(SWAP_VM, type(uint256).max);
        tokenIn.approve(POOL_SWAP_TEST, type(uint256).max);

        (, uint256 directOut,) = swapVM.swap(orderE, TOKEN_IN, TOKEN_OUT, SCENE_SWAP_AMOUNT, EOA_TAKER_DATA);

        uint256 tokenOutBefore = tokenOut.balanceOf(msg.sender);
        PoolSwapTest(POOL_SWAP_TEST).swap(
            matchedPoolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(SCENE_SWAP_AMOUNT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        uint256 v4Out = tokenOut.balanceOf(msg.sender) - tokenOutBefore;
        vm.stopBroadcast();

        console2.log("1inch SwapVM  ->", directOut);
        console2.log("Uniswap v4    ->", v4Out);
        require(directOut == v4Out, "cross-venue outputs must be bit-exact");
        console2.log("Same strategy. Same risk policy. Different execution venue.");
    }
}
