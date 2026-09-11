export const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
];

export const EXPOSURE_ORACLE_ABI = [
  "function exposureOf(address maker) view returns (uint64 exposureBps, uint256 updatedAt)",
  "function pushExposure(address maker, uint64 exposureBps)",
  "function keeper() view returns (address)",
  "function owner() view returns (address)",
  // Maker-only emergency kill switch (see src/oracle/ExposureOracle.sol) -- reverts against any
  // deployment predating this function, which EmergencyPausePanel handles explicitly.
  "function isPausedByMaker(address maker) view returns (bool)",
  "function setPausedByMaker(bool paused)",
];

// Only the pieces the frontend calls directly. `swap`'s Order tuple must match
// ISwapVM.Order exactly (maker, traits, data) for the ABI encoder to build valid calldata.
export const SWAP_VM_ABI = [
  "function swap((address maker, uint256 traits, bytes data) order, address tokenIn, address tokenOut, uint256 amount, bytes takerTraitsAndData) returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash)",
  "function hash((address maker, uint256 traits, bytes data) order) view returns (bytes32)",
  "event Swapped(bytes32 orderHash, address maker, address taker, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)",
];

export const AQUA_ABI = [
  "function safeBalances(address maker, address app, bytes32 strategyHash, address token0, address token1) view returns (uint256 balance0, uint256 balance1)",
];

// v4-core's own reference swap router (PoolSwapTest). Generic and reusable by any caller, not
// exclusive to Foundry tests -- see the README for why this project uses it as the frontend's v4
// entry point instead of a bespoke router.
export const POOL_SWAP_TEST_ABI = [
  "function swap((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, (bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, (bool takeClaims, bool settleUsingBurn) testSettings, bytes hookData) payable returns (int256 delta)",
];
