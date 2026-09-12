// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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
 * @title AqueductV3DynamicFee
 * @notice One-off: ships a SECOND, ADDITIONAL Uniswap v4 pool for the maker's already-live
 *         Strategy A -- this one with a risk-adjusted dynamic fee (see `AquaV4Hook._applyFee`),
 *         while leaving the existing Strategy A pool (proven bit-for-bit identical to the direct
 *         SwapVM path in `test/CrossVenueConsistency.t.sol`) completely untouched. No re-shipping,
 *         no new router: the exact same maker, oracle, and Strategy A order from
 *         `script/AqueductV2Redeploy.s.sol` are reused as-is -- only a new hook + pool are added.
 *
 * @dev Verifies, on real Base Sepolia state:
 *        1. At a low exposure reading, the v4 swap output is exactly the SwapVM quote minus the
 *           floor fee (5 bps) -- computed off-chain here and asserted with `require`, not merely
 *           logged.
 *        2. Raising exposure raises the fee (and compounds with the SwapVM-side derate) -- the
 *           SAME live oracle reading driving both mechanisms simultaneously.
 *        3. `refreshFee()` pushes the current risk fee onto the pool's persisted `lpFee`
 *           (`StateLibrary.getSlot0`) with NO swap involved -- independently checkable via
 *           `cast call` alone.
 *        4. Exposure is restored to a safe reading at the end, exactly like every other script in
 *           this repo that runs a risk excursion for verification purposes -- this oracle is
 *           shared by every strategy this maker has shipped, so leaving it elevated would derate
 *           strategies this script never touched.
 *
 *      Run it:
 *        forge script script/AqueductV3DynamicFee.s.sol \
 *          --rpc-url <base sepolia rpc> \
 *          --private-key <the same funded account used for prior deployments> \
 *          --broadcast --slow -vvvv
 */
