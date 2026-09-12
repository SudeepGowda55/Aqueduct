import { BigInt, Bytes, Address } from "@graphprotocol/graph-ts";
import { Shipped, Pushed, Pulled, Docked } from "../generated/Aqua/Aqua";
import { ExposureUpdated, MakerPauseUpdated } from "../generated/ExposureOracle/ExposureOracle";
import { Swap } from "../generated/PoolManager/PoolManager";
import { ERC20 } from "../generated/Aqua/ERC20";
import { ExposureOracle } from "../generated/ExposureOracle/ExposureOracle";
import { Strategy, StrategyBalance, AquaBalanceEvent, Maker, ExposurePosition, ExposureSnapshot } from "../generated/schema";

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

  touchFromAqua(event.params.maker, event.params.app, event.params.strategyHash, event.block.timestamp);
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

  touchFromAqua(event.params.maker, event.params.app, event.params.strategyHash, event.block.timestamp);
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

  touchFromAqua(event.params.maker, event.params.app, event.params.strategyHash, event.block.timestamp);
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

  touchFromAqua(event.params.maker, event.params.app, event.params.strategyHash, event.block.timestamp);
}

// ---------------------------------------------------------------------------
// ExposurePosition join (Aqua x ExposureOracle x PoolManager).
//
// ONE position per (maker, strategyHash). Aqua events feed committed amounts
// (+ wallet balance via eth_call); ExposureOracle events feed exposure % and
// pause state; PoolManager swaps confirm the uniswap-v4 venue. Thresholds are
// hardcoded (every live strategy uses 50% / 90% -- decoding them out of raw
// program bytes isn't worth it); the single-maker MAKER constant below exists
// only because a bare PoolManager Swap event carries no maker -- every live
// strategy belongs to this maker (see deployment.json).
// ---------------------------------------------------------------------------

let ORACLE_ADDRESS = Address.fromString("0xe68530d8e694ec6d237f0b07ec24c405c8cd764a");
let TOKEN_IN = Address.fromString("0x2a22b21b15d6305abcbe78ff3098aed2f5b54869");
let MAKER = Address.fromString("0x5067591c365d7d69d76b725c2d9af7b9437132be");

let MAX_EXPOSURE_BPS = BigInt.fromI32(5000);
let HALT_EXPOSURE_BPS = BigInt.fromI32(9000);

// Uniswap v4 poolId (keccak256 of the pool key) -> strategyHash it is bound
// to. Pool 1 (hook 0xE115..) <-> Strategy A; pool 2 (hook 0x7aec..) <->
// Strategy F (proven: pool-2 swaps pull from 0xeb6c.. on-chain).
function strategyForPool(poolIdHex: string): string | null {
  if (poolIdHex == "0xeadf84808fa273e1837ebbfa022259d7e687c42f23fbea74bac849532b8ff8f8") {
    return "0x828353ec4866ca0f45f4bf5420875cba5a8d4afc8289eb98952016effab195e2";
  }
  if (poolIdHex == "0xafc0c968366c3ee3a813d16d5ca0960a5dc53e908dd316d011d8c1d7b6951359") {
    return "0xeb6cd6ba1b79355b923d569650736df8070377d7276b3fc086cafb0eac560777";
  }
  return null;
}

// Strategies with a bound v4 hook get both venues from birth; the Swap
// handler re-asserts it (belt and braces) and refreshes updatedAt.
function hasV4Venue(strategyHashHex: string): boolean {
  return (
    strategyHashHex == "0x828353ec4866ca0f45f4bf5420875cba5a8d4afc8289eb98952016effab195e2" ||
    strategyHashHex == "0xeb6cd6ba1b79355b923d569650736df8070377d7276b3fc086cafb0eac560777"
  );
}

function positionId(maker: Bytes, strategyHash: Bytes): Bytes {
  return Bytes.fromHexString(maker.toHexString() + strategyHash.toHexString().slice(2));
}

