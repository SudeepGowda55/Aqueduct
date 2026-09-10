import { Interface } from "ethers";

// The custom errors a viewer is actually likely to hit while playing with the demo, so failures
// read as "the exposure gate halted this" rather than an opaque raw revert selector.
const KNOWN_ERRORS = new Interface([
  "error ExposureGateExceedsHaltThreshold(address maker, uint64 exposureBps, uint16 haltExposureBps)",
  "error ExposureGateOracleStale(uint256 currentTime, uint256 updatedAt, uint16 maxStaleness)",
  "error ExactOutputNotSupported()",
  "error LiquidityNotAllowed()",
]);

/** Best-effort: pulls a hex error selector out of an ethers error and decodes it if recognized. */
export function decodeRevertReason(err: unknown): string {
  const raw = extractErrorData(err);
  if (raw) {
    try {
      const decoded = KNOWN_ERRORS.parseError(raw);
      if (decoded) {
        if (decoded.name === "ExposureGateExceedsHaltThreshold") {
          const [, exposureBps, haltExposureBps] = decoded.args;
          return `Halted: maker exposure is ${Number(exposureBps) / 100}%, at or above the ${Number(haltExposureBps) / 100}% halt threshold.`;
        }
        if (decoded.name === "ExposureGateOracleStale") {
          return "Halted: the exposure oracle reading is stale.";
        }
        return decoded.name;
      }
    } catch {
      // fall through to generic message below
    }
  }
  return err instanceof Error ? err.message : String(err);
}

function extractErrorData(err: unknown): string | null {
  if (typeof err !== "object" || err === null) return null;
  const candidate = err as { data?: unknown; error?: { data?: unknown } };
  const data = candidate.data ?? candidate.error?.data;
  return typeof data === "string" && data.startsWith("0x") ? data : null;
}
