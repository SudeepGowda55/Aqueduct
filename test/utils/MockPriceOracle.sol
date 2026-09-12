// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPriceOracle } from "@1inch/swap-vm/src/instructions/interfaces/IPriceOracle.sol";

/// @dev Minimal, settable stand-in for a Chainlink AggregatorV3Interface feed, for testing
/// `OraclePriceAdjuster` locally. `lib/swap-vm` ships no mock of its own for this instruction.
/// The live deployment points at a real, independently-verified Chainlink ETH/USD feed on Base
/// Sepolia (`0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`) instead of this.
contract MockPriceOracle is IPriceOracle {
    int256 public price;
    uint256 public updatedAt;

    constructor(int256 initialPrice) {
        price = initialPrice;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "MockPriceOracle";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, updatedAt, updatedAt, 1);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, updatedAt, updatedAt, 1);
    }
}
