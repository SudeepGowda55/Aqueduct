// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Context } from "@1inch/swap-vm/src/libs/VM.sol";

// Identical import set and ordering to 1inch's own AquaOpcodes.sol, plus ExposureGate appended.
// New instructions are added at the end to preserve backward compatibility with any program
// already bytecode-referencing these opcode indices -- the same convention 1inch's own
// Opcodes.sol / AquaOpcodes.sol document and follow themselves.
import { Controls } from "@1inch/swap-vm/src/instructions/Controls.sol";
import { XYCSwap } from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import { XYCConcentrate } from "@1inch/swap-vm/src/instructions/XYCConcentrate.sol";
import { Decay } from "@1inch/swap-vm/src/instructions/Decay.sol";
import { Fee } from "@1inch/swap-vm/src/instructions/Fee.sol";
import { PeggedSwap } from "@1inch/swap-vm/src/instructions/PeggedSwap.sol";
import { Extruction } from "@1inch/swap-vm/src/instructions/Extruction.sol";

import { ExposureGate } from "./ExposureGate.sol";

/// @title ExposureAquaOpcodes
/// @notice 1inch's AquaOpcodes instruction set with one new instruction appended: `_exposureGate1D`.
/// @dev This is a byte-for-byte copy of AquaOpcodes._opcodes()'s instruction table, plus a single
///      new opcode slot at the end. Every existing opcode keeps its original index, so any
///      program built against stock AquaOpcodes remains valid against this set.
contract ExposureAquaOpcodes is
    Controls,
    XYCSwap,
    XYCConcentrate,
    Decay,
    Fee,
    PeggedSwap,
    Extruction,
    ExposureGate
{
    constructor(address aqua) Fee(aqua) {}

    function _notInstruction(Context memory /* ctx */, bytes calldata /* args */) internal view {}

    function _opcodes() internal pure virtual returns (function(Context memory, bytes calldata) internal[] memory result) {
        function(Context memory, bytes calldata) internal[36] memory instructions = [
            _notInstruction,
            // Debug - reserved for debugging utilities (core infrastructure)
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            // Controls - control flow (core infrastructure)
            Controls._jump,
            Controls._jumpIfTokenIn,
            Controls._jumpIfTokenOut,
            Controls._deadline,
            Controls._onlyTakerTokenBalanceNonZero,
            Controls._onlyTakerTokenBalanceGte,
            Controls._onlyTakerTokenSupplyShareGte,
            // XYCSwap - basic swap (most common swap type)
            XYCSwap._xycSwapXD,
            // XYCConcentrate - liquidity concentration (common AMM feature)
            XYCConcentrate._xycConcentrateGrowLiquidity2D,
            // Decay - Decay AMM (specific AMM)
            Decay._decayXD,
            // NOTE: Add new instructions here to maintain backward compatibility
            Controls._salt,
            Fee._flatFeeAmountInXD,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            _notInstruction,
            Fee._protocolFeeAmountInXD,
            Fee._aquaProtocolFeeAmountInXD,
            Fee._dynamicProtocolFeeAmountInXD,
            Fee._aquaDynamicProtocolFeeAmountInXD,
            PeggedSwap._peggedSwapGrowPriceRange2D,
            Extruction._extruction,
            Controls._onlyTxOriginTokenBalanceNonZero,
            // Aqueduct: new instruction, appended at the end (index 35)
            ExposureGate._exposureGate1D
        ];

        // Efficiently turning static memory array into dynamic memory array
        // by rewriting _notInstruction with array length, so it's excluded from the result
        uint256 instructionsArrayLength = instructions.length - 1;
        assembly ("memory-safe") {
            result := instructions
            mstore(result, instructionsArrayLength)
        }
    }
}
