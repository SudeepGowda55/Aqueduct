// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import { BaseHook } from "uniswap-hooks/src/base/BaseHook.sol";
import { CurrencySettler } from "uniswap-hooks/src/utils/CurrencySettler.sol";

/**
 * @title AsyncLiquidityHook
 * @notice Reusable Uniswap v4 base hook for pools whose swaps are filled **synchronously** from
 *         liquidity that lives entirely **outside** the pool -- an RFQ desk, a shared-liquidity
 *         layer, a lending market, a market maker's own inventory, anything reachable by an
 *         onchain call. Inherit it and implement one method: {_fillFromExternalLiquidity}.
 *
 * @dev WHY THIS EXISTS -- the v4 problem it solves.
 *
 *      A hook that wants to hand the swapper real, externally-sourced output *within the same
 *      swap* runs into a hard ordering constraint in `PoolManager`'s flash accounting: the
 *      swapper's input payment is not credited to the manager's real reserves until *after*
 *      `PoolManager.swap()` returns to the top-level router and that router settles its deltas
 *      (see `PoolSwapTest.unlockCallback`, which calls `settle` only once `manager.swap()` has
 *      already returned). Inside `beforeSwap`, therefore:
 *
 *        - `take(..., claims: false)` of the swapper's input **reverts** -- the manager is not
 *          holding those tokens yet, and won't be until this call stack unwinds.
 *        - But the external venue you want to trade against needs *real* tokens *now*, because it
 *          will `transferFrom` or otherwise settle synchronously during your call into it.
 *
 *      OpenZeppelin's `BaseAsyncSwap` sidesteps this by deferring the fill entirely (the swapper
 *      gets nothing back in the same transaction). That is the right answer for genuinely async
 *      settlement, but not for a hook that wants to quote-and-fill atomically.
 *
 *      THE PATTERN THIS BASE IMPLEMENTS -- a working-capital float:
 *
 *        1. `take(..., claims: true)` mints this hook ERC-6909 claim tokens for the specified
 *           amount, closing out the credit the returned `BeforeSwapDelta` declares. Claims are
 *           accounting entries, not transferable tokens -- minting them does not require the
 *           manager to be holding anything yet, so this is legal here where a real take is not.
 *        2. The implementation funds the external trade from the hook's own pre-seeded balance of
 *           the input currency (its "float"), NOT from the swapper's not-yet-arrived payment.
 *        3. The externally-sourced output is settled to the manager on the swapper's behalf.
 *        4. The returned delta nets the specified amount to zero (so the core v3-style curve math
 *           never runs -- the pool needs no liquidity of its own) and credits the swapper the
 *           unspecified amount.
 *        5. Later, {sweepClaims} burns accumulated claims back into real tokens, replenishing the
 *           float from the real reserves that past swappers' settled payments have accumulated.
 *
 *      The float is therefore *working capital, not collateral*: every claim minted in step 1 is
 *      backed by the swapper's payment landing in the very same transaction, so the hook's claim
 *      balance and its real-token deficit always move together.
 *
 *      SEEDING AND OPERATING NOTES (deliberately kept out of the base, so integrators choose):
 *        - Seed the float by plainly transferring the relevant currencies to the hook address.
 *          No bespoke deposit function is imposed here.
 *        - {sweepClaims} is permissionless maintenance, not a security boundary: it reverts
 *          harmlessly if the manager's real reserves can't cover the requested amount yet.
 *        - Float sizing is an economic decision for the integrator: it bounds the largest single
 *          swap this hook can fill between sweeps.
 *
 *      SCOPE: one pool per hook instance (bound on first initialize, mirroring the single-pool
 *      binding used by OpenZeppelin's `ReHypothecationHook`), exact-input swaps only -- exact
 *      output has no pool liquidity to fall back on and is rejected outright rather than
 *      partially handled.
 *
 *      Reference implementations in this repository:
 *        - `AquaV4Hook` -- sources fills from a 1inch Aqua maker strategy executed through SwapVM.
 *        - `test/mocks/FixedRateAsyncHook.sol` -- a deliberately trivial, non-Aqua implementation
 *          used to prove this base is genuinely generic and not shaped around one integration.
 */
