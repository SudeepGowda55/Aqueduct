import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import { Shipped, Pushed, Pulled, Docked } from "../generated/Aqua/Aqua";
import { Strategy, StrategyBalance, AquaBalanceEvent } from "../generated/schema";

function strategyId(maker: Bytes, app: Bytes, strategyHash: Bytes): string {
  return maker.toHex() + "-" + app.toHex() + "-" + strategyHash.toHex();
}

function balanceId(maker: Bytes, app: Bytes, strategyHash: Bytes, token: Bytes): string {
  return strategyId(maker, app, strategyHash) + "-" + token.toHex();
}

function loadOrCreateStrategy(
  maker: Bytes,
  app: Bytes,
  strategyHash: Bytes,
  blockNumber: BigInt,
  blockTimestamp: BigInt
): Strategy {
  const id = strategyId(maker, app, strategyHash);
  let strategy = Strategy.load(id);
  if (strategy == null) {
    strategy = new Strategy(id);
    strategy.maker = maker;
    strategy.app = app;
    strategy.strategyHash = strategyHash;
    strategy.tokens = [];
    strategy.active = true;
    strategy.shippedAtBlock = blockNumber;
    strategy.shippedAtTimestamp = blockTimestamp;
  }
  return strategy as Strategy;
}

function loadOrCreateBalance(
  maker: Bytes,
  app: Bytes,
  strategyHash: Bytes,
  token: Bytes,
  blockNumber: BigInt,
  blockTimestamp: BigInt
): StrategyBalance {
  const id = balanceId(maker, app, strategyHash, token);
  let balance = StrategyBalance.load(id);
  if (balance == null) {
    balance = new StrategyBalance(id);
    balance.maker = maker;
    balance.app = app;
    balance.strategyHash = strategyHash;
    balance.token = token;
    balance.amount = BigInt.zero();
    balance.active = true;
    balance.updatedAtBlock = blockNumber;
    balance.updatedAtTimestamp = blockTimestamp;
  }
  return balance as StrategyBalance;
}

// `Shipped` fires once per new strategy, before the per-token `Pushed` events for its initial
// balances. It carries no token list itself (that arrived as a separate `ship()` argument, not
// re-emitted), so this handler only records that the strategy now exists; `handlePushed` is what
// actually creates each StrategyBalance and appends to `Strategy.tokens`.
export function handleShipped(event: Shipped): void {
  const strategy = loadOrCreateStrategy(
    event.params.maker,
    event.params.app,
    event.params.strategyHash,
    event.block.number,
    event.block.timestamp
  );
  strategy.active = true;
  strategy.save();

  const log = new AquaBalanceEvent(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  log.kind = "Shipped";
  log.maker = event.params.maker;
  log.app = event.params.app;
  log.strategyHash = event.params.strategyHash;
  log.token = null;
  log.amount = null;
  log.blockNumber = event.block.number;
  log.blockTimestamp = event.block.timestamp;
  log.transactionHash = event.transaction.hash;
  log.save();
}

// Fires both for a strategy's initial balances (during `ship()`) and for any later top-up
// (a standalone, permissionless `push()`) -- `Aqua.push` always adds, so a plain load-or-create
// plus increment handles both cases identically.
export function handlePushed(event: Pushed): void {
  const strategy = loadOrCreateStrategy(
    event.params.maker,
    event.params.app,
    event.params.strategyHash,
    event.block.number,
    event.block.timestamp
  );
  const tokens = strategy.tokens;
  let known = false;
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].equals(event.params.token)) {
      known = true;
      break;
    }
  }
  if (!known) {
    tokens.push(event.params.token);
    strategy.tokens = tokens;
  }
  strategy.active = true;
  strategy.save();

  const balance = loadOrCreateBalance(
    event.params.maker,
    event.params.app,
    event.params.strategyHash,
    event.params.token,
    event.block.number,
    event.block.timestamp
  );
  balance.amount = balance.amount.plus(event.params.amount);
  balance.active = true;
  balance.updatedAtBlock = event.block.number;
  balance.updatedAtTimestamp = event.block.timestamp;
  balance.save();

  const log = new AquaBalanceEvent(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  log.kind = "Pushed";
  log.maker = event.params.maker;
  log.app = event.params.app;
  log.strategyHash = event.params.strategyHash;
  log.token = event.params.token;
  log.amount = event.params.amount;
  log.blockNumber = event.block.number;
  log.blockTimestamp = event.block.timestamp;
  log.transactionHash = event.transaction.hash;
  log.save();
}

// `Aqua.pull` is only ever callable by the exact `app` a strategy was shipped to (see Aqua.sol's
// `_balances[maker][msg.sender][...]` keying), so every draw-down against a maker's committed
// liquidity -- including one gated by ExposureGate -- shows up here.
export function handlePulled(event: Pulled): void {
  const balance = loadOrCreateBalance(
    event.params.maker,
    event.params.app,
    event.params.strategyHash,
    event.params.token,
    event.block.number,
    event.block.timestamp
  );
  balance.amount = balance.amount.minus(event.params.amount);
  balance.updatedAtBlock = event.block.number;
  balance.updatedAtTimestamp = event.block.timestamp;
  balance.save();

  const log = new AquaBalanceEvent(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  log.kind = "Pulled";
  log.maker = event.params.maker;
  log.app = event.params.app;
  log.strategyHash = event.params.strategyHash;
  log.token = event.params.token;
  log.amount = event.params.amount;
  log.blockNumber = event.block.number;
  log.blockTimestamp = event.block.timestamp;
  log.transactionHash = event.transaction.hash;
  log.save();
}

// `Aqua.dock` closes every token in a strategy in one call but only emits (maker, app,
// strategyHash) -- no token list -- so this handler consults the `Strategy.tokens` list built up
// by `handlePushed` to flip every one of that strategy's balances inactive.
export function handleDocked(event: Docked): void {
  const id = strategyId(event.params.maker, event.params.app, event.params.strategyHash);
  const strategy = Strategy.load(id);
  if (strategy != null) {
    strategy.active = false;
    strategy.save();

    const tokens = strategy.tokens;
    for (let i = 0; i < tokens.length; i++) {
      const balance = StrategyBalance.load(balanceId(event.params.maker, event.params.app, event.params.strategyHash, tokens[i]));
      if (balance != null) {
        balance.active = false;
        balance.updatedAtBlock = event.block.number;
        balance.updatedAtTimestamp = event.block.timestamp;
        balance.save();
      }
    }
  }

  const log = new AquaBalanceEvent(event.transaction.hash.toHex() + "-" + event.logIndex.toString());
  log.kind = "Docked";
  log.maker = event.params.maker;
  log.app = event.params.app;
  log.strategyHash = event.params.strategyHash;
  log.token = null;
  log.amount = null;
  log.blockNumber = event.block.number;
  log.blockTimestamp = event.block.timestamp;
  log.transactionHash = event.transaction.hash;
  log.save();
}