function statusFor(exposure: BigInt, paused: boolean): string {
  if (paused) return "PAUSED";
  if (exposure.ge(HALT_EXPOSURE_BPS)) return "HALTED";
  if (exposure.gt(MAX_EXPOSURE_BPS)) return "DERATED";
  return "SAFE";
}

// Creates Maker + ExposurePosition rows if missing; registers app. Backfills
// exposure/pause from the oracle via eth_call so positions created late (e.g.
// from a Swap before any oracle event replays) still converge.
function ensurePosition(maker: Bytes, app: Bytes | null, strategyHash: Bytes, blockTimestamp: BigInt): ExposurePosition {
  let makerRow = Maker.load(maker);
  if (makerRow == null) {
    makerRow = new Maker(maker);
    makerRow.positionIds = [];
  }

  const id = positionId(maker, strategyHash);
  let pos = ExposurePosition.load(id);
  if (pos == null) {
    pos = new ExposurePosition(id);
    pos.maker = maker;
    pos.strategyHash = strategyHash;
    const venues = new Array<string>(0);
    venues.push("swapvm");
    if (hasV4Venue(strategyHash.toHexString())) venues.push("uniswap-v4");
    pos.venues = venues;
    pos.committedAmount = BigInt.zero();
    pos.makerWalletBalance = BigInt.zero();
    pos.exposureBps = BigInt.zero();
    pos.maxExposureBps = MAX_EXPOSURE_BPS;
    pos.haltExposureBps = HALT_EXPOSURE_BPS;
    pos.status = "SAFE";
    pos.isPausedByMaker = false;
    pos.updatedAt = blockTimestamp;
    pos.apps = new Array<Bytes>(0);

    const oracle = ExposureOracle.bind(ORACLE_ADDRESS);
    const makerAddr = Address.fromBytes(maker);
    const expCall = oracle.try_exposureOf(makerAddr);
    if (!expCall.reverted) {
      pos.exposureBps = expCall.value.value0;
      pos.status = statusFor(pos.exposureBps, pos.isPausedByMaker);
    }
    const pauseCall = oracle.try_isPausedByMaker(makerAddr);
    if (!pauseCall.reverted) {
      pos.isPausedByMaker = pauseCall.value;
      pos.status = statusFor(pos.exposureBps, pos.isPausedByMaker);
    }

    const ids = makerRow.positionIds;
    ids.push(id.toHexString());
    makerRow.positionIds = ids;
    makerRow.save();
  }

  if (app) {
    const apps = pos.apps;
    let known = false;
    for (let i = 0; i < apps.length; i++) {
      if (apps[i].equals(app)) {
        known = true;
        break;
      }
    }
    if (!known) {
      apps.push(app);
      pos.apps = apps;
    }
  }
  return pos as ExposurePosition;
}

// Re-sums committed tokenIn across every app of this (maker, strategyHash)
// from live StrategyBalance rows. Only ACTIVE balances count (Docked flips
// them off in the base handlers above).
function recomputeCommitted(pos: ExposurePosition): void {
  let total = BigInt.zero();
  const apps = pos.apps;
  for (let i = 0; i < apps.length; i++) {
    const sid = strategyId(pos.maker, apps[i], pos.strategyHash);
    const strat = Strategy.load(sid);
    if (strat == null) continue;
    const tokens = strat.tokens;
    for (let j = 0; j < tokens.length; j++) {
      if (!tokens[j].equals(TOKEN_IN)) continue;
      const bal = StrategyBalance.load(sid + "-" + tokens[j].toHexString());
      if (bal != null && bal.active) total = total.plus(bal.amount);
    }
  }
  pos.committedAmount = total;
}

// Wallet balance is NOT an event -- live balanceOf() eth_call on every
// Aqua-side touch. Reverted calls keep the previous value.
function refreshWallet(pos: ExposurePosition): void {
  const token = ERC20.bind(TOKEN_IN);
  const call = token.try_balanceOf(Address.fromBytes(pos.maker));
  if (!call.reverted) pos.makerWalletBalance = call.value;
}

