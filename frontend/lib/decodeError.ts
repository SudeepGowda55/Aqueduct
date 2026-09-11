import { Interface } from "ethers";

// The custom errors a viewer is actually likely to hit while playing with the demo, so failures
// read as "the exposure gate halted this" rather than an opaque raw revert selector.
const KNOWN_ERRORS = new Interface([
  "error ExposureGateExceedsHaltThreshold(address maker, uint64 exposureBps, uint16 haltExposureBps)",
  "error ExposureGateOracleStale(uint256 currentTime, uint256 updatedAt, uint16 maxStaleness)",
  "error ExposureGateMakerPaused(address maker)",
  "error ExactOutputNotSupported()",
  "error LiquidityNotAllowed()",
  // v4-core wraps every hook-callback revert in this before it reaches the top-level caller (see
  // CustomRevert.sol) -- unwrapped below so a halted v4 swap decodes the same as a direct one.
  "error WrappedError(address target, bytes4 selector, bytes reason, bytes details)",
]);

/** Best-effort: pulls a hex error selector out of an ethers error and decodes it if recognized. */
export function decodeRevertReason(err: unknown): string {
  const raw = extractErrorData(err);
  if (raw) {
    try {
      const decoded = decodeKnown(raw);
      if (decoded) return decoded;
    } catch {
      // fall through to generic message below
    }
  }
  return err instanceof Error ? err.message : String(err);
}

function decodeKnown(raw: string): string | null {
  const decoded = KNOWN_ERRORS.parseError(raw);
  if (!decoded) return null;

  if (decoded.name === "WrappedError") {
    // Recurse into the actual hook-thrown reason -- a v4 swap halted by the exposure gate should
    // read identically to a direct SwapVM halt, not as an opaque "WrappedError" from PoolManager.
    const [, , reason] = decoded.args;
    return decodeKnown(reason) ?? "WrappedError (unrecognized inner reason)";
  }
  if (decoded.name === "ExposureGateExceedsHaltThreshold") {
    const [, exposureBps, haltExposureBps] = decoded.args;
    return `Halted: maker exposure is ${Number(exposureBps) / 100}%, at or above the ${Number(haltExposureBps) / 100}% halt threshold.`;
  }
  if (decoded.name === "ExposureGateOracleStale") {
    return "Halted: the exposure oracle reading is stale.";
  }
  if (decoded.name === "ExposureGateMakerPaused") {
    return "Halted: the maker has paused this strategy themselves (emergency kill switch).";
  }
  return decoded.name;
}

function extractErrorData(err: unknown): string | null {
  if (typeof err !== "object" || err === null) return null;
  const candidate = err as { data?: unknown; error?: { data?: unknown } };
  const data = candidate.data ?? candidate.error?.data;
  return typeof data === "string" && data.startsWith("0x") ? data : null;
}
