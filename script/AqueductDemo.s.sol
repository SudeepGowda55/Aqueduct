// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { MockTaker } from "@1inch/swap-vm/test/mocks/MockTaker.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraitsLib } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";

import { Program, ProgramBuilder } from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import { dynamic } from "@1inch/swap-vm/test/utils/Dynamic.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { ExposureAquaOpcodes } from "../src/opcodes/ExposureAquaOpcodes.sol";
import { ExposureGate, ExposureGateArgsBuilder } from "../src/opcodes/ExposureGate.sol";
import { ExposureOracle } from "../src/oracle/ExposureOracle.sol";

/**
 * @title AqueductDemo
 * @notice End-to-end local demo of the ExposureGate opcode as real, broadcast on-chain
 *         transactions -- not `forge test` pranks. Deploys the real 1inch Aqua contract and a
 *         modified SwapVM router, ships real maker liquidity into it, then swaps through the
 *         gate three times as the maker's live cross-protocol exposure climbs:
 *           1. low exposure   -> normal fill, gate is a no-op
 *           2. mid exposure   -> derated fill, taker gets strictly less (or pays strictly more)
 *           3. halt exposure  -> swap reverts outright, no fill at all
 *
 * @dev 1inch's own repos ship no real mainnet/testnet Aqua or SwapVM deployment addresses (see
 *      lib/aqua/config/constants.json and lib/swap-vm/config/constants.json -- both are
 *      zero-address placeholders for local anvil, chain id 31337). The Aqua track's rules allow
 *      this directly: "Official Aqua/SwapVM contracts must be used (redeployments of a modified
 *      SwapVM contract is allowed)" and "local forks are ok". So this demo deploys fresh,
 *      unmodified-Aqua + modified-SwapVM instances onto a local anvil node and drives them with
 *      real signed transactions -- genuine on-chain execution, not a mainnet fork, because there
 *      is no real deployment to fork against.
 *
 *      The maker, taker, and keeper are throwaway demo accounts derived from fixed constants
 *      in-script (not real secrets) and funded by the deployer at runtime -- nothing here needs
 *      an external wallet or a pre-funded testnet faucet.
 *
 *      Run it:
 *        anvil
 *        forge script script/AqueductDemo.s.sol \
 *          --rpc-url http://127.0.0.1:8545 \
 *          --private-key <any funded anvil account> \
 *          --broadcast -vvvv
 */
