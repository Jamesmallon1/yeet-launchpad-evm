// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {YeetToken} from "../src/YeetToken.sol";
import {YeetLaunchpad} from "../src/YeetLaunchpad.sol";
import {YeetHook} from "../src/YeetHook.sol";
import {YeetBuyback} from "../src/YeetBuyback.sol";

/// Dividend split (holders vs buyback-and-burn), snipe tax, protocol buybacks.
contract GreenCandleTest is BaseTest {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------ split on the curve

    function test_splitOnCurve_60pctBurn() public {
        YeetToken t = createSplit(alice, 300, 6000, 0, 0); // 3% dividend, 60% of it buys back + burns
        uint256 deadBefore = t.balanceOf(DEAD);
        buy(bob, t, 1_000e18);
        // dividend = 3% of the taxable 1000 = 30; 40% -> holders (12), 60% -> burn (18)
        assertApproxEqAbs(t.totalDividends(), 12e18, 1e6);
        YeetLaunchpad.Curve memory c = curve(t);
        assertEq(c.burnedUsdc, 18e18);
        assertGt(c.burnedTokens, 0);
        assertEq(t.balanceOf(DEAD) - deadBefore, c.burnedTokens);
        // the burn buy paid USDC into the curve: real reserve = net + burn
        assertEq(c.realUsdc, 1_000e18 - 3e18 - 30e18 + 18e18);
        // curve accounting still closes
        assertEq(address(launchpad).balance, launchpad.accruedFees() + c.realUsdc);
    }

    function test_splitAllToBurn() public {
        YeetToken t = createSplit(alice, 300, 10_000, 0, 0);
        buy(bob, t, 500e18);
        assertEq(t.totalDividends(), 0);
        assertEq(curve(t).burnedUsdc, 15e18);
    }

    function test_splitOnSell() public {
        YeetToken t = createSplit(alice, 100, 5000, 0, 0);
        buy(bob, t, 1_000e18);
        uint256 burnedBefore = curve(t).burnedUsdc;
        uint256 divBefore = t.totalDividends();
        sell(bob, t, t.balanceOf(bob) / 2);
        assertGt(curve(t).burnedUsdc, burnedBefore);
        assertGt(t.totalDividends(), divBefore);
        // 50/50 split of the sell dividend
        assertApproxEqAbs(curve(t).burnedUsdc - burnedBefore, t.totalDividends() - divBefore, 1);
    }

    function test_burnBuyCanCompleteCurve() public {
        YeetToken t = createSplit(alice, 300, 10_000, 0, 0);
        for (uint256 i; i < 40; ++i) {
            if (curve(t).complete) break;
            buy(carol, t, 2_000e18);
        }
        assertTrue(curve(t).graduated);
        assertEq(t.balanceOf(address(launchpad)), 0);
    }

    // ------------------------------------------------------------ split after graduation (pool)

    function test_splitOnPool_pendingBurnAndExecute() public {
        YeetToken t = createSplit(alice, 300, 5000, 0, 0);
        completeCurve(t);
        assertTrue(curve(t).graduated);
        assertEq(hook.burnShareOf(address(t)), 5000);

        uint256 divBefore = t.totalDividends();
        vm.prank(bob);
        router.buy{value: 100e18}(address(t), 0);
        // 3 USDC dividend: 1.5 to holders now, 1.5 pending burn
        assertApproxEqAbs(t.totalDividends() - divBefore, 1.5e18, 1);
        assertEq(hook.pendingBurn(address(t)), 1.5e18);
        assertEq(hook.accruedFees(), 0.3e18);

        uint256 deadBefore = t.balanceOf(DEAD);
        vm.prank(carol); // anyone
        (uint256 usdcIn, uint256 burned) = hook.executeBuyback(address(t));
        assertEq(usdcIn, 1.5e18);
        assertGt(burned, 0);
        assertEq(t.balanceOf(DEAD) - deadBefore, burned);
        assertEq(hook.pendingBurn(address(t)), 0);
        assertEq(hook.totalBurned(address(t)), burned);
        // the buyback swap itself paid no hook fees
        assertEq(hook.accruedFees(), 0.3e18);
        assertEq(hook.pendingBurn(address(t)), 0);
        vm.expectRevert(YeetHook.NothingPending.selector);
        hook.executeBuyback(address(t));
    }

    // ------------------------------------------------------------ snipe tax

    function test_snipeTaxDecays() public {
        vm.prank(alice);
        YeetToken t = YeetToken(launchpad.createToken("S", "S", "u", 0, 0, 0));
        assertEq(launchpad.snipeTaxSeconds(), 3);
        assertEq(launchpad.snipeTaxBps(address(t)), 9900);
        vm.warp(block.timestamp + 1);
        assertEq(launchpad.snipeTaxBps(address(t)), 2475);
        vm.warp(block.timestamp + 1);
        assertEq(launchpad.snipeTaxBps(address(t)), 618);
        vm.warp(block.timestamp + 1);
        assertEq(launchpad.snipeTaxBps(address(t)), 0);
    }

    function test_snipeTaxTakenAndPaidToHolders() public {
        vm.prank(alice);
        YeetToken t = YeetToken(launchpad.createToken("S", "S", "u", 300, 0, 0));
        // same second as creation: 99% tax
        (uint256 q,,,, uint256 snipe,) = launchpad.quoteBuy(address(t), 100e18);
        assertEq(snipe, 99e18);
        uint256 out = buy(bob, t, 100e18);
        assertEq(out, q);
        // bob got tokens for ~1 USDC; the 99 USDC snipe tax went to the holder dividend (bob is the only holder)
        assertApproxEqAbs(t.totalDividends(), 99e18 + 0.03e18, 1e6);
        // after the window, no tax
        vm.warp(block.timestamp + 3);
        (,,,, snipe,) = launchpad.quoteBuy(address(t), 100e18);
        assertEq(snipe, 0);
    }

    function test_devBuyExemptFromSnipeTax() public {
        uint256 pre = alice.balance;
        vm.prank(alice);
        YeetToken t = YeetToken(launchpad.createToken{value: 200e18}("S", "S", "u", 300, 0, 500));
        // 200 USDC buys ≥ 5% without any snipe tax (a 99% tax would leave ~2 USDC and revert DevBuyShortfall)
        assertGe(t.balanceOf(alice), 50_000_000e18);
        assertEq(pre - alice.balance, 200e18);
    }

    function test_snipeTaxWithBurnSplit() public {
        vm.prank(alice);
        YeetToken t = YeetToken(launchpad.createToken("S", "S", "u", 300, 10_000, 0));
        buy(bob, t, 100e18);
        // all of the snipe tax + dividend bought the token back and burned it
        assertEq(t.totalDividends(), 0);
        assertApproxEqAbs(curve(t).burnedUsdc, 99e18 + 0.03e18, 1e6);
    }

    // ------------------------------------------------------------ protocol buybacks

    function test_protocolBuybackOnCurveAndPool() public {
        YeetToken yeet = create(alice, 300, 0, 0); // "the protocol token"
        YeetToken other = create(alice, 0, 0, 0);
        buy(bob, other, 1_000e18); // 3 USDC protocol fee
        launchpad.sweepFees();
        assertEq(address(buyback).balance, 3e18);

        // token is set once, forever
        vm.prank(owner);
        buyback.setToken(address(yeet));
        vm.prank(owner);
        vm.expectRevert(YeetBuyback.TokenAlreadySet.selector);
        buyback.setToken(address(other));

        // 1. buys from the curve while YEET is on it
        uint256 deadBefore = yeet.balanceOf(DEAD);
        vm.prank(carol);
        (uint256 usdcIn, uint256 burned) = buyback.execute(type(uint256).max);
        assertEq(usdcIn, 2.55e18); // 85% of the 3 USDC fee
        assertEq(yeet.balanceOf(DEAD) - deadBefore, burned);
        assertGt(burned, 0);
        assertEq(address(buyback).balance, 0.45e18); // treasury's 15% waits to be pulled
        // the protocol buyback paid no protocol fee on itself (fees unchanged), but did pay YEET holders their dividend
        assertEq(launchpad.accruedFees(), 0);

        // 2. after graduation it buys from the pool
        completeCurve(yeet);
        assertTrue(curve(yeet).graduated);
        vm.prank(bob);
        router.buy{value: 1_000e18}(address(yeet), 0); // pool trade: hook fees accrue
        hook.sweepFees();
        launchpad.sweepFees();
        uint256 bal = buyback.burnBalance();
        assertGt(bal, 0);
        deadBefore = yeet.balanceOf(DEAD);
        (usdcIn, burned) = buyback.execute(type(uint256).max);
        assertEq(usdcIn, bal);
        assertEq(yeet.balanceOf(DEAD) - deadBefore, burned);
        assertGt(buyback.totalBurned(), burned);
    }
}
