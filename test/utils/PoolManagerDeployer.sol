// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";

/// @dev Exists solely so `forge build` produces a compiled `PoolManager` artifact that tests can
/// deploy via `vm.deployCode` by name. `PoolManager.sol` pins an exact `pragma solidity 0.8.26`,
/// incompatible in the same compilation graph with swap-vm/aqua's exact `0.8.30` pin -- this file
/// is kept out of that graph (nothing in it imports this file) specifically to avoid the conflict.
contract PoolManagerDeployer {
    function deploy(address initialOwner) external returns (address) {
        return address(new PoolManager(initialOwner));
    }
}
