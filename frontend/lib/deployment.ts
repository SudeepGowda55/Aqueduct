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
