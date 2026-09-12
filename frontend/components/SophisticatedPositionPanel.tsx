"use client";

import { Contract, formatUnits, parseUnits } from "ethers";
import { useEffect, useState } from "react";
import { ERC20_ABI, PRICE_ORACLE_ABI, SWAP_VM_ABI } from "@/lib/abis";
import { useActivityLog } from "@/lib/ActivityLogProvider";
import { EOA_TAKER_TRAITS_AND_DATA } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { decodeRevertReason } from "@/lib/decodeError";
import { getReadProvider } from "@/lib/readProvider";
import { useWallet } from "@/lib/WalletProvider";

/**
 * Strategy P: a single SwapVM program composing THREE instructions -- `_xycSwapXD` ->
 * `_oraclePriceAdjuster1D` (1inch's own instruction, reading a real Chainlink feed, wired into
 * `AquaOpcodes` for the first time by this project) -> `_exposureGate1D`. Bounded from both
 * directions: the price adjuster can only ever improve a fill toward the oracle (capped), and the
 * exposure gate can only ever worsen it toward the maker's real risk (capped the other way) --
 * see test/SophisticatedPosition.t.sol for the exact-formula proof.
 */
export function SophisticatedPositionPanel() {
  const { deployment } = useDeployment();
  const { address, signer } = useWallet();
  const { log } = useActivityLog();

  const [livePrice, setLivePrice] = useState<string | null>(null);
  const [amount, setAmount] = useState("1");
  const [reversed, setReversed] = useState(false);
  const [isSwapping, setIsSwapping] = useState(false);
  const [lastAmountOut, setLastAmountOut] = useState<string | null>(null);

  const position = deployment?.sophisticatedPosition;

  useEffect(() => {
    if (!position) return;
    let cancelled = false;
    const provider = getReadProvider();
    const feed = new Contract(position.priceOracle, PRICE_ORACLE_ABI, provider);
    Promise.all([feed.decimals(), feed.latestRoundData()])
      .then(([decimals, roundData]) => {
        if (cancelled) return;
        setLivePrice(formatUnits(roundData.answer, decimals));
      })
      .catch(() => {
        if (!cancelled) setLivePrice(null);
      });
    return () => {
      cancelled = true;
    };
  }, [position]);

  const capPercent = position
    ? ((2e18 - Number(position.maxPriceDecay)) / 1e18 - 1) * 100
    : 0;

  const canSwap = Boolean(deployment && position && address && signer && amount);

  const swap = async () => {
    if (!deployment || !position || !signer || !address) return;
    setIsSwapping(true);
    setLastAmountOut(null);
    try {
      const [tokenInAddr, tokenOutAddr] = reversed
        ? [deployment.tokenOut, deployment.tokenIn]
        : [deployment.tokenIn, deployment.tokenOut];

      const tokenIn = new Contract(tokenInAddr, ERC20_ABI, signer);
      const decimals = await tokenIn.decimals();
      const amountWei = parseUnits(amount, decimals);

      const allowance: bigint = await tokenIn.allowance(address, deployment.swapVM);
      if (allowance < amountWei) {
        log("info", "Approving SwapVM to spend tokenIn...");
        const approveTx = await tokenIn.approve(deployment.swapVM, amountWei);
        await approveTx.wait();
        log("success", "Approved.", approveTx.hash);
      }

      const swapVM = new Contract(deployment.swapVM, SWAP_VM_ABI, signer);
      const order = {
        maker: position.order.maker,
        traits: position.order.traits,
        data: position.order.data,
      };

      log("info", `Swapping ${amount} tokens through Strategy P (price-adjusted + exposure-gated)...`);
      const tx = await swapVM.swap(order, tokenInAddr, tokenOutAddr, amountWei, EOA_TAKER_TRAITS_AND_DATA);
      const receipt = await tx.wait();

      const swappedLog = receipt.logs.find(
        (l: { topics: string[] }) => l.topics[0] === swapVM.interface.getEvent("Swapped")?.topicHash
      );
      let amountOutText = "(check activity log for tx)";
      if (swappedLog) {
        const parsed = swapVM.interface.parseLog(swappedLog);
        if (parsed) {
          amountOutText = formatUnits(parsed.args.amountOut, decimals);
        }
      }
      setLastAmountOut(amountOutText);
      log("success", `Strategy P fill -- received ${amountOutText} tokens.`, tx.hash);
    } catch (err) {
      const reason = decodeRevertReason(err);
      log("error", `Strategy P swap failed: ${reason}`);
    } finally {
      setIsSwapping(false);
    }
  };

  if (!position) {
    return (
      <div className="rounded-xl border border-dashed border-neutral-800 bg-neutral-900/30 p-5">
        <h3 className="text-sm font-semibold text-neutral-400">Strategy P (price + risk aware)</h3>
        <p className="mt-1 text-xs text-neutral-600">
          No sophisticated position found in this deployment. Run{" "}
          <code>forge script script/AqueductV2Redeploy.s.sol ...</code>, then reload.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">{position.label}</h3>
      <p className="mt-1 text-xs text-neutral-500">
        One program, three SwapVM instructions:{" "}
        <code>_xycSwapXD</code> &rarr; <code>_oraclePriceAdjuster1D</code> &rarr;{" "}
        <code>_exposureGate1D</code>. A favorable oracle reading can only ever improve the fill
        (capped at +{capPercent.toFixed(0)}%); the exposure gate can only ever worsen it toward the
        maker&apos;s real risk. Neither can override the other&apos;s direction.
      </p>

      <div className="mt-3 rounded-lg border border-neutral-800 bg-neutral-950 p-3 text-xs">
        <div className="text-neutral-500">
          Live Chainlink feed:{" "}
          <a
            href={`https://sepolia.basescan.org/address/${position.priceOracle}`}
            target="_blank"
            rel="noreferrer"
            className="text-cyan-400 hover:underline"
          >
            {position.priceOracle.slice(0, 10)}…
          </a>
        </div>
        <div className="mt-1 text-base font-semibold text-cyan-300">
          {livePrice === null ? "…" : `$${Number(livePrice).toFixed(2)}`}
        </div>
      </div>

      <div className="mt-4 flex items-center gap-2 text-xs text-neutral-400">
        <span>{reversed ? "tokenOut" : "tokenIn"}</span>
        <button
          onClick={() => setReversed((r) => !r)}
          className="rounded-full border border-neutral-700 px-2 py-1 hover:bg-neutral-800"
          title="Flip direction"
        >
          ⇄
        </button>
        <span>{reversed ? "tokenIn" : "tokenOut"}</span>
      </div>
      <div className="mt-3 flex gap-2">
        <input
          type="number"
          min={0}
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          className="flex-1 rounded-lg border border-neutral-700 bg-neutral-950 px-3 py-2 text-sm text-neutral-200"
          placeholder="Amount"
        />
        <button
          onClick={swap}
          disabled={!canSwap || isSwapping}
          className="rounded-lg bg-cyan-600 px-4 py-2 text-sm font-medium text-white hover:bg-cyan-500 disabled:opacity-50"
        >
          {isSwapping ? "Swapping..." : "Swap"}
        </button>
      </div>
      {!address && <p className="mt-2 text-xs text-neutral-600">Connect a wallet to swap.</p>}
      {lastAmountOut && <p className="mt-2 text-xs text-emerald-400">Received: {lastAmountOut}</p>}
    </div>
  );
}
