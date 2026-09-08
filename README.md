# Aqueduct — Exposure-Gated Aqua Liquidity

Built for ETHGlobal's **1inch: Build an Aqua App** track.

Aqueduct adds a new SwapVM instruction, `_exposureGate1D`, that derates or halts a maker's fill
based on their *live cross-protocol exposure* — read from an on-chain oracle fed by an off-chain
data pipeline (in the full Aqueduct project, The Graph: Substreams + Messari-standardized
subgraphs aggregating the maker's positions across every venue they've shipped Aqua liquidity to).

The opcode is **monotonic by construction**: it can only shrink a taker's fill, or halt it
entirely via revert. There is no code path in which it can enlarge a fill beyond what the
preceding swap-computing instruction already produced. That means a stale, wrong, or even
maliciously-signed oracle reading can only ever make a maker quote *more conservatively* than its
unsigned SwapVM program already authorized — never trade beyond it. This is the direct structural
mirror of SwapVM's own `OraclePriceAdjuster` instruction, which is one-directional in the opposite
sense (only ever improves the taker's price, never worsens it).

## Where to look

| What | File |
|---|---|
| The opcode itself, with the monotonicity argument spelled out | [`src/opcodes/ExposureGate.sol`](src/opcodes/ExposureGate.sol) |
| The on-chain oracle the opcode reads | [`src/oracle/ExposureOracle.sol`](src/oracle/ExposureOracle.sol) / [`IExposureOracle.sol`](src/oracle/IExposureOracle.sol) |
| Stock `AquaOpcodes` + the new instruction appended at the end (index 35), every existing index preserved | [`src/opcodes/ExposureAquaOpcodes.sol`](src/opcodes/ExposureAquaOpcodes.sol) |
| The deployable router wiring it together | [`src/routers/ExposureAwareAquaRouter.sol`](src/routers/ExposureAwareAquaRouter.sol) |
| Proof of the safety claim: 8 tests incl. two 257-run fuzz properties | [`test/ExposureGate.t.sol`](test/ExposureGate.t.sol) |
| End-to-end demo as real broadcast transactions on a local chain | [`script/AqueductDemo.s.sol`](script/AqueductDemo.s.sol) |

`lib/swap-vm` and `lib/aqua` are the real, unmodified 1inch repositories, pulled in as git
submodules — not reimplemented or mocked.

## Why a local chain, not a mainnet fork

1inch's own repos ship no real mainnet or testnet Aqua/SwapVM deployment addresses — see
[`lib/aqua/config/constants.json`](lib/aqua/config/constants.json) and
[`lib/swap-vm/config/constants.json`](lib/swap-vm/config/constants.json), both zero-address
placeholders for local anvil (chain id `31337`). The track's own rules anticipate this directly:
*"Official Aqua/SwapVM contracts must be used (redeployments of a modified SwapVM contract is
allowed)"* and *"local forks are ok."* So the demo deploys fresh, unmodified-Aqua +
modified-SwapVM instances onto a local anvil node and drives them with real signed transactions —
there is no live deployment to fork against.

## Run the tests

```shell
forge install   # pulls in swap-vm and aqua as submodules
forge test -vv
```

8 tests, all passing:
- pass-through below the exposure threshold (exact equality with an ungated baseline)
- exact derate math at the midpoint between max and halt, both exact-in and exact-out
- hard revert at and above the halt threshold
- stale-oracle revert
- **two 257-run property tests**: across the full exposure/amount input space, a gated exact-in
  fill never exceeds the ungated baseline's output, and a gated exact-out fill never requires
  less input than the baseline. This is what actually proves the monotonicity claim above, not
  just the example cases.

## Run the on-chain demo

```shell
anvil                                                    # terminal 1
forge script script/AqueductDemo.s.sol \                 # terminal 2
  --rpc-url http://127.0.0.1:8545 \
  --private-key <any funded anvil account, e.g. account (0) from anvil's own startup log> \
  --broadcast -vvvv
```

This deploys real contracts and ships real maker liquidity into Aqua as genuine, mined
transactions (not `forge test` pranks — verifiable independently with `cast receipt` against the
tx hashes forge writes to `broadcast/AqueductDemo.s.sol/31337/run-latest.json`), then runs three
scenarios as the maker's reported exposure climbs:

1. **10% exposure** (below the 50% max) → normal AMM fill, gate is a no-op
2. **70% exposure** (between 50% max and 90% halt) → derated fill: same `amountIn`, strictly less
   `amountOut` than scenario 1's pool-implied price — the taker gets worse execution, never better
3. **90% exposure** (at the halt threshold) → the swap reverts outright with
   `ExposureGateExceedsHaltThreshold`, no fill at all

Scenario 3 is deliberately run as a plain call against the live chain state rather than a
broadcast transaction — forge's broadcast pre-flight replays the whole batch before sending
anything and aborts the *entire* run the moment one call is predicted to revert, which would have
silently prevented scenarios 1 and 2 from ever being sent for real. The revert is exactly as real
either way: it executes against the actual deployed contracts and actual on-chain state from the
prior broadcast transactions.

## The idea behind it (full project context)

Aqueduct is one piece of a larger project: 1inch Aqua's whole premise is that the same wallet
balance can back multiple strategies across multiple venues at once (the "multiplier effect").
Nothing on-chain today knows a maker's *true* uncommitted exposure across all of those venues
simultaneously. `_exposureGate1D` is the missing primitive that lets a maker's own SwapVM program
price that risk in — fed by a live, standardized, cross-protocol view of their positions.