contract AqueductV3DynamicFee is Script, ExposureAquaOpcodes {
    using ProgramBuilder for Program;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant AQUA = 0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461;
    address internal constant ORACLE = 0xE68530d8e694eC6d237F0B07eC24C405c8Cd764A;
    address internal constant ROUTER = 0x00449DD6DCD06327d0ae98f013CfFb7426658B21;
    address internal constant TOKEN_IN = 0x2A22B21b15d6305AbCbe78ff3098aed2F5B54869;
    address internal constant TOKEN_OUT = 0x8BB1a7E6BABc09973a67D417120c3E8396c4822f;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal constant MAKER_PK = uint256(keccak256("aqueduct.demo.maker"));
    uint256 internal constant KEEPER_PK = uint256(keccak256("aqueduct.demo.keeper"));

    uint16 internal constant MAX_EXPOSURE_BPS = 5_000;
    uint16 internal constant HALT_EXPOSURE_BPS = 9_000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant ONE = 1e18;
    bytes internal constant EOA_TAKER_DATA = hex"00000000000000000000000000000000000000000041";

    // Mirrors AquaV4Hook's own private constants exactly, so this script can predict the fee
    // off-chain and assert the on-chain result matches -- not just log it and eyeball it.
    uint24 internal constant MIN_FEE_PIPS = 500;
    uint24 internal constant MAX_FEE_PIPS = 10_000;
    uint16 internal constant FEE_SATURATION_BPS = 9_000;

    uint256 internal constant HOOK_WORKING_CAPITAL = 5_000e18;
    uint256 internal constant VERIFICATION_SWAP_AMOUNT = 1e18;

    constructor() ExposureAquaOpcodes(AQUA) { }

    function run() external {
        address maker = vm.addr(MAKER_PK);
        address keeper = vm.addr(KEEPER_PK);
        require(maker == 0x5067591C365D7D69d76B725c2d9af7b9437132Be, "maker mismatch");
        require(keeper == 0x72759F6952b9c307F57865A5e4651C05C69c8101, "keeper mismatch");

        TokenMock tokenIn = TokenMock(TOKEN_IN);
        TokenMock tokenOut = TokenMock(TOKEN_OUT);
        ExposureOracle oracle = ExposureOracle(ORACLE);
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        // Reconstructs the EXACT SAME order already shipped as Strategy A under ROUTER in
        // AqueductV2Redeploy.s.sol -- identical program bytes, identical hash, no re-shipping.
        ISwapVM.Order memory orderA = _gatedOrder(maker, ORACLE, hex"a2");
        bytes32 strategyHashA = ExposureAwareAquaRouter(payable(ROUTER)).hash(orderA);
        require(
            strategyHashA == 0x0581e5d8783c51f4d45d190a41fee043d7859b8998373296acfc618baa0e64e7,
            "reconstructed order does not match the already-shipped Strategy A hash"
        );

        // ---- Step 1: known-good starting exposure for a deterministic demo. ----
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(maker, 1_000); // 10% -- matches the live frontend's usual resting state
        vm.stopBroadcast();

        // ---- Step 2: new hook + new pool bound to (ROUTER, orderA), but WITH the dynamic-fee
        //      flag -- the only thing that differs from the existing Strategy A pool. ----
        vm.startBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory hookArgs = abi.encode(poolManager, Aqua(AQUA), ExposureAwareAquaRouter(payable(ROUTER)), oracle, orderA);
        (address hookAddress, bytes32 hookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AquaV4Hook).creationCode, hookArgs);
        AquaV4Hook hook =
            new AquaV4Hook{ salt: hookSalt }(poolManager, Aqua(AQUA), ExposureAwareAquaRouter(payable(ROUTER)), oracle, orderA);
        require(address(hook) == hookAddress, "hook address mismatch");
        console2.log("New risk-adjusted-fee AquaV4Hook:", address(hook));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(TOKEN_IN),
            currency1: Currency.wrap(TOKEN_OUT),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        tokenIn.mint(address(hook), HOOK_WORKING_CAPITAL);
        tokenOut.mint(address(hook), HOOK_WORKING_CAPITAL);
        vm.stopBroadcast();
        console2.log("New dynamic-fee pool initialized, poolId:", vm.toString(PoolId.unwrap(PoolIdLibrary.toId(poolKey))));

        // ---- Step 3: verification swap #1 -- low exposure, floor fee. ----
        vm.startBroadcast();
        tokenIn.mint(msg.sender, VERIFICATION_SWAP_AMOUNT * 2);
        tokenIn.approve(POOL_SWAP_TEST, type(uint256).max);

        uint256 gatedQuoteLow = _quoteGated(strategyHashA, 1_000);
        uint24 expectedFeeLow = _expectedFeePips(1_000);
        uint256 expectedOutLow = gatedQuoteLow - (gatedQuoteLow * expectedFeeLow) / LPFeeLibrary.MAX_LP_FEE;

        uint256 actualOutLow = _v4Swap(poolKey);
        require(actualOutLow == expectedOutLow, "low-exposure fee did not match the predicted formula exactly");
        console2.log("VERIFIED: 10%% exposure -> fee (pips):", uint256(expectedFeeLow));
        console2.log("          v4 output matches SwapVM quote minus the floor fee exactly:", actualOutLow);
        vm.stopBroadcast();

        // ---- Step 4: verification swap #2 -- elevated exposure, fee AND gate derate both move,
        //      driven by the identical oracle reading. ----
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(maker, 7_000); // 70% -- squarely in the gate's own derate band
        vm.stopBroadcast();

        vm.startBroadcast();
        uint256 gatedQuoteHigh = _quoteGated(strategyHashA, 7_000);
        uint24 expectedFeeHigh = _expectedFeePips(7_000);
        uint256 expectedOutHigh = gatedQuoteHigh - (gatedQuoteHigh * expectedFeeHigh) / LPFeeLibrary.MAX_LP_FEE;

        uint256 actualOutHigh = _v4Swap(poolKey);
        require(actualOutHigh == expectedOutHigh, "elevated-exposure fee did not match the predicted formula exactly");
        require(expectedFeeHigh > expectedFeeLow, "fee must have actually risen with exposure");
        console2.log("VERIFIED: 70%% exposure -> fee (pips):", uint256(expectedFeeHigh));
        console2.log("          v4 output matches (gate-derated quote) minus (risk fee) exactly:", actualOutHigh);
        vm.stopBroadcast();

        // ---- Step 5: restore a safe reading -- this oracle is shared by every strategy this
        //      maker has shipped, not just this pool. ----
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(maker, 1_000);
        vm.stopBroadcast();
        console2.log("Restored exposure to 10%% -- every strategy left safe for the next visitor");

        // ---- Step 6: refreshFee() persists the fee matching the NOW-restored 10% reading, with
        //      NO swap involved -- independently checkable afterwards via `cast call ...
        //      getSlot0` alone. MUST be broadcast: an earlier version of this script called this
        //      unbroadcast, so the require() below passed against local simulation only while
        //      nothing was ever actually sent -- caught by an independent `cast` check against
        //      real chain state after the first broadcast, not by the script's own assertion.
        vm.startBroadcast();
        hook.refreshFee();
        vm.stopBroadcast();
        (,,, uint24 persistedFee) = poolManager.getSlot0(poolKey.toId());
        require(persistedFee == expectedFeeLow, "refreshFee did not push the exact expected fee with no swap");
        console2.log("VERIFIED: refreshFee() persisted the current risk fee with zero swaps involved");

        console2.log("\nDynamic-fee pool:", address(hook));
        console2.log("poolId:", vm.toString(PoolId.unwrap(PoolIdLibrary.toId(poolKey))));
    }

    /// @dev A pure, off-chain prediction of what the SwapVM path alone (gate included, no v4 fee)
    /// would return for `VERIFICATION_SWAP_AMOUNT` right now: reads the maker's REAL, live
    /// committed balances for this strategy (a view call, no state mutation), applies the exact
    /// same constant-product formula `_xycSwapXD` uses, then applies `_exposureGate1D`'s exact
    /// derate formula -- both already proven bit-exact against the real contracts elsewhere in
    /// this repo (`test/ExposureGate.t.sol`, `test/SophisticatedPosition.t.sol`). Deliberately NOT
    /// a simulate-then-revert trial swap, to avoid any interaction between `vm.snapshotState` and
    /// this script's own `--broadcast` transaction recording.
    function _quoteGated(bytes32 strategyHash, uint64 exposureBps) internal view returns (uint256) {
        (uint256 balIn, uint256 balOut) = Aqua(AQUA).safeBalances(
            vm.addr(MAKER_PK), ROUTER, strategyHash, TOKEN_IN, TOKEN_OUT
        );
        uint256 xycOut = (VERIFICATION_SWAP_AMOUNT * balOut) / (balIn + VERIFICATION_SWAP_AMOUNT);
        return _predictGated(xycOut, exposureBps);
    }

    /// @dev Uses `BalanceDelta`'s own accessors (upper 128 bits = amount0, lower 128 = amount1,
    /// per its own doc comment) rather than manual bit-packing -- a first version of this script
    /// hand-rolled the split and got amount0/amount1 swapped, caught only by this script's own
    /// dry-run `require` check against the predicted formula, exactly the kind of mistake that
    /// check exists to catch.
    function _v4Swap(PoolKey memory poolKey) internal returns (uint256 amountOut) {
        BalanceDelta delta = PoolSwapTest(POOL_SWAP_TEST).swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(VERIFICATION_SWAP_AMOUNT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        amountOut = uint256(int256(delta.amount1()));
    }

    /// @dev Mirrors `_exposureGate1D`'s exact-in derate formula precisely (see ExposureGate.sol).
    function _predictGated(uint256 amountOut, uint64 exposureBps) internal pure returns (uint256) {
        if (exposureBps <= MAX_EXPOSURE_BPS) return amountOut;
        uint256 overage = exposureBps - MAX_EXPOSURE_BPS;
        uint256 band = HALT_EXPOSURE_BPS - MAX_EXPOSURE_BPS;
        uint256 derateFactor = ONE - (overage * ONE) / band;
        return (amountOut * derateFactor) / ONE;
    }

    /// @dev Mirrors `AquaV4Hook._riskFeePips` precisely.
    function _expectedFeePips(uint64 exposureBps) internal pure returns (uint24) {
        uint256 capped = exposureBps > FEE_SATURATION_BPS ? FEE_SATURATION_BPS : exposureBps;
        return uint24(MIN_FEE_PIPS + (uint256(MAX_FEE_PIPS - MIN_FEE_PIPS) * capped) / FEE_SATURATION_BPS);
    }

    function _gatedOrder(address maker, address oracle, bytes1 salt) internal view returns (ISwapVM.Order memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                ExposureGate._exposureGate1D, ExposureGateArgsBuilder.build(oracle, MAX_EXPOSURE_BPS, HALT_EXPOSURE_BPS, 0)
            ),
            p.build(Controls._salt, abi.encodePacked(salt))
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
}
