// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { MockTaker } from "@1inch/swap-vm/test/mocks/MockTaker.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraits } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
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
 * @title AqueductDemoContinue
 * @notice One-off continuation of AqueductDemo.s.sol's Base Sepolia run, which deployed its first
 *         6 contracts successfully (confirmed via `cast nonce` before writing this) but then hit
 *         a nonce-tracking mismatch against the Alchemy RPC when moving to the next broadcast
 *         block (`Failed to send transaction: nonce too low`, and `--resume` disagreed with the
 *         chain's own reported nonce too: "EOA nonce changed unexpectedly. Expected 5 got 6").
 *         Rather than fight forge's cached broadcast state against an RPC with a nonce-reporting
 *         quirk, this picks up with the 6 already-deployed addresses (extracted directly from
 *         broadcast/AqueductDemo.s.sol/84532/run-latest.json) and does the rest as a fresh
 *         broadcast, which queries the live nonce at send time instead of relying on cached state.
 */
contract AqueductDemoContinue is Script, ExposureAquaOpcodes {
    using ProgramBuilder for Program;

    uint256 internal constant MAKER_PK = uint256(keccak256("aqueduct.demo.maker"));
    uint256 internal constant TAKER_PK = uint256(keccak256("aqueduct.demo.taker"));
    uint256 internal constant KEEPER_PK = uint256(keccak256("aqueduct.demo.keeper"));

    uint256 internal constant INITIAL_LIQUIDITY = 1_000_000e18;
    uint256 internal constant SWAP_AMOUNT = 10_000e18;

    uint16 internal constant MAX_EXPOSURE_BPS = 5_000;
    uint16 internal constant HALT_EXPOSURE_BPS = 9_000;

    Aqua internal constant AQUA = Aqua(0x2e706D0c3a6d9C8d62Bb3276Ff9a1a04e9108461);
    ExposureOracle internal constant ORACLE = ExposureOracle(0xF8c7ccE6a80140b6C6CBA4fE9CA172B6C544fe75);
    ExposureAwareAquaRouter internal constant SWAP_VM =
        ExposureAwareAquaRouter(payable(0xC008DD3D1293543d5FA7AD6eED285eD45E3d7cCc));
    TokenMock internal constant TOKEN_A = TokenMock(0x8BB1a7E6BABc09973a67D417120c3E8396c4822f);
    TokenMock internal constant TOKEN_B = TokenMock(0x2A22B21b15d6305AbCbe78ff3098aed2F5B54869);
    MockTaker internal constant TAKER_CONTRACT = MockTaker(0x3fE1dcaf1126c62f21FD28fF030D5D8B0e1f17d1);

    constructor() ExposureAquaOpcodes(address(0)) { }

    function run() external {
        address maker = vm.addr(MAKER_PK);
        address taker = vm.addr(TAKER_PK);
        address keeper = vm.addr(KEEPER_PK);

        (TokenMock tokenIn, TokenMock tokenOut) =
            address(TOKEN_A) < address(TOKEN_B) ? (TOKEN_A, TOKEN_B) : (TOKEN_B, TOKEN_A);

        vm.startBroadcast();
        payable(maker).transfer(0.01 ether);
        payable(taker).transfer(0.01 ether);
        payable(keeper).transfer(0.01 ether);
        TOKEN_A.mint(maker, INITIAL_LIQUIDITY);
        TOKEN_B.mint(maker, INITIAL_LIQUIDITY);
        tokenIn.mint(address(TAKER_CONTRACT), SWAP_AMOUNT * 100);
        vm.stopBroadcast();

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(XYCSwap._xycSwapXD),
            p.build(
                ExposureGate._exposureGate1D,
                ExposureGateArgsBuilder.build(address(ORACLE), MAX_EXPOSURE_BPS, HALT_EXPOSURE_BPS, 0)
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
        tokenIn.approve(address(AQUA), type(uint256).max);
        tokenOut.approve(address(AQUA), type(uint256).max);
        bytes32 strategyHash = AQUA.ship(
            address(SWAP_VM),
            abi.encode(order),
            dynamic([address(tokenIn), address(tokenOut)]),
            dynamic([INITIAL_LIQUIDITY, INITIAL_LIQUIDITY])
        );
        vm.stopBroadcast();
        console2.log("Shipped strategy:       ", vm.toString(strategyHash));

        console2.log("\n--- Scenario 1: exposure = 1000 bps / 10 pct (below max) -> normal fill ---");
        _pushExposure(keeper, maker, 1_000);
        _swap(order, tokenIn, tokenOut, taker, "Fill 1 (low exposure)");

        console2.log("\n--- Scenario 2: exposure = 7000 bps / 70 pct (between max and halt) -> derated fill ---");
        _pushExposure(keeper, maker, 7_000);
        _swap(order, tokenIn, tokenOut, taker, "Fill 2 (mid exposure)");

        console2.log("\n--- Scenario 3: exposure = 9000 bps / 90 pct (at halt threshold) -> swap must revert ---");
        _pushExposure(keeper, maker, HALT_EXPOSURE_BPS);

        bytes memory takerData = _buildTakerData(taker);
        vm.prank(taker);
        try TAKER_CONTRACT.swap(order, address(tokenIn), address(tokenOut), SWAP_AMOUNT, takerData) returns (uint256, uint256) {
            console2.log("UNEXPECTED: swap succeeded at halt exposure -- this should never happen");
        } catch (bytes memory reason) {
            console2.log("Swap reverted as expected against live on-chain state. Revert data:");
            console2.logBytes(reason);
        }

        _pushExposure(keeper, maker, 1_000);

        _writeDeploymentJson(tokenIn, tokenOut, order, strategyHash, maker, keeper);
    }

    function _pushExposure(address keeper, address maker, uint64 exposureBps) internal {
        vm.startBroadcast(KEEPER_PK);
        ORACLE.pushExposure(maker, exposureBps);
        vm.stopBroadcast();
        console2.log("Keeper", keeper, "pushed exposure (bps):", exposureBps);
    }

    function _swap(ISwapVM.Order memory order, TokenMock tokenIn, TokenMock tokenOut, address taker, string memory label)
        internal
    {
        bytes memory takerData = _buildTakerData(taker);
        vm.startBroadcast(TAKER_PK);
        (uint256 amountIn, uint256 amountOut) =
            TAKER_CONTRACT.swap(order, address(tokenIn), address(tokenOut), SWAP_AMOUNT, takerData);
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

    function _writeDeploymentJson(
        TokenMock tokenIn,
        TokenMock tokenOut,
        ISwapVM.Order memory order,
        bytes32 strategyHash,
        address maker,
        address keeper
    ) internal {
        string memory json = string.concat(
            "{",
            '"chainId":', vm.toString(block.chainid), ",",
            '"maker":"', vm.toString(maker), '",',
            '"keeper":"', vm.toString(keeper), '",',
            '"aqua":"', vm.toString(address(AQUA)), '",',
            '"oracle":"', vm.toString(address(ORACLE)), '",',
            '"swapVM":"', vm.toString(address(SWAP_VM)), '",',
            '"tokenIn":"', vm.toString(address(tokenIn)), '",',
            '"tokenOut":"', vm.toString(address(tokenOut)), '",',
            '"strategyHash":"', vm.toString(strategyHash), '",',
            '"maxExposureBps":', vm.toString(uint256(MAX_EXPOSURE_BPS)), ",",
            '"haltExposureBps":', vm.toString(uint256(HALT_EXPOSURE_BPS)), ",",
            '"order":{',
            '"maker":"', vm.toString(order.maker), '",',
            '"traits":"', vm.toString(MakerTraits.unwrap(order.traits)), '",',
            '"data":"', vm.toString(order.data), '"',
            "}",
            "}"
        );

        vm.writeFile("frontend/public/deployment.json", json);
        console2.log("\nWrote frontend/public/deployment.json");
    }
}
