// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";
import { Simulator } from "@1inch/solidity-utils/contracts/mixins/Simulator.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";

import { ExposureAquaOpcodes } from "../opcodes/ExposureAquaOpcodes.sol";

/// @title ExposureAwareAquaRouter
/// @notice Aqua-backed SwapVM router (mirrors 1inch's own AquaSwapVMRouter) using
///         ExposureAquaOpcodes instead of stock AquaOpcodes, so makers can compose the new
///         `_exposureGate1D` instruction into their programs alongside every existing opcode.
contract ExposureAwareAquaRouter is Simulator, SwapVM, ExposureAquaOpcodes {
    constructor(
        address aqua,
        address weth,
        address owner,
        string memory name,
        string memory version
    ) SwapVM(aqua, weth, owner, name, version) ExposureAquaOpcodes(aqua) { }

    /// @dev Returns instruction set for VM execution
    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
