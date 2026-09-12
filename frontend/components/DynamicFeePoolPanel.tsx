"use client";

import { Contract, formatUnits, parseUnits } from "ethers";
import { useCallback, useEffect, useState } from "react";
import { AQUA_V4_HOOK_ABI, ERC20_ABI, EXPOSURE_ORACLE_ABI, POOL_MANAGER_ABI, POOL_SWAP_TEST_ABI } from "@/lib/abis";
import { useActivityLog } from "@/lib/ActivityLogProvider";
import { MAX_SQRT_PRICE_LIMIT, MIN_SQRT_PRICE_LIMIT } from "@/lib/constants";
import { useDeployment } from "@/lib/DeploymentProvider";
import { decodeRevertReason } from "@/lib/decodeError";
import { computePoolId, computePoolStateSlot, decodeSlot0, feePipsToPercent, predictedFeePips } from "@/lib/dynamicFee";
import { getReadProvider } from "@/lib/readProvider";
import { useWallet } from "@/lib/WalletProvider";

/**
 * A second, independent Uniswap v4 capability layered on the same maker strategy and oracle as
 * UniswapPanel's pool: a swap fee that scales with live exposure via v4's own
 * `LPFeeLibrary`/`updateDynamicLPFee` mechanism. Two numbers are shown deliberately, not one:
 * the PREDICTED fee (computed client-side from the same live oracle reading the contract itself
 * reads -- free, no transaction) and the PERSISTED fee (read directly off PoolManager's own
 * storage via `extsload`, the exact mechanism `StateLibrary.getSlot0` uses on-chain) -- these can
 * differ, because the persisted value only updates when someone (a keeper, or the button below)
 * actually calls `refreshFee()`. See src/hooks/AquaV4Hook.sol and FEEDBACK.md item 4 for why that
 * distinction is real, not a UI nuance.
 */
