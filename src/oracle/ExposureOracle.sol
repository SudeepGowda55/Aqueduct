// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IExposureOracle } from "./IExposureOracle.sol";

/// @title ExposureOracle
/// @notice On-chain sink for a maker's live cross-protocol exposure, computed off-chain by the
///         Aqueduct Graph pipeline (Substreams + Messari-standardized subgraphs across every
///         protocol the maker has a position in) and posted here by an authorized keeper.
/// @dev Deliberately minimal: this contract only stores what the keeper reports. All the
///      cross-protocol aggregation logic lives off-chain in the Graph layer; this is just the
///      landing pad a SwapVM instruction can read synchronously and cheaply, mirroring how
///      SwapVM's OraclePriceAdjuster reads a Chainlink aggregator.
contract ExposureOracle is IExposureOracle, Ownable {
    /// @notice Thrown when a non-keeper attempts to post an update
    error NotKeeper(address caller);
    /// @notice Thrown when exposureBps exceeds 100% (10_000 bps) -- values above that are almost
    ///         certainly a keeper bug, not a real reading
    error ExposureExceedsOneHundredPercent(uint64 exposureBps);

    /// @notice Emitted whenever a keeper posts a fresh exposure reading for a maker
    event ExposureUpdated(address indexed maker, uint64 exposureBps, uint256 updatedAt);
    /// @notice Emitted when the keeper address is changed
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);

    struct Reading {
        uint64 exposureBps;
        uint256 updatedAt;
    }

    /// @notice The address authorized to post exposure updates (the Graph pipeline's relayer)
    address public keeper;

    mapping(address maker => Reading) private _readings;

    modifier onlyKeeper() {
        require(msg.sender == keeper, NotKeeper(msg.sender));
        _;
    }

    constructor(address initialOwner, address initialKeeper) Ownable(initialOwner) {
        keeper = initialKeeper;
        emit KeeperUpdated(address(0), initialKeeper);
    }

    /// @notice Rotate the keeper address (e.g. if the off-chain relayer key is rotated)
    function setKeeper(address newKeeper) external onlyOwner {
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice Post a fresh exposure reading for `maker`
    /// @dev Intentionally trivial and permissioned to exactly one relayer key: the safety
    ///      property this project relies on is not "the oracle is trustworthy" but "the opcode
    ///      that reads it can never use a bad reading to over-quote a taker" (see ExposureGate).
    function pushExposure(address maker, uint64 exposureBps) external onlyKeeper {
        require(exposureBps <= 10_000, ExposureExceedsOneHundredPercent(exposureBps));
        _readings[maker] = Reading({ exposureBps: exposureBps, updatedAt: block.timestamp });
        emit ExposureUpdated(maker, exposureBps, block.timestamp);
    }

    /// @inheritdoc IExposureOracle
    function exposureOf(address maker) external view returns (uint64 exposureBps, uint256 updatedAt) {
        Reading storage r = _readings[maker];
        return (r.exposureBps, r.updatedAt);
    }
}
