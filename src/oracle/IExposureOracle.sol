// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IExposureOracle
/// @notice Read interface for a maker's live cross-protocol exposure, expressed in basis points
///         of some app-defined notional (e.g. utilized / total committable liquidity).
/// @dev Mirrors the shape of a Chainlink-style price feed (see SwapVM's IPriceOracle) so it can be
///      consumed by a SwapVM instruction the same way OraclePriceAdjuster consumes a price feed.
interface IExposureOracle {
    /// @notice Latest known exposure for `maker`
    /// @param maker The liquidity provider whose cross-protocol exposure is being read
    /// @return exposureBps Exposure in basis points (10_000 = 100%)
    /// @return updatedAt Unix timestamp of the last update, for staleness checks
    function exposureOf(address maker) external view returns (uint64 exposureBps, uint256 updatedAt);
}
