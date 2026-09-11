// Fixed `takerTraitsAndData` for a plain-wallet ("EOA") exact-input swap directly against
// SwapVM: isExactIn + useTransferFromAndAquaPush flags set, every optional field (threshold,
// `to` override, deadline, hooks, callbacks, instructionsArgs, signature) left empty.
//
// TakerTraitsLib.build() never actually embeds the `taker` address anywhere in the packed bytes
// for this configuration (see TakerTraits.sol: `to` is only written when it differs from both
// zero and `taker`, and every other dynamic field is length-encoded via the same all-empty
// offsets) -- SwapVM instead reads the real taker as `msg.sender` at call time. So this exact
// 22-byte constant works for ANY connected wallet; there's nothing to compute per-user. Verified
// against TakerTraitsLib.build's actual Solidity output for this Args shape before relying on it
// here (see AGENTS/README notes) -- it is not a guess.
export const EOA_TAKER_TRAITS_AND_DATA = "0x00000000000000000000000000000000000000000041";

// v4-core's TickMath.MIN_SQRT_PRICE + 1 / MAX_SQRT_PRICE - 1 -- the loosest valid price limits,
// used here because AquaV4Hook fully overrides pricing (the core AMM curve never actually moves
// the price), so the limit only needs to satisfy PoolManager's bounds checks.
export const MIN_SQRT_PRICE_LIMIT = 4295128740n;
export const MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;

export const EXPOSURE_BANDS = {
  safeLabel: "Safe",
  derateLabel: "Derated",
  haltLabel: "Halted",
} as const;

// Mirrors ExposureGate.sol's own boundary semantics exactly (`exposureBps <= maxExposureBps` is
// the no-op/safe band, not `<`) -- getting this off by one would make the UI disagree with the
// contract at the exact threshold value.
export function exposureBand(
  exposureBps: number,
  maxExposureBps: number,
  haltExposureBps: number
): "safe" | "derate" | "halt" {
  if (exposureBps >= haltExposureBps) return "halt";
  if (exposureBps > maxExposureBps) return "derate";
  return "safe";
}
