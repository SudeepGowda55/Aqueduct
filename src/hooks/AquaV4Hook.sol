// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { ITakerCallbacks } from "@1inch/swap-vm/src/interfaces/ITakerCallbacks.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { IExposureOracle } from "../oracle/IExposureOracle.sol";
import { AsyncLiquidityHook } from "./AsyncLiquidityHook.sol";

/**
 * @title AquaV4Hook
 * @notice A Uniswap v4 hook whose swaps are entirely filled by JIT liquidity sourced from a
 *         single maker's Aqua-backed SwapVM strategy, instead of from the pool's own
 *         concentrated-liquidity curve.
 *
 * @dev This is the Aqua-specific `_fillFromExternalLiquidity` implementation on top of
 *      {AsyncLiquidityHook} -- see that contract's own doc comment for the general v4
 *      flash-accounting problem it solves (a swapper's payment isn't credited to the pool's real
 *      reserves until *after* `PoolManager.swap()` returns, so a hook that wants to hand back
 *      externally-sourced output synchronously has to front it from its own working-capital float,
 *      not the not-yet-arrived payment) and the reusable claims-mint / float-fund / settle / sweep
 *      pattern that solves it, independent of what "external liquidity" means.
 *
 *      Here, "external liquidity" specifically means: a real Aqua maker strategy, executed through
 *      that maker's own SwapVM program. Critically, this hook cannot bypass the maker's own safety
 *      rules while doing so: `Aqua.pull` is only callable by the exact `app` address the maker
 *      registered when they shipped their strategy (see `Aqua.sol`, keyed as
 *      `_balances[maker][msg.sender][strategyHash][token]`), so the ONLY way to draw funds out of
 *      the maker's Aqua position is to execute a real swap through `swapVM.swap(...)`. That means
 *      every fill this hook sources runs through the maker's full SwapVM program, including any
 *      exposure-gating instruction (e.g. `_exposureGate1D`) the maker composed into it. If the
 *      maker is too exposed, `swapVM.swap` reverts, and the entire Uniswap swap reverts with it --
 *      the safety guarantee is enforced at the Aqua layer itself, not merely by convention here.
 *
 *      Scope limitations inherited from {AsyncLiquidityHook} (hackathon-grade, documented rather
 *      than silently handled): exactly one pool key and one maker `Order` per hook instance, and
 *      only exact-input swaps are filled (exact-output reverts outright, since there is no pool
 *      liquidity for `PoolManager` to fall back on).
 *
 *      SECOND, INDEPENDENT V4 CAPABILITY: a risk-adjusted dynamic LP fee (see {_applyFee} and
 *      {refreshFee} below), on top of the {AsyncLiquidityHook} base's `beforeSwapReturnDelta`
 *      pricing override. Pools bound to this hook with a *static* fee (e.g. `fee: 0`, as used by
 *      the pool proven bit-for-bit identical to the direct SwapVM path in
 *      `test/CrossVenueConsistency.t.sol`) are completely unaffected -- the fee logic is a no-op
 *      unless the pool key was initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG`. A *dynamic-fee*
 *      pool bound to this same hook code gets a swap fee that scales with the same maker's live
 *      `ExposureOracle` reading -- the identical real-time risk data that already drives the
 *      SwapVM-side `_exposureGate1D` derate/halt, now also expressed through Uniswap's own native
 *      dynamic-fee mechanism. The pattern mirrors OpenZeppelin's `uniswap-hooks` `BaseOverrideFee`
 *      (per-swap fee via the `beforeSwap` return value's `OVERRIDE_FEE_FLAG`) and `BaseDynamicFee`
 *      (`_poke`-style external refresh) -- adapted, not inherited, because this hook's `beforeSwap`
 *      already returns a real `BeforeSwapDelta` from the base contract above.
 */
