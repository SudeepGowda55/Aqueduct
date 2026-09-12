import { AbiCoder, concat, keccak256, toBeHex } from "ethers";
import type { PoolKeyJson } from "./deployment";

// Mirrors AquaV4Hook's own private constants exactly (src/hooks/AquaV4Hook.sol).
export const MIN_FEE_PIPS = 500;
export const MAX_FEE_PIPS = 10_000;
export const FEE_SATURATION_BPS = 9_000;

/** Mirrors AquaV4Hook._riskFeePips precisely -- fee units are v4's "hundredths of a bip" (1_000_000 == 100%). */
export function predictedFeePips(exposureBps: number): number {
  const capped = Math.min(exposureBps, FEE_SATURATION_BPS);
  return Math.floor(MIN_FEE_PIPS + ((MAX_FEE_PIPS - MIN_FEE_PIPS) * capped) / FEE_SATURATION_BPS);
}

export function feePipsToPercent(pips: number): string {
  return (pips / 10_000).toFixed(3) + "%";
}

/** Mirrors Uniswap v4's PoolIdLibrary.toId: keccak256(abi.encode(poolKey)). */
export function computePoolId(key: PoolKeyJson): string {
  const encoded = AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "uint24", "int24", "address"],
    [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]
  );
  return keccak256(encoded);
}

// StateLibrary.POOLS_SLOT (index of the `pools` mapping in PoolManager's storage layout).
const POOLS_SLOT = toBeHex(6, 32);

/** Mirrors StateLibrary's _getPoolStateSlot: keccak256(abi.encodePacked(poolId, POOLS_SLOT)). */
export function computePoolStateSlot(poolId: string): string {
  return keccak256(concat([poolId, POOLS_SLOT]));
}

/**
 * Decodes a raw `extsload(stateSlot)` result into slot0's four packed fields, per
 * StateLibrary.getSlot0's own layout comment:
 *   [24 bits unused][24 bits lpFee][24 bits protocolFee][24 bits tick][160 bits sqrtPriceX96]
 */
export function decodeSlot0(raw: string): { sqrtPriceX96: bigint; tick: number; protocolFee: number; lpFee: number } {
  const value = BigInt(raw);
  const sqrtPriceX96 = value & ((1n << 160n) - 1n);
  let tick = Number((value >> 160n) & 0xffffffn);
  if (tick >= 0x800000) tick -= 0x1000000; // sign-extend the 24-bit tick
  const protocolFee = Number((value >> 184n) & 0xffffffn);
  const lpFee = Number((value >> 208n) & 0xffffffn);
  return { sqrtPriceX96, tick, protocolFee, lpFee };
}
