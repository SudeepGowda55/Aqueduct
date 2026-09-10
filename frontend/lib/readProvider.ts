import { JsonRpcProvider } from "ethers";

// Base's own public Sepolia RPC -- deliberately not a personal Alchemy/Infura URL. This file
// ships to every visitor's browser as plain client-side JS, so anything hardcoded here is public;
// a keyed RPC endpoint would leak that key to anyone who opens devtools. Deployment scripts (run
// locally, never shipped to a browser) can safely use a keyed endpoint instead.
const BASE_SEPOLIA_PUBLIC_RPC = "https://sepolia.base.org";

let cached: JsonRpcProvider | null = null;

export function getReadProvider(): JsonRpcProvider {
  if (!cached) {
    cached = new JsonRpcProvider(BASE_SEPOLIA_PUBLIC_RPC);
  }
  return cached;
}
