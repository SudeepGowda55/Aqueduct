// Mirrors lib/swap-vm/src/instructions/XYCSwap.sol's `_xycSwapXD` EXACTLY, for the exact-in case
// this frontend uses everywhere: amountOut = (amountIn * balanceOut) / (balanceIn + amountIn),
// floor division. This is the constant-product curve UNGATED -- i.e. what the maker's pool would
// give up with no `_exposureGate1D` in the program at all. `balanceIn`/`balanceOut` should come
// straight from a live `Aqua.safeBalances(maker, app, strategyHash, tokenIn, tokenOut)` read, the
// same real, current reserves the actual gated on-chain swap computes against -- so this is a
// faithful "what would this exact pool give right now if ungated" number, not an approximation.
export function xycAmountOut(amountIn: bigint, balanceIn: bigint, balanceOut: bigint): bigint {
  if (balanceIn <= 0n || balanceOut <= 0n || amountIn <= 0n) return 0n;
  return (amountIn * balanceOut) / (balanceIn + amountIn);
}

const ONE = 1_000_000_000_000_000_000n; // 1e18, matching ExposureGate.sol's fixed-point scale

/**
 * Mirrors `_exposureGate1D`'s exact-in derate math EXACTLY (see src/opcodes/ExposureGate.sol):
 *   - exposureBps <= maxExposureBps          -> no-op
 *   - maxExposureBps < exposureBps < halt    -> linear derate down towards (but never reaching) 0
 *   - exposureBps >= haltExposureBps         -> halted, no fill at all
 * Computed client-side from a live oracle reading + the live pool reserves (via `xycAmountOut`)
 * so this comparison works instantly, for any visitor, before a wallet even connects -- the same
 * public-RPC-only pattern the rest of this dashboard already uses (see ExposureGauge).
 */
export function applyExposureGate(
  ungatedAmountOut: bigint,
  exposureBps: bigint,
  maxExposureBps: bigint,
  haltExposureBps: bigint
): { amountOut: bigint; halted: boolean } {
  if (exposureBps <= maxExposureBps) return { amountOut: ungatedAmountOut, halted: false };
  if (exposureBps >= haltExposureBps) return { amountOut: 0n, halted: true };

  const overage = exposureBps - maxExposureBps;
  const band = haltExposureBps - maxExposureBps;
  const derateFactor = ONE - (overage * ONE) / band;
  return { amountOut: (ungatedAmountOut * derateFactor) / ONE, halted: false };
}
