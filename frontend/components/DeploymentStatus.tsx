"use client";

import { useDeployment } from "@/lib/DeploymentProvider";

export function DeploymentStatus() {
  const { isLoading, error, reload } = useDeployment();

  if (isLoading) {
    return <p className="text-sm text-neutral-500">Loading deployment...</p>;
  }

  if (error) {
    return (
      <div className="rounded-xl border border-red-900/50 bg-red-950/20 p-5 text-sm text-red-300">
        <p className="font-medium">Could not load the deployment.</p>
        <p className="mt-1 text-xs text-red-400">{error}</p>
        <p className="mt-3 text-xs text-neutral-400">
          Run the demo scripts against Base Sepolia (or redeploy fresh) first:
        </p>
        <pre className="mt-1 overflow-x-auto rounded-lg bg-neutral-950 p-3 text-xs text-neutral-300">
{`forge script script/AqueductDemo.s.sol --rpc-url <base sepolia rpc> \\
  --private-key <funded base sepolia account> --broadcast --slow
forge script script/AqueductV4Demo.s.sol --rpc-url <base sepolia rpc> \\
  --private-key <funded base sepolia account> --broadcast --slow`}
        </pre>
        <button
          onClick={reload}
          className="mt-3 rounded-lg border border-red-800 px-3 py-1.5 text-xs text-red-300 hover:bg-red-900/30"
        >
          Retry
        </button>
      </div>
    );
  }

  return null;
}

export function DeploymentAddresses() {
  const { deployment } = useDeployment();
  if (!deployment) return null;

  const rows: [string, string][] = [
    ["Aqua", deployment.aqua],
    ["ExposureOracle", deployment.oracle],
    ["SwapVM router", deployment.swapVM],
    ["tokenIn", deployment.tokenIn],
    ["tokenOut", deployment.tokenOut],
  ];
  if (deployment.v4) {
    rows.push(
      ["PoolManager", deployment.v4.poolManager],
      ["AquaV4Hook", deployment.v4.hook],
      ["v4 swap router", deployment.v4.swapRouter]
    );
  }

  return (
    <details className="rounded-xl border border-neutral-800 bg-neutral-900/30 p-4 text-xs">
      <summary className="cursor-pointer text-neutral-400">Deployed contract addresses</summary>
      <dl className="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 font-mono text-neutral-500">
        {rows.map(([label, addr]) => (
          <div key={label} className="contents">
            <dt className="text-neutral-600">{label}</dt>
            <dd>{addr}</dd>
          </div>
        ))}
      </dl>
    </details>
  );
}
