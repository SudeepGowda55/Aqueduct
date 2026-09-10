"use client";

import { Contract, formatUnits, parseUnits } from "ethers";
import { useState } from "react";
import { ERC20_ABI, POOL_SWAP_TEST_ABI } from "@/lib/abis";
import { useActivityLog } from "@/lib/ActivityLogProvider";
import { MAX_SQRT_PRICE_LIMIT, MIN_SQRT_PRICE_LIMIT } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { decodeRevertReason } from "@/lib/decodeError";
import { useWallet } from "@/lib/WalletProvider";

export function UniswapPanel() {
  const { deployment } = useDeployment();
  const { address, signer } = useWallet();
  const { log } = useActivityLog();
  const [amount, setAmount] = useState("1");
  const [zeroForOne, setZeroForOne] = useState(true);
  const [isSwapping, setIsSwapping] = useState(false);
  const [lastAmountOut, setLastAmountOut] = useState<string | null>(null);

  const v4 = deployment?.v4;
  const canSwap = Boolean(v4 && address && signer && amount);

  const swap = async () => {
    if (!deployment || !v4 || !signer || !address) return;
    setIsSwapping(true);
    setLastAmountOut(null);
    try {
      const tokenInAddr = zeroForOne ? v4.poolKey.currency0 : v4.poolKey.currency1;
      const tokenOutAddr = zeroForOne ? v4.poolKey.currency1 : v4.poolKey.currency0;
      const tokenIn = new Contract(tokenInAddr, ERC20_ABI, signer);
      const tokenOut = new Contract(tokenOutAddr, ERC20_ABI, signer);
      const decimals = await tokenIn.decimals();
      const amountWei = parseUnits(amount, decimals);
      const balanceOutBefore: bigint = await tokenOut.balanceOf(address);

      const allowance: bigint = await tokenIn.allowance(address, v4.swapRouter);
      if (allowance < amountWei) {
        log("info", "Approving the v4 swap router to spend tokenIn...");
        const approveTx = await tokenIn.approve(v4.swapRouter, amountWei);
        await approveTx.wait();
        log("success", "Approved.", approveTx.hash);
      }

      const swapRouter = new Contract(v4.swapRouter, POOL_SWAP_TEST_ABI, signer);
      const key = {
        currency0: v4.poolKey.currency0,
        currency1: v4.poolKey.currency1,
        fee: v4.poolKey.fee,
        tickSpacing: v4.poolKey.tickSpacing,
        hooks: v4.poolKey.hooks,
      };
      const params = {
        zeroForOne,
        amountSpecified: -amountWei,
        sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
      };
      const testSettings = { takeClaims: false, settleUsingBurn: false };

      log("info", `Swapping ${amount} tokens through the Uniswap v4 pool (sourced from Aqua)...`);
      const tx = await swapRouter.swap(key, params, testSettings, "0x");
      await tx.wait();

      const balanceOutAfter: bigint = await tokenOut.balanceOf(address);
      const amountOutText = formatUnits(balanceOutAfter - balanceOutBefore, decimals);

      setLastAmountOut(amountOutText);
      log("success", `Swap filled -- received ${amountOutText} tokens.`, tx.hash);
    } catch (err) {
      const reason = decodeRevertReason(err);
      log("error", `v4 swap failed: ${reason}`);
    } finally {
      setIsSwapping(false);
    }
  };

  if (!v4) {
    return (
      <div className="rounded-xl border border-dashed border-neutral-800 bg-neutral-900/30 p-5">
        <h3 className="text-sm font-semibold text-neutral-400">Swap via Uniswap v4</h3>
        <p className="mt-1 text-xs text-neutral-600">
          No v4 deployment found. Run <code>forge script script/AqueductV4Demo.s.sol ...</code>{" "}
          after the main demo script, then reload.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Swap via Uniswap v4</h3>
      <p className="mt-1 text-xs text-neutral-500">
        Same maker strategy, now backing a real v4 pool through <code>AquaV4Hook</code>. The pool
        has no liquidity of its own -- every fill is sourced live from Aqua, through the same
        exposure gate.
      </p>
      <div className="mt-4 flex items-center gap-2 text-xs text-neutral-400">
        <span>{zeroForOne ? "tokenIn" : "tokenOut"}</span>
        <button
          onClick={() => setZeroForOne((z) => !z)}
          className="rounded-full border border-neutral-700 px-2 py-1 hover:bg-neutral-800"
          title="Flip direction"
        >
          ⇄
        </button>
        <span>{zeroForOne ? "tokenOut" : "tokenIn"}</span>
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
          className="rounded-lg bg-fuchsia-600 px-4 py-2 text-sm font-medium text-white hover:bg-fuchsia-500 disabled:opacity-50"
        >
          {isSwapping ? "Swapping..." : "Swap"}
        </button>
      </div>
      {!address && <p className="mt-2 text-xs text-neutral-600">Connect a wallet to swap.</p>}
      {lastAmountOut && <p className="mt-2 text-xs text-emerald-400">Received: {lastAmountOut}</p>}
    </div>
  );
}
