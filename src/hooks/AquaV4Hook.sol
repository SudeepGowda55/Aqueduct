// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { SwapParams, ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import { BaseHook } from "uniswap-hooks/src/base/BaseHook.sol";
import { CurrencySettler } from "uniswap-hooks/src/utils/CurrencySettler.sol";

import { IAqua } from "@1inch/aqua/src/interfaces/IAqua.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { SwapVM } from "@1inch/swap-vm/src/SwapVM.sol";
import { ITakerCallbacks } from "@1inch/swap-vm/src/interfaces/ITakerCallbacks.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

/**
 * @title AquaV4Hook
 * @notice A Uniswap v4 hook whose swaps are entirely filled by JIT liquidity sourced from a
 *         single maker's Aqua-backed SwapVM strategy, instead of from the pool's own
 *         concentrated-liquidity curve.
 *
 * @dev The pool this hook is attached to carries NO liquidity of its own -- direct add/remove
 *      liquidity is disabled (see {_beforeAddLiquidity}/{_beforeRemoveLiquidity}), and the
 *      `_beforeSwap` implementation fully overrides the swap via `beforeSwapReturnDelta`, so the
 *      core v3-style AMM math in `PoolManager` never actually executes (the amount fed to it is
 *      always netted to zero). All pricing and execution comes from the maker's SwapVM program.
 *
 *      Critically, this hook cannot bypass the maker's own safety rules: `Aqua.pull` is only
 *      callable by the exact `app` address the maker registered when they shipped their strategy
 *      (see `Aqua.sol`, keyed as `_balances[maker][msg.sender][strategyHash][token]`), so the ONLY
 *      way to draw funds out of the maker's Aqua position is to execute a real swap through
 *      `swapVM.swap(...)`. That means every fill this hook sources runs through the maker's full
 *      SwapVM program, including any exposure-gating instruction (e.g. `_exposureGate1D`) the
 *      maker composed into it. If the maker is too exposed, `swapVM.swap` reverts, and the entire
 *      Uniswap swap reverts with it -- the safety guarantee is enforced at the Aqua layer itself,
 *      not merely by convention in this hook.
 *
 *      WORKING-CAPITAL FLOAT: `PoolManager`'s flash accounting only credits a swapper's actual
 *      payment to the pool's real reserves *after* `PoolManager.swap()` returns to the top-level
 *      router (see `PoolSwapTest.unlockCallback`, which settles deltas only once `manager.swap()`
 *      is done) -- so a real, non-claim `take()` of the swapper's input inside `_beforeSwap` would
 *      revert, since the manager is not holding it yet. This hook therefore funds the Aqua-side
 *      leg from its own small working-capital balance (seeded by a plain ERC20 transfer to this
 *      contract's address -- no bespoke deposit function needed) rather than from the swapper's
 *      not-yet-arrived payment, and instead mints itself ERC-6909 claim tokens for that amount to
 *      close out its own delta. Those claims are real, redeemable value (backed by the swapper's
 *      payment landing later in the very same transaction) and can be converted back into real
 *      tokens at any time via {sweepClaims}, once the pool's real reserves for that currency have
 *      accumulated enough from past swaps -- replenishing the float for future swaps.
 *
 *      Scope limitations (hackathon-grade, documented rather than silently handled):
 *        - Exactly one pool key and one maker `Order` per hook instance (mirrors the single-pool
 *          binding pattern of OpenZeppelin's `ReHypothecationHook`).
 *        - Only exact-input swaps are filled via Aqua; exact-output swaps revert outright, since
 *          there is no pool liquidity for the `PoolManager` to fall back on.
 *        - No automatic float sizing/sweeping: {sweepClaims} must be called by a keeper (or
 *          anyone) once enough real reserves have accumulated; it is a plain, permissionless
 *          maintenance operation, not a security boundary.
 */
