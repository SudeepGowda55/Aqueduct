// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraits } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";

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
 * @title AqueductRedeployOracle
 * @notice One-off, not part of the normal two-script flow (`AqueductDemo.s.sol` +
 *         `AqueductV4Demo.s.sol`): `ExposureOracle.setPausedByMaker`/`isPausedByMaker` (the
 *         maker's own emergency kill switch, added per the project review's threat-model
 *         feedback) were written *after* the original Base Sepolia deployment, so the already-live
 *         `ExposureOracle` predates them. Rather than redeploy the entire stack from scratch
 *         (burning more Aqua/token/SwapVM deployments that didn't actually change), this script
 *         reuses every unaffected piece -- `Aqua`, `ExposureAwareAquaRouter`, both `TokenMock`s,
 *         the maker and keeper addresses, Uniswap's real `PoolManager`/`PoolSwapTest` -- and only
 *         deploys what actually depends on the new oracle code: a fresh `ExposureOracle`, a new
 *         maker order/strategy whose `_exposureGate1D` args point at it (orders are immutable once
 *         shipped, so the old order can't just be edited in place), and a fresh `AquaV4Hook` +
 *         pool bound to that new order (the hook is immutable per-order too).
 *
 *         The maker's original strategy (against the old oracle) is left shipped and untouched --
 *         harmless, and simpler than trying to dock it mid-script. Only the NEW strategy/oracle
 *         pair is written to `deployment.json`, so the frontend and every doc reference the new
 *         one going forward.
 *
 *         Run it once, against Base Sepolia, with the same funded account that owns the existing
 *         `TokenMock`s (required for the `mint` calls below):
 *           forge script script/AqueductRedeployOracle.s.sol \
 *             --rpc-url <base sepolia rpc> \
 *             --private-key <the same funded account used for the original deployment> \
 *             --broadcast --slow -vvvv
 */
contract AqueductRedeployOracle is Script, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant MAKER_PK = uint256(keccak256("aqueduct.demo.maker"));
    uint256 internal constant KEEPER_PK = uint256(keccak256("aqueduct.demo.keeper"));

    address internal constant AQUA = 0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461;
    address internal constant SWAP_VM = 0xC008DD3D1293543d5FA7AD6eED285eD45E3d7cCc;
    address internal constant TOKEN_IN = 0x2A22B21b15d6305AbCbe78ff3098aed2F5B54869;
    address internal constant TOKEN_OUT = 0x8BB1a7E6BABc09973a67D417120c3E8396c4822f;
    address internal constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;

    // Same CREATE2 deployer proxy AqueductV4Demo.s.sol mines against when broadcasting.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 internal constant NEW_STRATEGY_LIQUIDITY = 100_000e18;
    uint256 internal constant HOOK_WORKING_CAPITAL = 10_000e18;
    uint256 internal constant VERIFICATION_SWAP_AMOUNT = 1e18;
    uint16 internal constant MAX_EXPOSURE_BPS = 5_000;
    uint16 internal constant HALT_EXPOSURE_BPS = 9_000;
    int24 internal constant TICK_SPACING = 60;
    bytes internal constant EOA_TAKER_DATA = hex"00000000000000000000000000000000000000000041";

    constructor() ExposureAquaOpcodes(AQUA) { }

    function run() external {
        address maker = vm.addr(MAKER_PK);
        address keeper = vm.addr(KEEPER_PK);
        require(maker == 0x5067591C365D7D69d76B725c2d9af7b9437132Be, "maker address mismatch vs existing deployment");
        require(keeper == 0x72759F6952b9c307F57865A5e4651C05C69c8101, "keeper address mismatch vs existing deployment");

        Aqua aqua = Aqua(AQUA);
        TokenMock tokenIn = TokenMock(TOKEN_IN);
        TokenMock tokenOut = TokenMock(TOKEN_OUT);
        ExposureAwareAquaRouter swapVM = ExposureAwareAquaRouter(payable(SWAP_VM));

        // ---- Deploy the new ExposureOracle (with setPausedByMaker/isPausedByMaker) and give the
        //      maker fresh committable liquidity for the new strategy below. ----
        vm.startBroadcast();
        ExposureOracle oracle = new ExposureOracle(msg.sender, keeper);
        tokenIn.mint(maker, NEW_STRATEGY_LIQUIDITY);
        tokenOut.mint(maker, NEW_STRATEGY_LIQUIDITY);
        vm.stopBroadcast();
        console2.log("New ExposureOracle:     ", address(oracle));

        // ---- Build a new order pointing at the new oracle, and ship it as a new Aqua strategy
        //      under the SAME maker, Aqua, SwapVM router, and tokens as before. ----
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                ExposureGate._exposureGate1D,
                ExposureGateArgsBuilder.build(address(oracle), MAX_EXPOSURE_BPS, HALT_EXPOSURE_BPS, 0)
            )
        );
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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

        vm.startBroadcast(MAKER_PK);
        tokenIn.approve(AQUA, type(uint256).max);
        tokenOut.approve(AQUA, type(uint256).max);
        bytes32 strategyHash = aqua.ship(
            SWAP_VM, abi.encode(order), dynamic([TOKEN_IN, TOKEN_OUT]),
            dynamic([NEW_STRATEGY_LIQUIDITY, NEW_STRATEGY_LIQUIDITY])
        );
        vm.stopBroadcast();
        console2.log("New strategy hash:      ", vm.toString(strategyHash));

        // ---- Deploy a fresh AquaV4Hook bound to the new order, and a fresh pool for it (a hook's
        //      order is immutable per its constructor args, so the old hook can't be re-pointed). ----
        vm.startBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), aqua, swapVM, oracle, order);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AquaV4Hook).creationCode, constructorArgs);

        AquaV4Hook hook = new AquaV4Hook{ salt: salt }(IPoolManager(POOL_MANAGER), aqua, swapVM, oracle, order);
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
        console2.log("New AquaV4Hook:         ", address(hook));

        // ---- Verification, exactly like the original demo: push a safe reading, run one real
        //      swap on each venue, then exercise and reset the new maker-pause kill switch so the
        //      strategy is left in a normal, usable state for future site visitors. ----
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(maker, 1_000);
        vm.stopBroadcast();

        vm.startBroadcast();
        tokenIn.mint(msg.sender, VERIFICATION_SWAP_AMOUNT);
        tokenIn.approve(SWAP_VM, type(uint256).max);
        (, uint256 directOut,) = swapVM.swap(order, TOKEN_IN, TOKEN_OUT, VERIFICATION_SWAP_AMOUNT, EOA_TAKER_DATA);
        console2.log("Verification: direct SwapVM swap amountOut:", directOut);

        tokenIn.mint(msg.sender, VERIFICATION_SWAP_AMOUNT);
        tokenIn.approve(POOL_SWAP_TEST, type(uint256).max);
        PoolSwapTest(POOL_SWAP_TEST).swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(VERIFICATION_SWAP_AMOUNT),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        console2.log("Verification: v4 swap through the new hook succeeded");
        vm.stopBroadcast();

        vm.startBroadcast(MAKER_PK);
        oracle.setPausedByMaker(true);
        require(oracle.isPausedByMaker(maker), "pause did not take effect");
        console2.log("Verification: maker pause is live and readable");
        vm.stopBroadcast();

        // Prove the pause actually halts a fill, as a plain (non-broadcast) call rather than a
        // queued transaction -- forge's broadcast pre-flight replays the whole batch before
        // sending anything and aborts the entire run the moment one call is predicted to revert,
        // exactly the same reasoning AqueductDemo.s.sol's own halt scenario documents. Then
        // immediately undo the pause -- left paused, the live demo would appear permanently broken
        // to the next site visitor.
        (bool haltedAsExpected,) = SWAP_VM.call(
            abi.encodeCall(swapVM.swap, (order, TOKEN_IN, TOKEN_OUT, VERIFICATION_SWAP_AMOUNT, EOA_TAKER_DATA))
        );
        console2.log("Verification: swap while paused reverted as expected:", !haltedAsExpected);

        vm.startBroadcast(MAKER_PK);
        oracle.setPausedByMaker(false);
        require(!oracle.isPausedByMaker(maker), "unpause did not take effect");
        vm.stopBroadcast();
        console2.log("Verification: maker unpaused -- strategy left in normal, usable state");

        _writeDeploymentJson(oracle, order, strategyHash, hook, poolKey, maker, keeper);
    }

    function _writeDeploymentJson(
        ExposureOracle oracle,
        ISwapVM.Order memory order,
        bytes32 strategyHash,
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
            '"oracle":"', vm.toString(address(oracle)), '",',
            '"swapVM":"', vm.toString(SWAP_VM), '",',
            '"tokenIn":"', vm.toString(TOKEN_IN), '",',
            '"tokenOut":"', vm.toString(TOKEN_OUT), '",',
            '"strategyHash":"', vm.toString(strategyHash), '",',
            '"maxExposureBps":', vm.toString(uint256(MAX_EXPOSURE_BPS)), ",",
            '"haltExposureBps":', vm.toString(uint256(HALT_EXPOSURE_BPS)), ",",
            '"order":{',
            '"maker":"', vm.toString(order.maker), '",',
            '"traits":"', vm.toString(MakerTraits.unwrap(order.traits)), '",',
            '"data":"', vm.toString(order.data), '"',
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
            "}",
            "}"
        );

        vm.writeFile("frontend/public/deployment.json", json);
        console2.log("\nWrote frontend/public/deployment.json");
    }
}
