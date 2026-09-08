// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

contract CurveMathTest is Test {
    CurveMath.Params P = CurveMath.params(3_500e18, 10_000e18);
    function test_parameters() public view {
        // S = 794,117,647.05.. ; LP = 205,882,352.94.. ; V_T0 = 1,072,058,823.5..
        assertApproxEqRel(P.curveSupply, 794_117_647e18, 1e12);
        assertApproxEqRel(P.lpSupply, 205_882_353e18, 1e12);
        assertApproxEqRel(P.vToken0, 1_072_058_824e18, 1e12);
        assertEq(P.curveSupply + P.lpSupply, CurveMath.SUPPLY);
    }

    function test_launchAndGraduationPrice() public view {
        uint256 p0 = CurveMath.price(P, 0, 0);
        assertApproxEqRel(p0, 3.2647e-6 * 1e18, 1e14);
        uint256 usdc = CurveMath.usdcIn(P, 0, 0, P.curveSupply);
        assertApproxEqAbs(usdc, P.target, 1e6); // whole curve costs exactly the target (± dust)
        uint256 pf = CurveMath.price(P, usdc, P.curveSupply);
        assertApproxEqRel(pf, 4.857e-5 * 1e18, 1e14);
        // pool price with all raised USDC and all reserved tokens equals the final curve price
        uint256 poolPrice = usdc * 1e18 / P.lpSupply;
        assertApproxEqRel(poolPrice, pf, 1e9);
        assertApproxEqRel(pf * 1e9 / p0, 14.9e9, 2e16);
    }

    function testFuzz_buyThenSellNeverProfits(uint256 realUsdc, uint256 sold, uint256 usdcIn) public view {
        sold = bound(sold, 0, P.curveSupply - 1e18);
        realUsdc = bound(realUsdc, 0, CurveMath.usdcIn(P, 0, 0, sold));
        usdcIn = bound(usdcIn, 1, 5_000e18);
        uint256 out = CurveMath.tokensOut(P, realUsdc, sold, usdcIn);
        if (out == 0 || sold + out > P.curveSupply) return;
        uint256 back = CurveMath.usdcOut(P, realUsdc + usdcIn, sold + out, out);
        assertLe(back, usdcIn);
    }

    function testFuzz_monotonic(uint256 realUsdc, uint256 sold, uint256 a, uint256 b) public view {
        sold = bound(sold, 0, P.curveSupply - 1e18);
        realUsdc = bound(realUsdc, 0, CurveMath.usdcIn(P, 0, 0, sold));
        a = bound(a, 1, 5_000e18);
        b = bound(b, a, 5_000e18);
        assertLe(CurveMath.tokensOut(P, realUsdc, sold, a), CurveMath.tokensOut(P, realUsdc, sold, b));
    }

    function testFuzz_usdcInRoundTrip(uint256 sold, uint256 amountOut) public view {
        sold = bound(sold, 0, P.curveSupply - 1e18);
        uint256 realUsdc = CurveMath.usdcIn(P, 0, 0, sold);
        amountOut = bound(amountOut, 1e18, P.curveSupply - sold);
        uint256 need = CurveMath.usdcIn(P, realUsdc, sold, amountOut);
        uint256 got = CurveMath.tokensOut(P, realUsdc, sold, need);
        assertGe(got, amountOut - 1); // paying the quoted amount yields at least the requested tokens (±1 wei)
        assertLe(got, amountOut + 1e6);
    }

    function test_priceIncreasesAlongCurve() public view {
        uint256 last;
        for (uint256 i = 1; i <= 10; ++i) {
            uint256 sold = P.curveSupply * i / 10;
            uint256 p = CurveMath.price(P, CurveMath.usdcIn(P, 0, 0, sold), sold);
            assertGt(p, last);
            last = p;
        }
    }
}
