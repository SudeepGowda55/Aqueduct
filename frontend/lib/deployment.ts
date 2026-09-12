export interface DeploymentOrder {
  maker: string;
  traits: string;
  data: string;
}

export interface PoolKeyJson {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
}

export interface V4Deployment {
  poolManager: string;
  hook: string;
  swapRouter: string;
  poolKey: PoolKeyJson;
}

export interface NamedStrategy {
  label: string;
  strategyHash: string;
}

// Strategy P: xyc -> oraclePriceAdjuster (real Chainlink feed) -> exposureGate, composed in one
// program. See script/AqueductV2Redeploy.s.sol and test/SophisticatedPosition.t.sol.
export interface SophisticatedPosition {
  label: string;
  strategyHash: string;
  priceOracle: string;
  maxPriceDecay: string;
  order: DeploymentOrder;
}

// A SECOND, additional v4 pool bound to the same Strategy A order and oracle as `v4` above, but
// initialized with LPFeeLibrary.DYNAMIC_FEE_FLAG -- a risk-adjusted swap fee on top of the same
// exposure reading that drives the SwapVM-side gate. See src/hooks/AquaV4Hook.sol (_applyFee,
// _riskFeePips, refreshFee) and script/AqueductV3DynamicFee.s.sol.
export interface DynamicFeePool {
  label: string;
  hook: string;
  poolId: string;
  poolKey: PoolKeyJson;
  minFeePips: number;
  maxFeePips: number;
  feeSaturationBps: number;
  note?: string;
}

export interface Deployment {
  chainId: number;
  maker: string;
  keeper: string;
  aqua: string;
  oracle: string;
  swapVM: string;
  tokenIn: string;
  tokenOut: string;
  strategyHash: string;
  maxExposureBps: number;
  haltExposureBps: number;
  order: DeploymentOrder;
  v4?: V4Deployment;
  // Every Aqua strategy this maker has actually shipped and labeled for the dashboard -- NOT a
  // fixed "A/B/C" schema. Absent (or a single entry) on deployments that have only ever shipped
  // one strategy; AggregateExposurePanel renders however many real entries exist and shows the
  // rest as explicitly unshipped, rather than inventing data to match a fixed slot count.
  strategies?: NamedStrategy[];
  sophisticatedPosition?: SophisticatedPosition;
  dynamicFeePool?: DynamicFeePool;
}

export async function loadDeployment(): Promise<Deployment> {
  const res = await fetch("/deployment.json", { cache: "no-store" });
  if (!res.ok) {
    throw new Error(
      "Could not load deployment.json. Run the Foundry demo scripts first: " +
        "see the README for `forge script script/AqueductDemo.s.sol ...` and " +
        "`forge script script/AqueductV4Demo.s.sol ...`."
    );
  }
  return (await res.json()) as Deployment;
}
