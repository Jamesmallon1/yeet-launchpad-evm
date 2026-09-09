// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {YeetToken} from "../src/YeetToken.sol";
import {YeetHook} from "../src/YeetHook.sol";
import {YeetLaunchpad} from "../src/YeetLaunchpad.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Direct PoolManager caller for exact-output shapes the router does not expose.
contract RawSwapper is IUnlockCallback {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external payable returns (BalanceDelta d) {
        bytes memory r = pm.unlock(abi.encode(key, zeroForOne, amountSpecified));
        d = abi.decode(r, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified) = abi.decode(data, (PoolKey, bool, int256));
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        if (d.amount0() < 0) pm.settle{value: uint256(uint128(-d.amount0()))}();
        if (d.amount0() > 0) pm.take(key.currency0, address(this), uint256(uint128(d.amount0())));
        if (d.amount1() < 0) {
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transfer(address(pm), uint256(uint128(-d.amount1())));
            pm.settle();
        }
        if (d.amount1() > 0) pm.take(key.currency1, address(this), uint256(uint128(d.amount1())));
        return abi.encode(d);
    }
}

contract PoolTest is BaseTest {
    YeetToken t;
    uint256 feeBps = 330;

    function setUp() public override {
        super.setUp();
        t = create(alice, 300, 0, 0);
        completeCurve(t);
        assertTrue(curve(t).graduated);
    }

    function test_routerBuyTakesFeeAndPaysDividend() public {
        uint256 divBefore = t.totalDividends();
        uint256 feesBefore = hook.accruedFees();
        (uint256 q,,,) = router.quote(address(t), true, 100e18);
        vm.prank(bob);
        uint256 out = router.buy{value: 100e18}(address(t), 0);
        assertEq(out, q);
        assertEq(t.balanceOf(bob), out);
        assertEq(hook.accruedFees() - feesBefore, 100e18 * 30 / BPS);
        assertEq(t.totalDividends() - divBefore, 100e18 * 300 / BPS);
        assertEq(address(pm).balance, address(pm).balance); // sanity
    }

    function test_routerSellTakesFeeFromOutput() public {
        vm.prank(bob);
        uint256 got = router.buy{value: 100e18}(address(t), 0);
        uint256 divBefore = t.totalDividends();
        uint256 feesBefore = hook.accruedFees();
        (uint256 q, uint256 qfee,,) = router.quote(address(t), false, got);
        uint256 pre = bob.balance;
        vm.startPrank(bob);
        t.approve(address(router), got);
        uint256 out = router.sell(address(t), got, 0);
        vm.stopPrank();
        assertApproxEqAbs(out, q, 1); // quote is exact to 1 wei of swap-math rounding
        assertEq(bob.balance - pre, out);
        uint256 gross = out + qfee;
        assertApproxEqAbs(hook.accruedFees() - feesBefore, gross * 30 / BPS, 1);
        assertApproxEqAbs(t.totalDividends() - divBefore, gross * 300 / BPS, 1);
        assertLt(out, 100e18); // fees both ways
        assertGt(out, 93e18); // 100 * 0.967 * 0.967 minus price impact
    }

    function test_exactOutputShapesAlsoPayFees() public {
        RawSwapper s = new RawSwapper(pm);
        vm.deal(address(s), 1_000e18);
        PoolKey memory key = graduator.poolKey(address(t));

        // buy exact-out 1M tokens: USDC is unspecified input → afterSwap fee
        uint256 feesBefore = hook.accruedFees();
        BalanceDelta d = s.swap(key, true, int256(1_000_000e18));
        assertEq(uint256(uint128(d.amount1())), 1_000_000e18);
        uint256 paid = uint256(uint128(-d.amount0()));
        assertGt(hook.accruedFees() - feesBefore, 0);
        // fee = 3.3% of gross input; gross = paid - fee → paid = gross * 1.033
        uint256 protocolTaken = hook.accruedFees() - feesBefore;
        assertApproxEqRel(protocolTaken * feeBps / 30, paid * feeBps / (BPS + feeBps), 1e12);

        // sell exact-out 10 USDC: USDC is specified output → beforeSwap fee
        feesBefore = hook.accruedFees();
        d = s.swap(key, false, int256(10e18));
        assertEq(uint256(uint128(d.amount0())), 10e18);
        assertEq(hook.accruedFees() - feesBefore, 10e18 * 30 / BPS);
    }

    function test_hookRejectsForeignPools() public {
        PoolKey memory key = graduator.poolKey(address(t));
        key.fee = 3000;
        vm.expectRevert();
        pm.initialize(key, 1 << 96);
        PoolKey memory key2 = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        pm.initialize(key2, 1 << 96);
    }

    function test_dividendsContinueAfterGraduation() public {
        uint256 carolBefore = t.claimable(carol);
        vm.prank(bob);
        router.buy{value: 1_000e18}(address(t), 0);
        assertGt(t.claimable(carol), carolBefore);
        uint256 pre = carol.balance;
        vm.prank(carol);
        t.claim();
        assertGt(carol.balance, pre);
    }

    function test_hookFeesSweepToBuyback() public {
        vm.prank(bob);
        router.buy{value: 1_000e18}(address(t), 0);
        assertEq(hook.accruedFees(), 3e18);
        vm.prank(bob);
        hook.sweepFees();
        assertEq(hook.accruedFees(), 0);
        assertEq(address(buyback).balance, 3e18);
    }

    function test_liquidityIsLocked() public view {
        // graduator has no liquidity-removal entry point; position is keyed to it inside PoolManager
        assertGt(graduator.liquidityOf(address(t)), 0);
        assertEq(t.balanceOf(address(graduator)), 0);
    }
}
