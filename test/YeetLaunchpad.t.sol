// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {YeetToken} from "../src/YeetToken.sol";
import {YeetLaunchpad} from "../src/YeetLaunchpad.sol";
import {YeetBuyback} from "../src/YeetBuyback.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract YeetLaunchpadTest is BaseTest {
    using StateLibrary for IPoolManager;

    function test_createWithoutDevBuyRefundsValue() public {
        uint256 pre = alice.balance;
        YeetToken t = create(alice, 100, 0, 5e18);
        assertEq(alice.balance, pre);
        assertEq(t.balanceOf(alice), 0);
        assertEq(launchpad.tokenCount(), 1);
    }

    function test_devBuy() public {
        uint256 cost = CurveMath.usdcIn(P, 0, 0, CurveMath.SUPPLY * 5 / 100);
        uint256 gross = cost * BPS / (BPS - 30 - 300) + 1e18; // plenty
        uint256 pre = alice.balance;
        YeetToken t = create(alice, 300, 500, gross);
        assertGe(t.balanceOf(alice), CurveMath.SUPPLY * 5 / 100);
        // dev buy spends all of msg.value (no refund unless it completes the curve): ~171 net + 3.3% fees + 1
        assertEq(pre - alice.balance, gross);
        assertLt(gross, 180e18);
        assertGt(gross, 176e18);
    }

    function test_devBuyShortfallReverts() public {
        vm.expectRevert(YeetLaunchpad.DevBuyShortfall.selector);
        vm.prank(alice);
        launchpad.createToken{value: 10e18}("A", "A", "u", 0, 0, 500);
    }

    function test_devBuyCap() public {
        vm.expectRevert(YeetLaunchpad.DevBuyTooLarge.selector);
        vm.prank(alice);
        launchpad.createToken{value: 1e18}("A", "A", "u", 0, 0, 5001);
    }

    function test_invalidTax() public {
        vm.expectRevert(YeetLaunchpad.InvalidTax.selector);
        vm.prank(alice);
        launchpad.createToken("A", "A", "u", 200, 0, 0);
        vm.expectRevert(YeetLaunchpad.InvalidSplit.selector);
        vm.prank(alice);
        launchpad.createToken("A", "A", "u", 300, 10_001, 0);
    }

    function test_buySellFeesAndReserves() public {
        YeetToken t = create(alice, 100, 0, 0);
        (uint256 q,,,,,) = launchpad.quoteBuy(address(t), 1_000e18); // quoted on the same state as the buy
        uint256 out = buy(bob, t, 1_000e18);
        assertEq(out, CurveMath.tokensOut(P, 0, 0, 1_000e18 - 3e18 - 10e18));
        assertEq(q, out);
        YeetLaunchpad.Curve memory c = curve(t);
        assertEq(c.realUsdc, 1_000e18 - 3e18 - 10e18);
        assertEq(c.tokensSold, out);
        assertEq(launchpad.accruedFees(), 3e18);
        assertEq(t.totalDividends(), 10e18);

        uint256 pre = bob.balance;
        uint256 usdc = sell(bob, t, out);
        assertGt(bob.balance - pre, 0);
        assertEq(bob.balance - pre, usdc);
        assertLt(usdc, 1_000e18); // round trip loses fees
        c = curve(t);
        assertEq(c.tokensSold, 0);
        assertLe(c.realUsdc, 1e6); // back to ~0 (rounding dust favours the curve)
        assertEq(address(launchpad).balance, launchpad.accruedFees() + c.realUsdc);
    }

    function test_slippage() public {
        YeetToken t = create(alice, 0, 0, 0);
        vm.expectRevert(YeetLaunchpad.Slippage.selector);
        vm.prank(bob);
        launchpad.buy{value: 1e18}(address(t), type(uint256).max);
    }

    function test_completeCurveGraduatesAtomically() public {
        YeetToken t = create(alice, 300, 0, 0);
        uint256 pre = carol.balance;
        completeCurve(t);
        YeetLaunchpad.Curve memory c = curve(t);
        assertTrue(c.complete);
        assertTrue(c.graduated);
        assertEq(c.tokensSold, launchpad.CURVE_SUPPLY());
        assertEq(c.realUsdc, 0); // moved to the pool
        assertTrue(c.poolId != bytes32(0));

        // total spent by carol = ~10,000 net + fees, with the final buy's excess refunded
        uint256 spent = pre - carol.balance;
        assertApproxEqRel(spent, 10_000e18 * BPS / (BPS - 330), 1e14);

        // launchpad holds exactly its fees (curve USDC is in the pool)
        assertEq(address(launchpad).balance, launchpad.accruedFees());
        // all reserved tokens left the launchpad; dust burned
        assertEq(t.balanceOf(address(launchpad)), 0);
        assertLe(t.balanceOf(address(graduator)), 0);

        // pool price == final curve price
        (uint160 sqrtP,,,) = pm.getSlot0(PoolId.wrap(c.poolId));
        uint256 poolPrice = 1e18 * (1 << 96) / sqrtP; // usdc per token ≈ (2^96/sqrtP)^2 … compare squared below
        poolPrice = poolPrice * (1 << 96) / sqrtP;
        uint256 curvePrice = CurveMath.price(P, CurveMath.usdcIn(P, 0, 0, launchpad.CURVE_SUPPLY()), launchpad.CURVE_SUPPLY());
        assertApproxEqRel(poolPrice, curvePrice, 1e12);

        // curve closed
        vm.expectRevert(YeetLaunchpad.CurveClosed.selector);
        vm.prank(bob);
        launchpad.buy{value: 1e18}(address(t), 0);
    }

    function test_finalBuyRefundsExcess() public {
        YeetToken t = create(alice, 0, 0, 0);
        for (uint256 i; i < 4; ++i) buy(carol, t, 2_000e18);
        uint256 pre = bob.balance;
        buy(bob, t, 50_000e18); // way more than needed
        uint256 spent = pre - bob.balance;
        assertLt(spent, 3_000e18);
        assertTrue(curve(t).graduated);
    }

    function test_protocolFeesCanOnlyGoToBuyback() public {
        YeetToken t = create(alice, 0, 0, 0);
        buy(bob, t, 1_000e18);
        assertEq(launchpad.accruedFees(), 3e18);
        // anyone can sweep; the only destination is the buyback contract
        vm.prank(bob);
        launchpad.sweepFees();
        assertEq(launchpad.accruedFees(), 0);
        assertEq(address(buyback).balance, 3e18);
        assertEq(buyback.totalReceived(), 3e18);
        // 85% is reserved for burns, 15% for the treasury; no owner path to the 85%, ever
        assertEq(buyback.burnBalance(), 2.55e18);
        assertEq(buyback.treasuryAccrued(), 0.45e18);
        vm.prank(owner);
        vm.expectRevert(YeetBuyback.TokenNotSet.selector);
        buyback.execute(type(uint256).max);
        // only the treasury can pull its share
        vm.prank(bob);
        vm.expectRevert(YeetBuyback.NotTreasury.selector);
        buyback.withdrawTreasury();
        uint256 pre = owner.balance;
        vm.prank(owner); // treasury defaults to the owner
        buyback.withdrawTreasury();
        assertEq(owner.balance - pre, 0.45e18);
        assertEq(address(buyback).balance, 2.55e18);
    }

    function test_pauseCreation() public {
        vm.prank(owner);
        launchpad.setCreationPaused(true);
        vm.expectRevert(YeetLaunchpad.CreationIsPaused.selector);
        vm.prank(alice);
        launchpad.createToken("A", "A", "u", 0, 0, 0);
        // trading unaffected
        vm.prank(owner);
        launchpad.setCreationPaused(false);
        YeetToken t = create(alice, 0, 0, 0);
        vm.prank(owner);
        launchpad.setCreationPaused(true);
        buy(bob, t, 1e18);
    }

    function testFuzz_randomTradesKeepAccounting(uint256 seed) public {
        YeetToken t = create(alice, 100, 0, 0);
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 20; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address w = who[seed % 3];
            if (curve(t).complete) break;
            if (seed % 4 == 0 && t.balanceOf(w) > 0) {
                sell(w, t, t.balanceOf(w) * ((seed >> 8) % 100 + 1) / 100);
            } else {
                buy(w, t, ((seed >> 16) % 500 + 1) * 1e18);
            }
            YeetLaunchpad.Curve memory c = curve(t);
            if (!c.graduated) {
                assertEq(address(launchpad).balance, launchpad.accruedFees() + c.realUsdc);
                assertEq(t.balanceOf(address(launchpad)), CurveMath.SUPPLY - c.tokensSold);
            }
        }
    }
}
