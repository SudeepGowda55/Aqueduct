"use client";

import { useWallet } from "@/lib/WalletProvider";

function shortenAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

export function ConnectWallet() {
  const { address, isConnecting, error, isWrongNetwork, connect, disconnect } = useWallet();

  if (!address) {
    return (
      <div className="flex flex-col items-end gap-1">
        <button
          onClick={connect}
          disabled={isConnecting}
          className="rounded-lg bg-cyan-600 px-4 py-2 text-sm font-medium text-white hover:bg-cyan-500 disabled:opacity-50"
        >
          {isConnecting ? "Connecting..." : "Connect Wallet"}
        </button>
        {error && <p className="max-w-xs text-right text-xs text-red-400">{error}</p>}
      </div>
    );
  }

  return (
    <div className="flex flex-col items-end gap-1">
      <div className="flex items-center gap-2">
        {isWrongNetwork && (
          <span className="rounded-full bg-amber-500/20 px-2 py-1 text-xs font-medium text-amber-400">
            Wrong network
          </span>
        )}
        <span className="rounded-lg bg-neutral-800 px-3 py-2 text-sm font-mono text-neutral-200">
          {shortenAddress(address)}
        </span>
        <button
          onClick={disconnect}
          className="rounded-lg border border-neutral-700 px-3 py-2 text-xs text-neutral-400 hover:bg-neutral-800"
        >
          Disconnect
        </button>
      </div>
      {isWrongNetwork && (
        <p className="max-w-xs text-right text-xs text-amber-400">
          Switch your wallet to Base Sepolia (chain id 84532) to use this app.
        </p>
      )}
    </div>
  );
}