contract AqueductDemo is Script, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant MAKER_PK = uint256(keccak256("aqueduct.demo.maker"));
    uint256 internal constant TAKER_PK = uint256(keccak256("aqueduct.demo.taker"));
    uint256 internal constant KEEPER_PK = uint256(keccak256("aqueduct.demo.keeper"));

    uint256 internal constant INITIAL_LIQUIDITY = 1_000_000e18;
    uint256 internal constant SWAP_AMOUNT = 10_000e18;

    uint16 internal constant MAX_EXPOSURE_BPS = 5_000; // 50%: below this, no adjustment
    uint16 internal constant HALT_EXPOSURE_BPS = 9_000; // 90%: at/above this, hard revert

    // The Fee opcode's stored AQUA address is unused by this demo's program (only _xycSwapXD and
    // _exposureGate1D are used), so a placeholder here is harmless -- see ExposureAquaOpcodes.
    constructor() ExposureAquaOpcodes(address(0)) { }

    function run() external {
        address maker = vm.addr(MAKER_PK);
        address taker = vm.addr(TAKER_PK);
        address keeper = vm.addr(KEEPER_PK);

        console2.log("Maker: ", maker);
        console2.log("Taker: ", taker);
        console2.log("Keeper:", keeper);

        // ---- Deploy the real Aqua contract, the modified SwapVM router, the exposure oracle,
        //      and two demo tokens; fund the throwaway demo actors. ----
        vm.startBroadcast();
        Aqua aqua = new Aqua();
        ExposureOracle oracle = new ExposureOracle(msg.sender, keeper);
        ExposureAwareAquaRouter swapVM = new ExposureAwareAquaRouter(
            address(aqua), address(0), msg.sender, "Aqueduct", "1.0.0"
        );
        TokenMock tokenIn = new TokenMock("Aqueduct Demo USDC", "aUSDC");
        TokenMock tokenOut = new TokenMock("Aqueduct Demo WETH", "aWETH");
        MockTaker takerContract = new MockTaker(aqua, swapVM, taker);

        payable(maker).transfer(1 ether);
        payable(taker).transfer(1 ether);
        payable(keeper).transfer(1 ether);

        tokenIn.mint(maker, INITIAL_LIQUIDITY);
        tokenOut.mint(maker, INITIAL_LIQUIDITY);
        tokenIn.mint(address(takerContract), SWAP_AMOUNT * 100);
        vm.stopBroadcast();

        console2.log("Aqua:                   ", address(aqua));
        console2.log("ExposureOracle:         ", address(oracle));
        console2.log("ExposureAwareAquaRouter:", address(swapVM));
        console2.log("tokenIn (aUSDC):        ", address(tokenIn));
        console2.log("tokenOut (aWETH):       ", address(tokenOut));

        // ---- Build the maker's program: an XYC-curve AMM gated by live cross-protocol
        //      exposure, read from `oracle` at swap time. ----
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

        // ---- Maker ships real liquidity into Aqua. ----
        vm.startBroadcast(MAKER_PK);
        tokenIn.approve(address(aqua), type(uint256).max);
        tokenOut.approve(address(aqua), type(uint256).max);
        bytes32 strategyHash = aqua.ship(
            address(swapVM),
            abi.encode(order),
            dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([INITIAL_LIQUIDITY, INITIAL_LIQUIDITY])
        );
        vm.stopBroadcast();
        console2.log("Shipped strategy:       ", vm.toString(strategyHash));

        // ---- Scenario 1: low exposure -- gate is a no-op, normal AMM fill. ----
        console2.log("\n--- Scenario 1: exposure = 1000 bps / 10 pct (below max) -> normal fill ---");
        _pushExposure(oracle, keeper, maker, 1_000);
        _swap(takerContract, order, tokenIn, tokenOut, taker, "Fill 1 (low exposure)");

        // ---- Scenario 2: mid-band exposure -- gate derates the fill, strictly worse for
        //      the taker than scenario 1's pool-implied price, never better. ----
        console2.log("\n--- Scenario 2: exposure = 7000 bps / 70 pct (between max and halt) -> derated fill ---");
        _pushExposure(oracle, keeper, maker, 7_000);
        _swap(takerContract, order, tokenIn, tokenOut, taker, "Fill 2 (mid exposure)");

        // ---- Scenario 3: halt exposure -- the swap must revert outright. ----
        console2.log("\n--- Scenario 3: exposure = 9000 bps / 90 pct (at halt threshold) -> swap must revert ---");
        _pushExposure(oracle, keeper, maker, HALT_EXPOSURE_BPS);

        // Deliberately NOT wrapped in vm.startBroadcast()/stopBroadcast(): forge's broadcast
        // pre-flight replays every recorded transaction before sending any of them, and aborts
        // the *entire* batch the moment one is predicted to revert -- so queuing a call we know
        // will revert would silently prevent scenarios 1 and 2 from ever being sent for real,
        // even though this try/catch handles it fine locally. Executed as a plain call instead,
        // it still runs against the real, already-broadcast on-chain state of the live node
        // (the maker's actual shipped strategy, the actual pushed exposure reading) -- it just
        // isn't itself submitted as a transaction, since a transaction guaranteed to fail has
        // nothing more to prove on top of what this trace already shows.
        bytes memory takerData = _buildTakerData(taker);
        vm.prank(taker); // MockTaker.swap() is onlyOwner(taker); without a real broadcast, msg.sender would otherwise be this script contract
        try takerContract.swap(order, address(tokenIn), address(tokenOut), SWAP_AMOUNT, takerData) returns (uint256, uint256) {
            console2.log("UNEXPECTED: swap succeeded at halt exposure -- this should never happen");
        } catch (bytes memory reason) {
            console2.log("Swap reverted as expected against live on-chain state. Revert data:");
            console2.logBytes(reason);
        }
    }

    function _pushExposure(ExposureOracle oracle, address keeper, address maker, uint64 exposureBps) internal {
        vm.startBroadcast(KEEPER_PK);
        oracle.pushExposure(maker, exposureBps);
        vm.stopBroadcast();
        console2.log("Keeper", keeper, "pushed exposure (bps):", exposureBps);
    }

    function _swap(
        MockTaker takerContract,
        ISwapVM.Order memory order,
        TokenMock tokenIn,
        TokenMock tokenOut,
        address taker,
        string memory label
    ) internal {
        bytes memory takerData = _buildTakerData(taker);

        vm.startBroadcast(TAKER_PK);
        (uint256 amountIn, uint256 amountOut) =
            takerContract.swap(order, address(tokenIn), address(tokenOut), SWAP_AMOUNT, takerData);
        vm.stopBroadcast();

        console2.log(label, "-- amountIn:", amountIn);
        console2.log(label, "-- amountOut:", amountOut);
    }

    function _buildTakerData(address taker) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
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
    }
}
