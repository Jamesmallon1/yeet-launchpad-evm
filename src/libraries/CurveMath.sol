// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CurveMath
/// @notice Constant-product bonding curve with virtual reserves (pump.fun shape) in native USDC (18-dec on Arc).
/// @dev Parameters are derived from (vUsdc0, target) so the pool can be seeded with ALL the raised USDC and ALL
///      the reserved tokens at exactly the curve's final price:
///        S   = SUPPLY * (V_U + R) / (2 V_U + R)      tokens sold on the curve
///        V_T = S * (V_U + R) / R                     initial virtual token reserve
///      Production: vUsdc0 = 3,500 USDC, target = 10,000 USDC. Rounding is always against the trader.
library CurveMath {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    struct Params {
        uint256 vUsdc0;
        uint256 target;
        uint256 curveSupply;
        uint256 lpSupply;
        uint256 vToken0;
    }

    error InsufficientLiquidity();
    error BadParams();

    function params(uint256 vUsdc0, uint256 target) internal pure returns (Params memory p) {
        if (vUsdc0 == 0 || target == 0) revert BadParams();
        p.vUsdc0 = vUsdc0;
        p.target = target;
        p.curveSupply = SUPPLY * (vUsdc0 + target) / (2 * vUsdc0 + target);
        p.lpSupply = SUPPLY - p.curveSupply;
        p.vToken0 = p.curveSupply * (vUsdc0 + target) / target;
    }

    function reserves(Params memory p, uint256 realUsdc, uint256 tokensSold)
        internal
        pure
        returns (uint256 vU, uint256 vT)
    {
        vU = p.vUsdc0 + realUsdc;
        vT = p.vToken0 - tokensSold;
    }

    /// @notice Tokens received for `usdcIn` (net of fees).
    function tokensOut(Params memory p, uint256 realUsdc, uint256 tokensSold, uint256 usdcIn)
        internal
        pure
        returns (uint256)
    {
        (uint256 vU, uint256 vT) = reserves(p, realUsdc, tokensSold);
        uint256 newVT = Math.ceilDiv(vU * vT, vU + usdcIn);
        return vT - newVT;
    }

    /// @notice USDC (net of fees) required to receive exactly `amountOut` tokens.
    function usdcIn(Params memory p, uint256 realUsdc, uint256 tokensSold, uint256 amountOut)
        internal
        pure
        returns (uint256)
    {
        (uint256 vU, uint256 vT) = reserves(p, realUsdc, tokensSold);
        if (amountOut >= vT) revert InsufficientLiquidity();
        uint256 newVU = Math.ceilDiv(vU * vT, vT - amountOut);
        return newVU - vU;
    }

    /// @notice Gross USDC (before fees) received for selling `tokensIn`.
    function usdcOut(Params memory p, uint256 realUsdc, uint256 tokensSold, uint256 tokensIn)
        internal
        pure
        returns (uint256)
    {
        (uint256 vU, uint256 vT) = reserves(p, realUsdc, tokensSold);
        uint256 newVU = Math.ceilDiv(vU * vT, vT + tokensIn);
        return vU - newVU;
    }

    /// @notice Spot price in USDC per token, 18 decimals.
    function price(Params memory p, uint256 realUsdc, uint256 tokensSold) internal pure returns (uint256) {
        (uint256 vU, uint256 vT) = reserves(p, realUsdc, tokensSold);
        return vU * 1e18 / vT;
    }
}
