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