function writeSnapshot(pos: ExposurePosition, blockNumber: BigInt, blockTimestamp: BigInt, txHash: Bytes, logIndex: BigInt): void {
  const idHex = pos.id.toHexString();
  const snap = new ExposureSnapshot(
    txHash.toHexString() + "-" + logIndex.toString() + "-" + idHex.slice(idHex.length - 8, idHex.length)
  );
  snap.maker = pos.maker;
  snap.strategyHash = pos.strategyHash;
  snap.exposureBps = pos.exposureBps;
  snap.status = pos.status;
  snap.blockNumber = blockNumber;
  snap.blockTimestamp = blockTimestamp;
  snap.save();
}

// Called at the end of every Aqua handler (after the base StrategyBalance
// bookkeeping above has saved).
function touchFromAqua(maker: Bytes, app: Bytes, strategyHash: Bytes, blockTimestamp: BigInt): void {
  const pos = ensurePosition(maker, app, strategyHash, blockTimestamp);
  recomputeCommitted(pos);
  refreshWallet(pos);
  pos.status = statusFor(pos.exposureBps, pos.isPausedByMaker);
  pos.updatedAt = blockTimestamp;
  pos.save();
}

// Fan-out for maker-level oracle events: updates EVERY position of the maker
// (via Maker.positionIds) and writes one snapshot per position.
function touchFromOracle(
  maker: Bytes,
  exposure: BigInt | null,
  paused: boolean,
  hasPaused: boolean,
  blockNumber: BigInt,
  blockTimestamp: BigInt,
  txHash: Bytes,
  logIndex: BigInt
): void {
  const makerRow = Maker.load(maker);
  if (makerRow == null) return;
  const ids = (makerRow as Maker).positionIds;
  for (let i = 0; i < ids.length; i++) {
    const pos = ExposurePosition.load(Bytes.fromHexString(ids[i]));
    if (pos == null) continue;
    const p = pos as ExposurePosition;
    if (exposure) p.exposureBps = exposure;
    if (hasPaused) p.isPausedByMaker = paused;
    p.status = statusFor(p.exposureBps, p.isPausedByMaker);
    p.updatedAt = blockTimestamp;
    p.save();
    writeSnapshot(p, blockNumber, blockTimestamp, txHash, logIndex);
  }
}

export function handleExposureUpdated(event: ExposureUpdated): void {
  touchFromOracle(
    event.params.maker,
    event.params.exposureBps,
    false,
    false,
    event.block.number,
    event.block.timestamp,
    event.transaction.hash,
    event.logIndex
  );
}

export function handleMakerPauseUpdated(event: MakerPauseUpdated): void {
  touchFromOracle(
    event.params.maker,
    null,
    event.params.paused,
    true,
    event.block.number,
    event.block.timestamp,
    event.transaction.hash,
    event.logIndex
  );
}

// A swap on a whitelisted v4 pool re-asserts the uniswap-v4 venue on the bound
// position. Pool -> strategy mapping is hardcoded (no factory/discovery
// events exist); unknown pools are ignored. Maker is the deployment's single
// maker -- bare Swap events carry no maker field.
export function handlePoolSwap(event: Swap): void {
  const hashHex = strategyForPool(event.params.id.toHexString());
  if (hashHex) {
    const pos = ensurePosition(MAKER, null, Bytes.fromHexString(hashHex), event.block.timestamp);
    const venues = pos.venues;
    let has = false;
    for (let i = 0; i < venues.length; i++) {
      if (venues[i] == "uniswap-v4") {
        has = true;
        break;
      }
    }
    if (!has) {
      venues.push("uniswap-v4");
      pos.venues = venues;
    }
    pos.updatedAt = event.block.timestamp;
    pos.save();
  }
}
