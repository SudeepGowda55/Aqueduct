# Uniswap v4 developer feedback — Aqueduct

Real friction points hit while building `AquaV4Hook` (a hook that sources every swap from an
external liquidity source — a 1inch Aqua maker strategy — rather than the pool's own curve), and
what we did about each one. Not a wishlist; every item below is something that cost real debugging
time before we understood it.

## 1. The flash-accounting settlement order isn't obvious from the docs, and it's the single
   biggest blocker for "hand back real external liquidity synchronously" hooks

A swapper's input payment isn't credited to `PoolManager`'s real reserves until *after*
`PoolManager.swap()` returns to the top-level router (concretely: `PoolSwapTest.unlockCallback`
only calls `settle()` once `manager.swap()` has already returned). That means inside `beforeSwap`,
a real (non-claim) `take()` of the swapper's own input **always reverts** — the manager simply
isn't holding it yet.

This is *correct* and *necessary* for how flash accounting works, but it's genuinely easy to hit
by surprise: the natural first instinct for "fill this swap from an external venue" is to `take()`
the input, forward it to the venue, and settle the output — and that fails in a way that doesn't
obviously point at "settlement ordering" from the revert alone (it just reverts on the venue's own
`transferFrom`, since the hook never actually received real tokens).

**What we did:** a working-capital float — mint the hook ERC-6909 *claims* for the specified
amount (legal, since claims are accounting entries, not a real balance check), fund the external
leg from the hook's own pre-seeded token balance instead of the swapper's not-yet-arrived payment,
settle the real output to the manager, and later burn accumulated claims back into real tokens via
a permissionless `sweepClaims()` once the pool's real reserves (from *past* swappers' settled
payments) can cover it.

**Suggestion:** a short, explicit note in the `beforeSwap`/flash-accounting docs along the lines of
"if your hook needs to synchronously fund an external leg during `beforeSwap`, you cannot use the
swapper's own payment — fund it from your own balance and reconcile via claims after" would have
saved real time. `BaseAsyncSwap` in `openzeppelin/uniswap-hooks` is close, but it solves a
different problem (fully deferred settlement, no output in the same transaction) — there's no
reference pattern in that library for "fill synchronously anyway."

## 2. We built the reference pattern the above was missing, in case it's useful upstream

Since no existing base covered "synchronous fill from external liquidity," we extracted the
pattern above into a small, dependency-free base contract:
[`src/hooks/AsyncLiquidityHook.sol`](src/hooks/AsyncLiquidityHook.sol). It implements the full
claims-mint → fund → settle → sweep sequence and the standard "hook is the pool's sole liquidity
source" permission set, and asks integrators to implement exactly one method:
`_fillFromExternalLiquidity`.

We proved it's genuinely generic, not shaped around our own integration, with two independent
implementations against a real `PoolManager`:
- [`src/hooks/AquaV4Hook.sol`](src/hooks/AquaV4Hook.sol) — sources fills from a 1inch Aqua maker
  strategy through SwapVM (our actual project).
- [`test/mocks/FixedRateAsyncHook.sol`](test/mocks/FixedRateAsyncHook.sol) — a deliberately trivial
  fixed-rate implementation sharing zero code or state with the first, used purely to prove the
  base isn't secretly Aqua-specific ([`test/AsyncLiquidityHook.t.sol`](test/AsyncLiquidityHook.t.sol)).

If this pattern is useful as an official reference or an addition to `uniswap-hooks`, happy to
upstream it.

## 3. `HookMiner`'s deployer argument is easy to get subtly wrong between tests and scripts

`HookMiner.find(deployer, flags, creationCode, constructorArgs)` needs the deployer that will
*actually* perform the CREATE2 deployment, and that differs by context: inside a Foundry test,
that's `address(this)` (the test contract deploying directly); inside a broadcast `forge script`,
`forge` routes salted `new` expressions through the canonical CREATE2 deployer proxy
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`), not the broadcasting EOA. Passing the wrong one
silently mines a salt for an address that never actually gets used, and the subsequent
`assertEq(address(hook), hookAddress)` sanity check is what actually catches it — it would be easy
to skip that check and end up genuinely confused about why permission flags aren't being read
correctly from the deployed address. Worth calling out explicitly in `HookMiner`'s own docs, since
it's a one-line fix once known and a real time sink before that.

## 4. The per-swap fee override (`OVERRIDE_FEE_FLAG`) and the persisted `lpFee` are two genuinely
   separate mechanisms, and conflating them cost us a real (caught) bug

Once we had a working hook, we added a second, independent capability: a swap fee that scales with
a maker's live risk reading (`src/hooks/AquaV4Hook.sol`'s `_applyFee`/`_riskFeePips`), mirroring
`uniswap-hooks`'s own `BaseOverrideFee` (return `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG` from
`beforeSwap`) and `BaseDynamicFee` (`_poke`-style `updateDynamicLPFee`) patterns. It is easy to
assume these two are the same fee living in one place; they are not. The per-swap override prices
*that one swap* and does not write through to the pool's persisted `slot0.lpFee` -- only an
explicit `updateDynamicLPFee` call does that. We initially wrote a verification script that called
our `refreshFee()` (which wraps `updateDynamicLPFee`) *without* `vm.startBroadcast()`, so the
call executed only in the script's local simulation; the script's own `require` checked persisted
`lpFee` against local state and passed, while nothing was ever actually sent on-chain. It was only
caught by independently reading the real pool's storage via `extsload` after the broadcast and
finding `lpFee == 0` -- the exact "verify the real outcome, not your own tool's report of it"
lesson from the maker-pause bug in our main README, recurring in a different shape. Worth an
explicit callout in the dynamic-fee guides: the override flag and `updateDynamicLPFee` solve
different problems (per-swap pricing vs. persisted, externally-queryable pool state), and using one
does not imply the other has happened.

## 5. What worked well, for balance

`beforeSwapReturnDelta` + `toBeforeSwapDelta` for fully overriding a swap's pricing is clean and
well-documented once you know to look for it (the `Hooks.sol` permission-flag encoding into the
hook's own address, via `HookMiner`, is a genuinely elegant piece of design). `CurrencySettler` in
`openzeppelin/uniswap-hooks` made the settle/take bookkeeping much less error-prone than writing it
by hand. The `CustomRevert.WrappedError` pattern for propagating hook reverts with full context
made test-writing straightforward once we found it, though it's not obviously discoverable from
the hook side alone.

---

Repo: this is the same repository as the main submission. Contract-level pointers for judges:
- `src/hooks/AsyncLiquidityHook.sol` — the reusable base (the actual contribution this feedback
  is about).
- `src/hooks/AquaV4Hook.sol` — the real implementation, live on Base Sepolia, including the
  risk-adjusted dynamic-fee capability (`_applyFee`, `_riskFeePips`, `refreshFee`) discussed above.
- `test/AsyncLiquidityHook.t.sol`, `test/AquaV4Hook.t.sol` — both implementations proven against
  a real `PoolManager`.
- `test/DynamicFeeHook.t.sol` — the dynamic-fee capability, including the explicit proof that a
  static-fee pool bound to the same hook code is completely unaffected.
- `script/AqueductV3DynamicFee.s.sol` — the real Base Sepolia deployment of the dynamic-fee pool,
  including the fixed version of the broadcast bug described in item 4 above.