abstract contract AsyncLiquidityHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /// @dev Thrown when an exact-output swap is attempted; only exact-input is supported.
    error ExactOutputNotSupported();
    /// @dev Thrown when a third party attempts to add or remove liquidity directly on the pool.
    error LiquidityNotAllowed();
    /// @dev Thrown when the hook has already been bound to a pool.
    error AlreadyBound();
    /// @dev Thrown when a swap is attempted before the pool has been initialized.
    error NotBound();

    /// @dev The single pool this hook is bound to, set once at `_beforeInitialize`.
    PoolKey internal _poolKey;
    bool internal _bound;

    constructor(IPoolManager poolManager_) BaseHook(poolManager_) { }

    /// @notice Returns the pool key this hook is bound to.
    function getPoolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /**
     * @notice Source `specifiedAmount` of `specified` currency into `unspecified` currency from
     *         whatever external venue this hook is built around, and return how much
     *         `unspecified` was obtained.
     * @dev Implementations MUST end holding at least `amountOut` of `unspecified` as real tokens
     *      (the base settles that amount to the `PoolManager` immediately after this returns), and
     *      MAY spend up to `specifiedAmount` of the hook's real `specified` float to do so. The
     *      base has already minted itself claims for `specifiedAmount` before calling this, so the
     *      hook's *net* position is flat once the swapper's payment settles.
     *
     *      Reverting here reverts the entire Uniswap swap, which is the intended way to propagate
     *      an external venue's own refusal (a risk check, a stale quote, insufficient inventory)
     *      up to the swapper, rather than silently filling less.
     */
    function _fillFromExternalLiquidity(Currency specified, Currency unspecified, uint256 specifiedAmount)
        internal
        virtual
        returns (uint256 amountOut);

    /**
     * @notice Hook for integrators who want a swap fee on top of the async fill -- e.g. one that
     *         tracks live risk data the same way {_fillFromExternalLiquidity} sources liquidity.
     * @dev Called after the external fill, before settlement, so it can reduce `amountOut` in
     *      place (the difference simply stays in this hook's own float, exactly like an AMM's LP
     *      fee accrues to the LP by not being paid out). May also return a per-swap fee, OR'd with
     *      `LPFeeLibrary.OVERRIDE_FEE_FLAG`, so the pool's `Swap` event and any indexer reflect the
     *      real fee used -- the same mechanism OpenZeppelin's `BaseOverrideFee` uses, adapted here
     *      because this base already returns its own `BeforeSwapDelta`. Default: no fee, no
     *      override -- inert for integrators who don't need one (see `FixedRateAsyncHook`).
     */
    function _applyFee(PoolKey calldata, uint256 amountOut) internal virtual returns (uint256, uint24) {
        return (amountOut, 0);
    }

    /**
     * @dev Binds the hook to the first pool key it sees. Pool initialization is permissionless in
     * v4, so trigger this atomically with the hook's own deployment (single script or multicall)
     * to avoid being front-run onto an unintended pool key.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (_bound) revert AlreadyBound();
        _poolKey = key;
        _bound = true;
        return this.beforeInitialize.selector;
    }

    /// @dev The hook is the pool's sole source of liquidity; third-party LPing is disabled.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev See {_beforeAddLiquidity}.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev The float-funded fill sequence described in this contract's own doc comment.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_bound) revert NotBound();
        require(params.amountSpecified < 0, ExactOutputNotSupported());

        Currency specified = params.zeroForOne ? key.currency0 : key.currency1;
        Currency unspecified = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 specifiedAmount = uint256(-params.amountSpecified);

        // Claims, not a real take: the manager is not holding the swapper's payment yet.
        specified.take(poolManager, address(this), specifiedAmount, true);

        uint256 amountOut = _fillFromExternalLiquidity(specified, unspecified, specifiedAmount);

        uint24 feeOverride;
        (amountOut, feeOverride) = _applyFee(key, amountOut);

        unspecified.settle(poolManager, address(this), amountOut, false);

        return (
            this.beforeSwap.selector, toBeforeSwapDelta(specifiedAmount.toInt128(), -amountOut.toInt128()), feeOverride
        );
    }

    /**
     * @notice Converts this hook's accumulated ERC-6909 claim balance for `currency` back into
     *         real tokens, replenishing the working-capital float that funds future swaps.
     * @dev Permissionless maintenance, callable by anyone (e.g. a keeper). Reverts harmlessly if
     *      the manager's real reserves for `currency` can't yet cover `amount`.
     */
    function sweepClaims(Currency currency, uint256 amount) external {
        poolManager.unlock(abi.encode(currency, amount));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        return "";
    }

    /**
     * The permission set this pattern requires: `beforeInitialize` to bind the pool,
     * `beforeAddLiquidity`/`beforeRemoveLiquidity` to keep the hook the pool's sole liquidity
     * source, and `beforeSwap` + `beforeSwapReturnDelta` to fully source swaps externally.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
