// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AsyncLiquidityHook } from "../../src/hooks/AsyncLiquidityHook.sol";

/**
 * @title FixedRateAsyncHook
 * @notice Deliberately trivial second implementation of {AsyncLiquidityHook}, with ZERO Aqua or
 *         SwapVM involvement -- it exists purely to prove `AsyncLiquidityHook` is a genuinely
 *         reusable v4 pattern, not something shaped around this project's one integration.
 *         "External liquidity" here just means: this contract's own token balance, quoted at a
 *         fixed, owner-settable rate. That is the entire implementation.
 * @dev Not used by the live Aqueduct deployment or demo -- it is test-only scaffolding whose only
 *      job is to exercise {AsyncLiquidityHook}'s claims/float/settle/sweep machinery end to end
 *      with an implementation that shares no code, no state, and no dependency with `AquaV4Hook`.
 *      See `test/AsyncLiquidityHook.t.sol` for the real swap proving this fills correctly.
 */
contract FixedRateAsyncHook is AsyncLiquidityHook {
    /// @notice rateNumerator/rateDenominator = how much `unspecified` one unit of `specified` buys.
    uint256 public immutable rateNumerator;
    uint256 public immutable rateDenominator;

    constructor(IPoolManager poolManager_, uint256 rateNumerator_, uint256 rateDenominator_)
        AsyncLiquidityHook(poolManager_)
    {
        rateNumerator = rateNumerator_;
        rateDenominator = rateDenominator_;
    }

    /// @dev The entire "external venue": multiply by a fixed rate and pay out of this contract's
    /// own pre-funded balance. No oracle, no risk engine, no other protocol -- proving the base
    /// contract itself carries none of that complexity; it all lives in the integrator.
    function _fillFromExternalLiquidity(Currency, Currency unspecified, uint256 specifiedAmount)
        internal
        view
        override
        returns (uint256 amountOut)
    {
        amountOut = (specifiedAmount * rateNumerator) / rateDenominator;
        require(
            IERC20(Currency.unwrap(unspecified)).balanceOf(address(this)) >= amountOut,
            "FixedRateAsyncHook: insufficient float"
        );
    }
}
