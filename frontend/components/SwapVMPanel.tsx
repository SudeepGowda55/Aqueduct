"use client";

import { Contract, formatUnits, parseUnits } from "ethers";
import { useState } from "react";
import { ERC20_ABI, SWAP_VM_ABI } from "@/lib/abis";
import { useActivityLog } from "@/lib/ActivityLogProvider";
import { EOA_TAKER_TRAITS_AND_DATA } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { decodeRevertReason } from "@/lib/decodeError";
import { useWallet } from "@/lib/WalletProvider";

export function SwapVMPanel() {
  const { deployment } = useDeployment();
  const { address, signer } = useWallet();
  const { log } = useActivityLog();
  const [amount, setAmount] = useState("10");
  const [reversed, setReversed] = useState(false);
  const [isSwapping, setIsSwapping] = useState(false);
  const [lastAmountOut, setLastAmountOut] = useState<string | null>(null);

  const canSwap = Boolean(deployment && address && signer && amount);

  const swap = async () => {
    if (!deployment || !signer || !address) return;
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
        maker: deployment.order.maker,
        traits: deployment.order.traits,
        data: deployment.order.data,
      };

      log("info", `Swapping ${amount} tokens directly through SwapVM...`);
      const tx = await swapVM.swap(order, tokenInAddr, tokenOutAddr, amountWei, EOA_TAKER_TRAITS_AND_DATA);
      const receipt = await tx.wait();

      // Swapped(orderHash, maker, taker, tokenIn, tokenOut, amountIn, amountOut)
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
      log("success", `Swap filled -- received ${amountOutText} tokens.`, tx.hash);
    } catch (err) {
      const reason = decodeRevertReason(err);
      log("error", `Swap failed: ${reason}`);
    } finally {
      setIsSwapping(false);
    }
  };

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Swap directly via SwapVM</h3>
      <p className="mt-1 text-xs text-neutral-500">
        Calls <code>swapVM.swap(...)</code> straight from your connected wallet -- no contract
        needed as taker (SwapVM&apos;s <code>useTransferFromAndAquaPush</code> flag handles the
        transfer for you). Runs through the maker&apos;s program, including the exposure gate.
      </p>
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
