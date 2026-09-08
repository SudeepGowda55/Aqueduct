// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Calldata } from "@1inch/solidity-utils/contracts/libraries/Calldata.sol";
import { Context, ContextLib } from "@1inch/swap-vm/src/libs/VM.sol";

import { IExposureOracle } from "../oracle/IExposureOracle.sol";

/// @dev Args layout for `_exposureGate1D`, packed identically to how SwapVM's own instructions
///      (see OraclePriceAdjuster) pack theirs: fixed-width fields, no ABI encoding overhead.
library ExposureGateArgsBuilder {
    using Calldata for bytes;

    error ExposureGateHaltMustExceedMax(uint16 maxExposureBps, uint16 haltExposureBps);
    error ExposureGateMissingOracleAddressArg();
    error ExposureGateMissingMaxExposureArg();
    error ExposureGateMissingHaltExposureArg();
    error ExposureGateMissingMaxStalenessArg();

    /// @param oracleAddress   Address of the IExposureOracle to read the maker's exposure from
    /// @param maxExposureBps  Exposure at/below this (bps): no adjustment, program passes through untouched
    /// @param haltExposureBps Exposure at/above this (bps): hard revert, no fill at all
    /// @param maxStaleness    Max age of the oracle reading in seconds; 0 disables the staleness check
    function build(
        address oracleAddress,
        uint16 maxExposureBps,
        uint16 haltExposureBps,
        uint16 maxStaleness
    ) internal pure returns (bytes memory) {
        require(haltExposureBps > maxExposureBps, ExposureGateHaltMustExceedMax(maxExposureBps, haltExposureBps));
        return abi.encodePacked(oracleAddress, maxExposureBps, haltExposureBps, maxStaleness);
    }

    function parse(bytes calldata args) internal pure returns (
        address oracleAddress,
        uint16 maxExposureBps,
        uint16 haltExposureBps,
        uint16 maxStaleness
    ) {
        oracleAddress = address(bytes20(args.slice(0, 20, ExposureGateMissingOracleAddressArg.selector)));
        maxExposureBps = uint16(bytes2(args.slice(20, 22, ExposureGateMissingMaxExposureArg.selector)));
        haltExposureBps = uint16(bytes2(args.slice(22, 24, ExposureGateMissingHaltExposureArg.selector)));
        maxStaleness = uint16(bytes2(args.slice(24, 26, ExposureGateMissingMaxStalenessArg.selector)));
    }
}

/**
 * @notice Exposure Gate instruction: derates or halts a fill based on the maker's live
 *         cross-protocol exposure, sourced from an on-chain IExposureOracle that is itself fed
 *         by an off-chain Graph pipeline (Substreams + standardized subgraphs) aggregating the
 *         maker's positions across every venue they've shipped liquidity to via Aqua.
 *
 * @dev MONOTONIC BY CONSTRUCTION -- this is the load-bearing safety property of the whole
 *      opcode, so it is enforced structurally rather than by convention:
 *        - exposureBps <= maxExposureBps  -> no-op, registers untouched
 *        - maxExposureBps < exposureBps < haltExposureBps -> linear derate, strictly worse for taker
 *        - exposureBps >= haltExposureBps -> hard revert, no fill at all
 *      There is no code path in this instruction that can increase ctx.swap.amountOut or decrease
 *      ctx.swap.amountIn relative to what the preceding swap-computing instructions produced. A
 *      stale, wrong, or even maliciously-signed oracle reading can therefore only ever make the
 *      maker quote *more* conservatively than the unsigned SwapVM program already authorized --
 *      never trade beyond it. This makes it the structural mirror of SwapVM's own
 *      OraclePriceAdjuster, which is one-directional in the opposite sense (only ever improves
 *      the taker's price, never worsens it).
 *
 *      Must run after a swap-computing instruction (e.g. _xycSwapXD, _dynamicBalancesXD) has
 *      already populated both ctx.swap.amountIn and ctx.swap.amountOut, exactly like
 *      OraclePriceAdjuster and MinRate's adjustment instructions.
 */
contract ExposureGate {
    using Math for uint256;
    using ContextLib for Context;

    error ExposureGateShouldBeAppliedAfterSwap();
    error ExposureGateOracleStale(uint256 currentTime, uint256 updatedAt, uint16 maxStaleness);
    error ExposureGateExceedsHaltThreshold(address maker, uint64 exposureBps, uint16 haltExposureBps);

    /// @param args.oracleAddress   | 20 bytes
    /// @param args.maxExposureBps  | 2 bytes (uint16)
    /// @param args.haltExposureBps | 2 bytes (uint16)
    /// @param args.maxStaleness    | 2 bytes (uint16)
    function _exposureGate1D(Context memory ctx, bytes calldata args) internal view {
        require(ctx.swap.amountIn > 0 && ctx.swap.amountOut > 0, ExposureGateShouldBeAppliedAfterSwap());

        (
            address oracleAddress,
            uint16 maxExposureBps,
            uint16 haltExposureBps,
            uint16 maxStaleness
        ) = ExposureGateArgsBuilder.parse(args);

        (uint64 exposureBps, uint256 updatedAt) = IExposureOracle(oracleAddress).exposureOf(ctx.query.maker);

        require(
            maxStaleness == 0 || block.timestamp <= updatedAt + maxStaleness,
            ExposureGateOracleStale(block.timestamp, updatedAt, maxStaleness)
        );

        if (exposureBps <= maxExposureBps) {
            return;
        }

        require(exposureBps < haltExposureBps, ExposureGateExceedsHaltThreshold(ctx.query.maker, exposureBps, haltExposureBps));

        // Linear derate from 1e18 (untouched, at maxExposureBps) down towards 0 (at
        // haltExposureBps, which is instead caught by the revert above before ever being
        // reached) -- strictly positive here since exposureBps < haltExposureBps was just checked.
        uint256 overage = exposureBps - maxExposureBps;
        uint256 band = haltExposureBps - maxExposureBps;
        uint256 derateFactor = 1e18 - (overage * 1e18) / band;

        if (ctx.query.isExactIn) {
            ctx.swap.amountOut = (ctx.swap.amountOut * derateFactor) / 1e18;
        } else {
            ctx.swap.amountIn = (ctx.swap.amountIn * 1e18).ceilDiv(derateFactor);
        }
    }
}