contract AquaV4Hook is AsyncLiquidityHook, ITakerCallbacks {
    using LPFeeLibrary for uint24;

    /// @dev Thrown when a caller other than `swapVM` invokes a taker callback.
    error NotSwapVM();

    /// @notice The Aqua shared-liquidity layer contract.
    IAqua public immutable aqua;
    /// @notice The (possibly exposure-gated) SwapVM router the maker's strategy was shipped to.
    SwapVM public immutable swapVM;
    /// @notice The same live exposure feed the maker's own `_exposureGate1D` instruction reads --
    /// read here too so this pool's dynamic fee (if enabled) tracks the identical risk signal.
    IExposureOracle public immutable oracle;

    /// @dev The maker's SwapVM order backing this pool's liquidity.
    ISwapVM.Order private _order;

    /// @dev Risk-adjusted fee curve, in v4's hundredths-of-a-bip units (`LPFeeLibrary.MAX_LP_FEE`
    /// == 1_000_000 == 100%): 5 bps when the maker is unexposed, scaling linearly to 100 bps as
    /// exposure approaches `FEE_SATURATION_BPS` -- deliberately the same 90% halt line
    /// `_exposureGate1D` uses, so both mechanisms saturate together.
    uint24 internal constant MIN_FEE_PIPS = 500;
    uint24 internal constant MAX_FEE_PIPS = 10_000;
    uint16 internal constant FEE_SATURATION_BPS = 9_000;

    constructor(IPoolManager poolManager_, IAqua aqua_, SwapVM swapVM_, IExposureOracle oracle_, ISwapVM.Order memory order_)
        AsyncLiquidityHook(poolManager_)
    {
        aqua = aqua_;
        swapVM = swapVM_;
        oracle = oracle_;
        _order = order_;
    }

    modifier onlySwapVM() {
        if (msg.sender != address(swapVM)) revert NotSwapVM();
        _;
    }

    /**
     * @dev Executes a real swap against the maker's strategy via `swapVM.swap`, funding the input
     *      leg from this hook's own working-capital float (the base contract already minted this
     *      hook claims for `specifiedAmount` before calling this) -- this is the only step that can
     *      move funds in or out of the maker's Aqua balance, and the only step the exposure gate
     *      (or any other instruction in the maker's program) gets a chance to run. The base
     *      contract settles the returned `amountOut` to `PoolManager` on the taker's behalf.
     */
    function _fillFromExternalLiquidity(Currency specified, Currency unspecified, uint256 specifiedAmount)
        internal
        override
        returns (uint256 amountOut)
    {
        (, amountOut,) = swapVM.swap(
            _order, Currency.unwrap(specified), Currency.unwrap(unspecified), specifiedAmount, _buildTakerData()
        );
    }

    /// @dev Linear risk curve: `MIN_FEE_PIPS` at 0% exposure, `MAX_FEE_PIPS` once exposure reaches
    /// (or exceeds) `FEE_SATURATION_BPS`. A swap this function even runs for has already survived
    /// `_exposureGate1D`'s own halt check inside `_fillFromExternalLiquidity`, so exposure here is
    /// always below the hard halt -- this curve is purely about pricing risk, not gating it.
    function _riskFeePips() internal view returns (uint24) {
        (uint64 exposureBps,) = oracle.exposureOf(_order.maker);
        uint256 capped = exposureBps > FEE_SATURATION_BPS ? FEE_SATURATION_BPS : exposureBps;
        return uint24(MIN_FEE_PIPS + (uint256(MAX_FEE_PIPS - MIN_FEE_PIPS) * capped) / FEE_SATURATION_BPS);
    }

    /// @dev No-op for any pool bound to this hook with a static fee -- only pools deliberately
    /// initialized with `LPFeeLibrary.DYNAMIC_FEE_FLAG` get a risk-adjusted fee. The deducted
    /// amount simply stays in this hook's own float (the maker is this pool's sole liquidity
    /// source, so that is exactly where an LP fee should accrue).
    function _applyFee(PoolKey calldata key, uint256 amountOut) internal override returns (uint256, uint24) {
        if (!key.fee.isDynamicFee()) return (amountOut, 0);
        uint24 feePips = _riskFeePips();
        uint256 fee = (amountOut * feePips) / LPFeeLibrary.MAX_LP_FEE;
        return (amountOut - fee, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /**
     * @notice Permissionlessly pushes the current risk-based fee onto this pool's persisted
     *         `lpFee`, independent of any swap -- so anyone (a keeper, `cast call` + `cast send`,
     *         a block explorer reading `StateLibrary.getSlot0`) can observe the fee track the
     *         oracle in real time without needing to execute a fill. Mirrors OpenZeppelin's
     *         `BaseDynamicFee._poke` pattern. No-op if this pool isn't a dynamic-fee pool.
     */
    function refreshFee() external {
        if (_bound && _poolKey.fee.isDynamicFee()) {
            poolManager.updateDynamicLPFee(_poolKey, _riskFeePips());
        }
    }

    /// @inheritdoc ITakerCallbacks
    /// @dev Pushes this hook's just-taken input tokens into the maker's Aqua balance -- the
    /// mirror image of `MockTaker.preTransferInCallback` in swap-vm's own test suite.
    function preTransferInCallback(
        address maker,
        address, /* taker */
        address tokenIn,
        address, /* tokenOut */
        uint256 amountIn,
        uint256, /* amountOut */
        bytes32 orderHash,
        bytes calldata /* takerData */
    ) external onlySwapVM {
        IERC20(tokenIn).approve(address(aqua), amountIn);
        aqua.push(maker, address(swapVM), orderHash, tokenIn, amountIn);
    }

    /// @inheritdoc ITakerCallbacks
    function preTransferOutCallback(
        address, /* maker */
        address, /* taker */
        address, /* tokenIn */
        address, /* tokenOut */
        uint256, /* amountIn */
        uint256, /* amountOut */
        bytes32, /* orderHash */
        bytes calldata /* takerData */
    ) external view onlySwapVM { }

    function _buildTakerData() internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(this),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }
}
