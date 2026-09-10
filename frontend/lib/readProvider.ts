import { JsonRpcProvider } from "ethers";

// A read-only fallback so dashboard data (exposure, balances) can render before a wallet is
// connected, or for viewers who don't have MetaMask at all. Local anvil only, by design -- this
// whole app is a local demo frontend, not a production dApp meant to work against arbitrary RPCs.
let cached: JsonRpcProvider | null = null;

export function getReadProvider(): JsonRpcProvider {
  if (!cached) {
    cached = new JsonRpcProvider("http://127.0.0.1:8545");
  }
  return cached;
}
