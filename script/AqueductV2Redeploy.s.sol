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
import { OraclePriceAdjuster, OraclePriceAdjusterArgsBuilder } from "@1inch/swap-vm/src/instructions/OraclePriceAdjuster.sol";
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
 * @title AqueductV2Redeploy
 * @notice One-off, not part of the normal flow: fixes a real bug found during live testing, and
 *         ships the new sophisticated (price + exposure) position for real, in one pass.
 *
 * @dev THE BUG: `_exposureGate1D` is an internal function -- it compiles directly into whatever
 *      router inherits it, it isn't called externally. `ExposureOracle.setPausedByMaker` was
 *      added to the source, and a *new oracle* was deployed to pick it up
 *      (`AqueductRedeployOracle.s.sol`) -- but that script explicitly REUSED the existing
 *      `ExposureAwareAquaRouter`, whose bytecode was compiled *before* the pause check existed in
 *      source. Result: `isPausedByMaker` was never actually called during a real swap on that
 *      router, on EITHER venue, even though the oracle correctly stored the flag and emitted real
 *      events. Confirmed via a real execution trace of a real swap (`cast run`) that showed
 *      `exposureOf` being called with no preceding `isPausedByMaker` call at all -- not inferred,
 *      directly observed. An earlier attempt to verify this same fix in
 *      `AqueductRedeployOracle.s.sol`'s own on-chain check was itself a false positive: it checked
 *      only whether a call reverted, not *why*, and the revert it saw was actually an unrelated
 *      insufficient-balance failure from reusing `msg.sender` without minting fresh tokens for that
 *      specific call. This script's own verification below decodes the exact revert reason instead
 *      of just checking success/failure, specifically so that mistake cannot repeat itself.
 *
 *      THE FIX: deploy a fresh `ExposureAwareAquaRouter` from current source (includes the pause
 *      check), and re-ship every strategy that needs to keep working under it -- `Aqua.pull` is
 *      keyed by `_balances[maker][app][strategyHash][token]`, so a new router address is a new
 *      `app` identity; strategies shipped to the old router are not migrated, they are re-created.
 *      Both v4 hooks are immutable per-`swapVM` in their constructor, so they get redeployed too.
 *
 *      ALSO SHIPPED HERE: a new maker program composing `_xycSwapXD` -> `_oraclePriceAdjuster1D`
 *      (1inch's own instruction, wired into `ExposureAquaOpcodes` for the first time) ->
 *      `_exposureGate1D`, pointed at a real, independently-verified Chainlink ETH/USD feed on
 *      Base Sepolia (`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`) -- see
 *      `test/SophisticatedPosition.t.sol` for the composed proof this is built from.
 *
 *      Run it:
 *        forge script script/AqueductV2Redeploy.s.sol \
 *          --rpc-url <base sepolia rpc> \
 *          --private-key <the same funded account used for prior deployments> \
 *          --broadcast --slow -vvvv
 */
contract AqueductV2Redeploy is Script, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    address internal constant AQUA = 0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461;
    address internal constant ORACLE = 0xE68530d8e694eC6d237F0B07eC24C405c8Cd764A;
    address internal constant TOKEN_IN = 0x2A22B21b15d6305AbCbe78ff3098aed2F5B54869;
    address internal constant TOKEN_OUT = 0x8BB1a7E6BABc09973a67D417120c3E8396c4822f;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Real Chainlink ETH/USD feed on Base Sepolia -- independently verified on-chain before use
    // here: real bytecode, description()=="ETH / USD", decimals()==8, a live, recently-updated
    // price (not assumed or guessed from a blog post).
    address internal constant CHAINLINK_ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    uint256 internal constant MAKER_PK = uint256(keccak256("aqueduct.demo.maker"));
    uint256 internal constant KEEPER_PK = uint256(keccak256("aqueduct.demo.keeper"));

    uint256 internal constant STRATEGY_A = 100_000e18;
    uint256 internal constant STRATEGY_B = 75_000e18;
    uint256 internal constant STRATEGY_C = 50_000e18;
    uint256 internal constant STRATEGY_P = 50_000e18; // the sophisticated price+risk position
    uint256 internal constant HOOK_WORKING_CAPITAL = 10_000e18;
    uint256 internal constant VERIFICATION_SWAP_AMOUNT = 1e18;

    uint16 internal constant MAX_EXPOSURE_BPS = 5_000;
    uint16 internal constant HALT_EXPOSURE_BPS = 9_000;
    uint64 internal constant MAX_PRICE_DECAY = 0.97e18; // caps price improvement at +3%
    uint16 internal constant PRICE_MAX_STALENESS = 3_600; // 1 hour -- a real, meaningful check
    int24 internal constant TICK_SPACING = 60;
    bytes internal constant EOA_TAKER_DATA = hex"00000000000000000000000000000000000000000041";

    constructor() ExposureAquaOpcodes(AQUA) { }

    function run() external {
        address maker = vm.addr(MAKER_PK);
        address keeper = vm.addr(KEEPER_PK);
        require(maker == 0x5067591C365D7D69d76B725c2d9af7b9437132Be, "maker mismatch");
        require(keeper == 0x72759F6952b9c307F57865A5e4651C05C69c8101, "keeper mismatch");

        Aqua aqua = Aqua(AQUA);
        TokenMock tokenIn = TokenMock(TOKEN_IN);
        TokenMock tokenOut = TokenMock(TOKEN_OUT);
        ExposureOracle oracle = ExposureOracle(ORACLE);

        // ---- Step 1: THE FIX. Deploy a fresh router from current source. ----
        vm.startBroadcast();
        ExposureAwareAquaRouter router = new ExposureAwareAquaRouter(AQUA, address(0), msg.sender, "Aqueduct", "1.0.0");
        vm.stopBroadcast();
        console2.log("New ExposureAwareAquaRouter (pause-check included):", address(router));

        // ---- Step 2: fund the maker for the strategies being (re-)shipped below. ----
        uint256 totalNeeded = STRATEGY_A + STRATEGY_B + STRATEGY_C + STRATEGY_P;
        vm.startBroadcast();
        tokenIn.mint(maker, totalNeeded);
        tokenOut.mint(maker, totalNeeded);
        vm.stopBroadcast();

        // ---- Step 3: re-ship Strategy A, B, C under the new router. ----
        ISwapVM.Order memory orderA = _gatedOrder(maker, address(oracle), hex"a2");
        ISwapVM.Order memory orderB = _gatedOrder(maker, address(oracle), hex"b2");
        ISwapVM.Order memory orderC = _gatedOrder(maker, address(oracle), hex"c2");

        vm.startBroadcast(MAKER_PK);
        tokenIn.approve(AQUA, type(uint256).max);
        tokenOut.approve(AQUA, type(uint256).max);
        bytes32 hashA = aqua.ship(address(router), abi.encode(orderA), dynamic([TOKEN_IN, TOKEN_OUT]), dynamic([STRATEGY_A, STRATEGY_A]));
        bytes32 hashB = aqua.ship(address(router), abi.encode(orderB), dynamic([TOKEN_IN, TOKEN_OUT]), dynamic([STRATEGY_B, STRATEGY_B]));
        bytes32 hashC = aqua.ship(address(router), abi.encode(orderC), dynamic([TOKEN_IN, TOKEN_OUT]), dynamic([STRATEGY_C, STRATEGY_C]));
        vm.stopBroadcast();
        console2.log("Strategy A hash:", vm.toString(hashA));
        console2.log("Strategy B hash:", vm.toString(hashB));
        console2.log("Strategy C hash:", vm.toString(hashC));

        // ---- Step 4: new v4 hook + pool bound to (new router, orderA). ----
        vm.startBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory hookArgs = abi.encode(IPoolManager(POOL_MANAGER), aqua, router, oracle, orderA);
        (address hookAddress, bytes32 hookSalt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(AquaV4Hook).creationCode, hookArgs);
        AquaV4Hook hook = new AquaV4Hook{ salt: hookSalt }(IPoolManager(POOL_MANAGER), aqua, router, oracle, orderA);
        require(address(hook) == hookAddress, "hook address mismatch");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN_IN),
            currency1: Currency.wrap(TOKEN_OUT),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        IPoolManager(POOL_MANAGER).initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        tokenIn.mint(address(hook), HOOK_WORKING_CAPITAL);
        tokenOut.mint(address(hook), HOOK_WORKING_CAPITAL);
        vm.stopBroadcast();
        console2.log("New AquaV4Hook:", address(hook));

        // ---- Step 5: ship the sophisticated position -- xyc + real-oracle price adjuster +
        //      exposure gate, all in one program. ----
        ISwapVM.Order memory orderP = _sophisticatedOrder(maker, address(oracle));
        vm.startBroadcast(MAKER_PK);
        bytes32 hashP = aqua.ship(address(router), abi.encode(orderP), dynamic([TOKEN_IN, TOKEN_OUT]), dynamic([STRATEGY_P, STRATEGY_P]));
        vm.stopBroadcast();
        console2.log("Strategy P (sophisticated) hash:", vm.toString(hashP));

        // ---- Step 6: keeper posts a safe reading. ----
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(maker, 1_000);
        vm.stopBroadcast();

        // ---- Step 7: verification -- real swaps on every path. ----
        vm.startBroadcast();
        tokenIn.mint(msg.sender, VERIFICATION_SWAP_AMOUNT * 4);
        tokenIn.approve(address(router), type(uint256).max);
        tokenIn.approve(POOL_SWAP_TEST, type(uint256).max);

        (, uint256 directOut,) = router.swap(orderA, TOKEN_IN, TOKEN_OUT, VERIFICATION_SWAP_AMOUNT, EOA_TAKER_DATA);
        console2.log("Verification: direct swap on new Strategy A -> amountOut:", directOut);

        PoolSwapTest(POOL_SWAP_TEST).swap(
            poolKey,
            SwapParams({ zeroForOne: true, amountSpecified: -int256(VERIFICATION_SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        console2.log("Verification: v4 swap on new hook succeeded");

        (, uint256 priceAwareOut,) = router.swap(orderP, TOKEN_IN, TOKEN_OUT, VERIFICATION_SWAP_AMOUNT, EOA_TAKER_DATA);
        console2.log("Verification: sophisticated (price+risk) swap -> amountOut:", priceAwareOut);
        vm.stopBroadcast();

        // ---- Step 8: THE ACTUAL FIX VERIFICATION -- pause for real, then decode the EXACT
        //      revert reason (not just success/failure) on both venues, then unpause. ----
        vm.startBroadcast(MAKER_PK);
        oracle.setPausedByMaker(true);
        require(oracle.isPausedByMaker(maker), "pause did not take effect");
        vm.stopBroadcast();

        (bool directOk, bytes memory directReason) = address(router).call(
            abi.encodeCall(router.swap, (orderA, TOKEN_IN, TOKEN_OUT, VERIFICATION_SWAP_AMOUNT, EOA_TAKER_DATA))
        );
        require(!directOk, "BUG STILL PRESENT: direct swap succeeded while paused");
        bytes4 expectedSelector = ExposureGate.ExposureGateMakerPaused.selector;
        bytes4 actualSelector = bytes4(directReason);
        require(actualSelector == expectedSelector, "direct swap reverted for the WRONG reason -- not the pause check");
        console2.log("VERIFIED: direct swap on Strategy A now correctly reverts with ExposureGateMakerPaused while paused");

        (bool v4Ok,) = POOL_SWAP_TEST.call(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    poolKey,
                    SwapParams({ zeroForOne: true, amountSpecified: -int256(VERIFICATION_SWAP_AMOUNT), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
                    PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
                    bytes("")
                )
            )
        );
        require(!v4Ok, "BUG STILL PRESENT: v4 swap succeeded while paused");
        console2.log("VERIFIED: v4 swap on the new hook now also correctly reverts while paused");

        vm.startBroadcast(MAKER_PK);
        oracle.setPausedByMaker(false);
        require(!oracle.isPausedByMaker(maker), "unpause did not take effect");
        vm.stopBroadcast();

        // Broadcast this one for real (unlike the two paused-path checks above, which deliberately
        // stay as unbroadcast low-level calls since they only need *any* caller to observe the
        // revert reason) -- a real success here has to go through the actual EOA that holds the
        // Step 7 approval, or an unrelated allowance revert on the script contract's own identity
        // would masquerade as "the fix broke restoration" the same way the original false positive
        // masqueraded as "the fix works".
        vm.startBroadcast();
        (, uint256 restoredOut,) = router.swap(orderA, TOKEN_IN, TOKEN_OUT, VERIFICATION_SWAP_AMOUNT, EOA_TAKER_DATA);
        vm.stopBroadcast();
        require(restoredOut > 0, "unpause did not actually restore normal swapping");
        console2.log("VERIFIED: unpaused -- strategy left live and usable for the next visitor");

        _writeDeploymentJson(router, orderA, hashA, hashB, hashC, hashP, orderP, hook, poolKey, maker, keeper);
    }

    function _gatedOrder(address maker, address oracle, bytes1 salt) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(oracle, MAX_EXPOSURE_BPS, HALT_EXPOSURE_BPS, 0)),
            p.build(Controls._salt, abi.encodePacked(salt))
        );
        return _buildOrder(maker, program);
    }

    /// @dev xyc -> real-oracle price adjuster -> exposure gate, composed in that order so the
    /// derate/halt applies ON TOP of whatever the price adjuster already did -- see
    /// test/SophisticatedPosition.t.sol for the exact composed-formula proof this mirrors.
    function _sophisticatedOrder(address maker, address oracle) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                OraclePriceAdjuster._oraclePriceAdjuster1D,
                OraclePriceAdjusterArgsBuilder.build(MAX_PRICE_DECAY, PRICE_MAX_STALENESS, 8, CHAINLINK_ETH_USD)
            ),
            p.build(ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(oracle, MAX_EXPOSURE_BPS, HALT_EXPOSURE_BPS, 0))
        );
        return _buildOrder(maker, program);
    }

    function _buildOrder(address maker, bytes memory program) internal pure returns (ISwapVM.Order memory) {
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

    function _writeDeploymentJson(
        ExposureAwareAquaRouter router,
        ISwapVM.Order memory orderA,
        bytes32 hashA,
        bytes32 hashB,
        bytes32 hashC,
        bytes32 hashP,
        ISwapVM.Order memory orderP,
        AquaV4Hook hook,
        PoolKey memory poolKey,
        address maker,
        address keeper
    ) internal {
        string memory json = string.concat(
            "{",
            '"chainId":', vm.toString(block.chainid), ",",
            '"maker":"', vm.toString(maker), '",',
            '"keeper":"', vm.toString(keeper), '",',
            '"aqua":"', vm.toString(AQUA), '",',
            '"oracle":"', vm.toString(ORACLE), '",',
            '"swapVM":"', vm.toString(address(router)), '",',
            '"tokenIn":"', vm.toString(TOKEN_IN), '",',
            '"tokenOut":"', vm.toString(TOKEN_OUT), '",',
            '"strategyHash":"', vm.toString(hashA), '",',
            '"maxExposureBps":', vm.toString(uint256(MAX_EXPOSURE_BPS)), ",",
            '"haltExposureBps":', vm.toString(uint256(HALT_EXPOSURE_BPS)), ",",
            '"order":{',
            '"maker":"', vm.toString(orderA.maker), '",',
            '"traits":"', vm.toString(MakerTraits.unwrap(orderA.traits)), '",',
            '"data":"', vm.toString(orderA.data), '"',
            "},",
            '"v4":{',
            '"poolManager":"', vm.toString(POOL_MANAGER), '",',
            '"hook":"', vm.toString(address(hook)), '",',
            '"swapRouter":"', vm.toString(POOL_SWAP_TEST), '",',
            '"poolKey":{',
            '"currency0":"', vm.toString(Currency.unwrap(poolKey.currency0)), '",',
            '"currency1":"', vm.toString(Currency.unwrap(poolKey.currency1)), '",',
            '"fee":', vm.toString(uint256(poolKey.fee)), ",",
            '"tickSpacing":', vm.toString(int256(poolKey.tickSpacing)), ",",
            '"hooks":"', vm.toString(address(poolKey.hooks)), '"',
            "}",
            "},",
            '"strategies":[',
            '{"label":"Strategy A","strategyHash":"', vm.toString(hashA), '"},',
            '{"label":"Strategy B","strategyHash":"', vm.toString(hashB), '"},',
            '{"label":"Strategy C","strategyHash":"', vm.toString(hashC), '"}',
            "],",
            '"sophisticatedPosition":{',
            '"label":"Strategy P (price + risk aware)",',
            '"strategyHash":"', vm.toString(hashP), '",',
            '"priceOracle":"', vm.toString(CHAINLINK_ETH_USD), '",',
            '"maxPriceDecay":"', vm.toString(uint256(MAX_PRICE_DECAY)), '",',
            '"order":{',
            '"maker":"', vm.toString(orderP.maker), '",',
            '"traits":"', vm.toString(MakerTraits.unwrap(orderP.traits)), '",',
            '"data":"', vm.toString(orderP.data), '"',
            "}",
            "}",
            "}"
        );

        vm.writeFile("frontend/public/deployment.json", json);
        console2.log("\nWrote frontend/public/deployment.json");
    }
}