contract AquaV4Hook is BaseHook, ITakerCallbacks, IUnlockCallback {
    using CurrencySettler for Currency;
    using SafeCast for uint256;

    /// @dev Thrown when an exact-output swap is attempted; only exact-input is supported.
    error ExactOutputNotSupported();
    /// @dev Thrown when a third party attempts to add or remove liquidity directly on the pool.
    error LiquidityNotAllowed();
    /// @dev Thrown when the pool has already been bound to this hook's maker order.
    error AlreadyBound();
    /// @dev Thrown when a swap is attempted before the pool has been initialized.
    error NotBound();
    /// @dev Thrown when a caller other than `swapVM` invokes a taker callback.
    error NotSwapVM();

    /// @notice The Aqua shared-liquidity layer contract.
    IAqua public immutable aqua;
    /// @notice The (possibly exposure-gated) SwapVM router the maker's strategy was shipped to.
    SwapVM public immutable swapVM;

    /// @dev The single pool this hook is bound to, set once at `_beforeInitialize`.
    PoolKey private _poolKey;
    /// @dev The maker's SwapVM order backing this pool's liquidity.
    ISwapVM.Order private _order;
    bool private _bound;

    constructor(IPoolManager poolManager_, IAqua aqua_, SwapVM swapVM_, ISwapVM.Order memory order_)
        BaseHook(poolManager_)
    {
        aqua = aqua_;
        swapVM = swapVM_;
        _order = order_;
    }

    modifier onlySwapVM() {
        if (msg.sender != address(swapVM)) revert NotSwapVM();
        _;
    }

    /// @notice Returns the pool key this hook is bound to.
    function getPoolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /**
     * @dev Binds the hook to the first pool key it sees. As with `ReHypothecationHook`, pool
     * initialization is permissionless, so this should be triggered atomically with the hook's
     * own deployment (e.g. via a single script/multicall) to avoid front-running with an
     * unintended pool key.
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

    /**
     * @dev Fully sources an exact-input swap from the maker's Aqua-backed SwapVM strategy:
     *      1. Mints this hook ERC-6909 claim tokens for the taker's specified input amount,
     *         closing out the credit this function's return value declares for that currency (see
     *         the contract-level comment on why a *real* take() is not possible here).
     *      2. Executes a real swap against the maker's strategy via `swapVM.swap`, funding the
     *         input leg from this hook's own working-capital balance (not the freshly-minted
     *         claims, which are not real tokens) -- this is the only step that can move funds in
     *         or out of the maker's Aqua balance, and the only step the exposure gate (or any
     *         other instruction in the maker's program) gets a chance to run.
     *      3. Pays the Aqua-sourced output to the `PoolManager` on the taker's behalf.
     *      4. Returns a `BeforeSwapDelta` that nets the specified amount to zero (so the core v3
     *         math never runs) and credits the taker with the unspecified amount, so the overall
     *         swap settles atomically in this same transaction -- see the contract-level comment
     *         for why this is safe against the `PoolManager`'s own delta accounting.
     */
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

        specified.take(poolManager, address(this), specifiedAmount, true);

        (, uint256 amountOut,) = swapVM.swap(
            _order, Currency.unwrap(specified), Currency.unwrap(unspecified), specifiedAmount, _buildTakerData()
        );

        unspecified.settle(poolManager, address(this), amountOut, false);

        return (
            this.beforeSwap.selector,
            toBeforeSwapDelta(specifiedAmount.toInt128(), -amountOut.toInt128()),
            0
        );
    }

    /**
     * @notice Converts this hook's accumulated ERC-6909 claim balance for `currency` back into
     *         real tokens, replenishing the working-capital float that funds future swaps.
     * @dev Permissionless and callable by anyone (e.g. a keeper) at any time; it simply reverts
     *      if the `PoolManager`'s real reserves for `currency` (accumulated from past swappers'
     *      settled payments) can't yet cover `amount`. Not a security boundary -- see the
     *      contract-level comment.
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

    /**
     * Set the hook permissions: `beforeInitialize` to bind the pool, `beforeAddLiquidity` /
     * `beforeRemoveLiquidity` to keep this hook the pool's sole liquidity source, and
     * `beforeSwap` + `beforeSwapReturnDelta` to fully source swaps from Aqua.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
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