export function DynamicFeePoolPanel() {
  const { deployment } = useDeployment();
  const { address, signer } = useWallet();
  const { log } = useActivityLog();

  const [predictedFee, setPredictedFee] = useState<number | null>(null);
  const [persistedFee, setPersistedFee] = useState<number | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const [amount, setAmount] = useState("1");
  const [zeroForOne, setZeroForOne] = useState(true);
  const [isSwapping, setIsSwapping] = useState(false);
  const [lastAmountOut, setLastAmountOut] = useState<string | null>(null);

  const pool = deployment?.dynamicFeePool;
  const v4 = deployment?.v4;

  const readOnChainState = useCallback(async () => {
    if (!deployment || !pool || !v4) return;
    const provider = getReadProvider();

    const oracle = new Contract(deployment.oracle, EXPOSURE_ORACLE_ABI, provider);
    const [exposureBps] = await oracle.exposureOf(deployment.maker);
    setPredictedFee(predictedFeePips(Number(exposureBps)));

    const poolId = computePoolId(pool.poolKey);
    const slot = computePoolStateSlot(poolId);
    const manager = new Contract(v4.poolManager, POOL_MANAGER_ABI, provider);
    const raw: string = await manager.extsload(slot);
    setPersistedFee(decodeSlot0(raw).lpFee);
  }, [deployment, pool, v4]);

  useEffect(() => {
    readOnChainState().catch(() => {
      // Best-effort background read; swap/refresh actions surface their own errors.
    });
  }, [readOnChainState]);

  const refreshFee = async () => {
    if (!deployment || !pool || !signer) return;
    setIsRefreshing(true);
    try {
      const hook = new Contract(pool.hook, AQUA_V4_HOOK_ABI, signer);
      log("info", "Pushing the current risk fee onto the pool's persisted state (no swap involved)...");
      const tx = await hook.refreshFee();
      await tx.wait();
      log("success", "refreshFee() confirmed -- re-reading persisted lpFee from PoolManager storage.", tx.hash);
      await readOnChainState();
    } catch (err) {
      const reason = decodeRevertReason(err);
      log("error", `refreshFee failed: ${reason}`);
    } finally {
      setIsRefreshing(false);
    }
  };

  const canSwap = Boolean(pool && v4 && address && signer && amount);

  const swap = async () => {
    if (!deployment || !pool || !v4 || !signer || !address) return;
    setIsSwapping(true);
    setLastAmountOut(null);
    try {
      const tokenInAddr = zeroForOne ? pool.poolKey.currency0 : pool.poolKey.currency1;
      const tokenOutAddr = zeroForOne ? pool.poolKey.currency1 : pool.poolKey.currency0;
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
        currency0: pool.poolKey.currency0,
        currency1: pool.poolKey.currency1,
        fee: pool.poolKey.fee,
        tickSpacing: pool.poolKey.tickSpacing,
        hooks: pool.poolKey.hooks,
      };
      const params = {
        zeroForOne,
        amountSpecified: -amountWei,
        sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT,
      };
      const testSettings = { takeClaims: false, settleUsingBurn: false };

      log("info", `Swapping ${amount} tokens through the risk-adjusted dynamic-fee v4 pool...`);
      const tx = await swapRouter.swap(key, params, testSettings, "0x");
      await tx.wait();

      const balanceOutAfter: bigint = await tokenOut.balanceOf(address);
      const amountOutText = formatUnits(balanceOutAfter - balanceOutBefore, decimals);

      setLastAmountOut(amountOutText);
      log("success", `Swap filled -- received ${amountOutText} tokens (fee applied).`, tx.hash);
      await readOnChainState();
    } catch (err) {
      const reason = decodeRevertReason(err);
      log("error", `Dynamic-fee swap failed: ${reason}`);
    } finally {
      setIsSwapping(false);
    }
  };

  if (!pool || !v4) {
    return (
      <div className="rounded-xl border border-dashed border-neutral-800 bg-neutral-900/30 p-5">
        <h3 className="text-sm font-semibold text-neutral-400">Risk-adjusted dynamic fee (Uniswap v4)</h3>
        <p className="mt-1 text-xs text-neutral-600">
          No dynamic-fee pool found in this deployment. Run{" "}
          <code>forge script script/AqueductV3DynamicFee.s.sol ...</code> after the main demo
          script, then reload.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900/50 p-5">
      <h3 className="text-sm font-semibold text-neutral-200">Risk-adjusted dynamic fee (Uniswap v4)</h3>
      <p className="mt-1 text-xs text-neutral-500">
        A SECOND, additional pool bound to the same Strategy A order and oracle as the plain v4
        pool -- this one charges a swap fee (5&ndash;100 bps) that scales with the maker&apos;s
        live exposure, via v4&apos;s own <code>updateDynamicLPFee</code> mechanism. The plain v4
        pool is completely unaffected.
      </p>

      <div className="mt-4 grid grid-cols-2 gap-3 text-xs">
        <div className="rounded-lg border border-neutral-800 bg-neutral-950 p-3">
          <div className="text-neutral-500">Predicted fee (live oracle read, free)</div>
          <div className="mt-1 text-base font-semibold text-cyan-300">
            {predictedFee === null ? "…" : `${predictedFee} pips (${feePipsToPercent(predictedFee)})`}
          </div>
        </div>
        <div className="rounded-lg border border-neutral-800 bg-neutral-950 p-3">
          <div className="text-neutral-500">Persisted on-chain fee (PoolManager storage)</div>
          <div className="mt-1 text-base font-semibold text-fuchsia-300">
            {persistedFee === null ? "…" : `${persistedFee} pips (${feePipsToPercent(persistedFee)})`}
          </div>
        </div>
      </div>

      <button
        onClick={refreshFee}
        disabled={!signer || isRefreshing}
        className="mt-3 w-full rounded-lg border border-neutral-700 bg-neutral-900 px-3 py-2 text-xs font-medium text-neutral-200 hover:bg-neutral-800 disabled:opacity-50"
      >
        {isRefreshing ? "Refreshing..." : "Push current fee on-chain (refreshFee) -- no swap needed"}
      </button>

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
      {!address && <p className="mt-2 text-xs text-neutral-600">Connect a wallet to swap or refresh the fee.</p>}
      {lastAmountOut && <p className="mt-2 text-xs text-emerald-400">Received: {lastAmountOut} (net of fee)</p>}
    </div>
  );
}
