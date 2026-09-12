// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { MakerTraits } from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { HookMiner } from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import { ExposureAwareAquaRouter } from "../src/routers/ExposureAwareAquaRouter.sol";
import { AquaV4Hook } from "../src/hooks/AquaV4Hook.sol";
import { IExposureOracle } from "../src/oracle/IExposureOracle.sol";

/**
 * @title AqueductV4Demo
 * @notice Wires up a real Uniswap v4 pool backed by the SAME maker strategy `AqueductDemo.s.sol`
 *         already shipped, then re-writes `frontend/public/deployment.json` with both the 1inch
 *         and Uniswap sections so the frontend can drive both swap paths.
 *
 * @dev This is a SEPARATE script from `AqueductDemo.s.sol`, run as a second, separate
 *      `forge script` invocation, rather than one script doing everything in a single run.
 *      While iterating on this project's foundry.toml (adding the v4-core compiler profile,
 *      fs_permissions, etc.), a stale forge build/selector cache once caused a spurious
 *      `Failed to decode constructor arguments` / `ABI decoding failed: buffer overrun while
 *      deserializing` error when forge tried to pretty-print the transaction list before
 *      broadcasting an earlier, unrelated deployment -- `forge clean` resolved it, confirming it
 *      was a cache artifact rather than anything about this script's actual logic. The two
 *      scripts stay split regardless: it keeps the 1inch-only demo runnable and legible on its
 *      own (matching the Aqua track's own submission, independent of the Uniswap piece), and
 *      lets this script simply pick up whatever `AquaDemo.s.sol` already deployed by reading
 *      `deployment.json` back, rather than re-deriving or duplicating that setup.
 *
 *      Run it after AqueductDemo.s.sol, against the same anvil node:
 *        forge script script/AqueductV4Demo.s.sol \
 *          --rpc-url http://127.0.0.1:8545 \
 *          --private-key <any funded anvil account> \
 *          --broadcast -vvvv
 */
contract AqueductV4Demo is Script {
    uint256 internal constant HOOK_WORKING_CAPITAL = 50_000e18;
    int24 internal constant TICK_SPACING = 60;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    // Uniswap's own real deployment on Base Sepolia (confirmed verified on BaseScan before use:
    // "PoolManager" / "PoolSwapTest" respectively, both with thousands of prior transactions) --
    // https://developers.uniswap.org/contracts/v4/deployments. Using these instead of deploying
    // our own is both a stronger integration (real v4 core, not a redeploy) and cheaper.
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SEPOLIA_POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;

    // The canonical deterministic CREATE2 deployer proxy (0age/Arachnid's), pre-deployed at
    // genesis on anvil and virtually every EVM chain -- forge script routes any salted `new`
    // through it when broadcasting, so hook-address mining must target this deployer, not the
    // broadcasting EOA (see HookMiner's own doc comment). Confirmed present on Base Sepolia too
    // (real bytecode via `cast code`) before relying on it here.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        string memory json = vm.readFile("frontend/public/deployment.json");

        Aqua aqua = Aqua(vm.parseJsonAddress(json, ".aqua"));
        ExposureAwareAquaRouter swapVM = ExposureAwareAquaRouter(payable(vm.parseJsonAddress(json, ".swapVM")));
        TokenMock tokenIn = TokenMock(vm.parseJsonAddress(json, ".tokenIn"));
        TokenMock tokenOut = TokenMock(vm.parseJsonAddress(json, ".tokenOut"));

        ISwapVM.Order memory order = ISwapVM.Order({
            maker: vm.parseJsonAddress(json, ".order.maker"),
            traits: MakerTraits.wrap(vm.parseJsonUint(json, ".order.traits")),
            data: vm.parseJsonBytes(json, ".order.data")
        });

        bool isBaseSepolia = block.chainid == BASE_SEPOLIA_CHAIN_ID;

        vm.startBroadcast();
        IPoolManager poolManager = isBaseSepolia
            ? IPoolManager(BASE_SEPOLIA_POOL_MANAGER)
            : IPoolManager(vm.deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(msg.sender)));

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        // No exposure oracle in this pre-ExposureGate demo script -- the order carries no gate
        // instruction, so `AquaV4Hook`'s dynamic-fee logic (gated on the pool's own static `fee: 0`
        // below) never touches the oracle; a null address is safe and inert here.
        IExposureOracle noOracle = IExposureOracle(address(0));
        bytes memory constructorArgs = abi.encode(poolManager, aqua, swapVM, noOracle, order);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AquaV4Hook).creationCode, constructorArgs);

        AquaV4Hook hook = new AquaV4Hook{ salt: salt }(poolManager, aqua, swapVM, noOracle, order);
        require(address(hook) == hookAddress, "hook address mismatch");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenIn)),
            currency1: Currency.wrap(address(tokenOut)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

        PoolSwapTest swapRouter =
            isBaseSepolia ? PoolSwapTest(BASE_SEPOLIA_POOL_SWAP_TEST) : new PoolSwapTest(poolManager);

        // Seed the hook's working-capital float (see AquaV4Hook's contract-level comment): a
        // plain ERC20 transfer, no special deposit function needed.
        tokenIn.mint(address(hook), HOOK_WORKING_CAPITAL);
        tokenOut.mint(address(hook), HOOK_WORKING_CAPITAL);
        vm.stopBroadcast();

        console2.log("PoolManager: ", address(poolManager));
        console2.log("AquaV4Hook:  ", address(hook));
        console2.log("PoolSwapTest:", address(swapRouter));

        string memory v4Json = string.concat(
            '"v4":{',
            '"poolManager":"', vm.toString(address(poolManager)), '",',
            '"hook":"', vm.toString(address(hook)), '",',
            '"swapRouter":"', vm.toString(address(swapRouter)), '",',
            '"poolKey":{',
            '"currency0":"', vm.toString(Currency.unwrap(poolKey.currency0)), '",',
            '"currency1":"', vm.toString(Currency.unwrap(poolKey.currency1)), '",',
            '"fee":', vm.toString(uint256(poolKey.fee)), ",",
            '"tickSpacing":', vm.toString(int256(poolKey.tickSpacing)), ",",
            '"hooks":"', vm.toString(address(poolKey.hooks)), '"',
            "}",
            "}"
        );

        // json's closing "}" is its last character; splice the new "v4" key in before it.
        bytes memory jsonBytes = bytes(json);
        string memory withoutClosingBrace = _slice(jsonBytes, 0, jsonBytes.length - 1);
        string memory merged = string.concat(withoutClosingBrace, ",", v4Json, "}");

        vm.writeFile("frontend/public/deployment.json", merged);
        console2.log("\nUpdated frontend/public/deployment.json with the v4 section");
    }

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = data[i];
        }
        return string(result);
    }
}
