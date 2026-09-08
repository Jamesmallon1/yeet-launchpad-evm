// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {YeetToken} from "../src/YeetToken.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

contract YeetTokenTest is BaseTest {
    YeetToken t;

    function setUp() public override {
        super.setUp();
        t = create(alice, 300, 0, 0);
    }

    function test_supplyAndExclusions() public view {
        assertEq(t.totalSupply(), CurveMath.SUPPLY);
        assertEq(t.balanceOf(address(launchpad)), CurveMath.SUPPLY);
        assertEq(t.eligibleSupply(), 0);
        assertTrue(t.isExcluded(address(launchpad)));
        assertTrue(t.isExcluded(address(graduator)));
        assertTrue(t.isExcluded(address(pm)));
        assertTrue(t.isExcluded(address(hook)));
        assertEq(t.taxBps(), 300);
    }

    function test_onlyDistributorCanNotify() public {
        vm.expectRevert(YeetToken.NotDistributor.selector);
        vm.prank(alice);
        t.notifyDividend{value: 1e18}();
    }

    function test_dividendsProRata() public {
        buy(alice, t, 1_000e18); // alice gets her own dividend back (only holder)
        uint256 aliceBal = t.balanceOf(alice);
        uint256 claimableAfterOwnBuy = t.claimable(alice);
        assertApproxEqAbs(claimableAfterOwnBuy, 1_000e18 * 300 / BPS, 1e6); // MAGNITUDE rounding dust

        buy(bob, t, 1_000e18); // dividend of bob's buy split by balance between alice and bob
        uint256 bobBal = t.balanceOf(bob);
        uint256 div = 1_000e18 * 300 / BPS;
        uint256 aliceShare = div * aliceBal / (aliceBal + bobBal);
        assertApproxEqAbs(t.claimable(alice), claimableAfterOwnBuy + aliceShare, 1e6);
        assertApproxEqAbs(t.claimable(bob), div - aliceShare, 1e6);

        // transfer moves future dividends, not accrued ones
        vm.prank(alice);
        t.transfer(carol, aliceBal);
        uint256 aliceBefore = t.claimable(alice);
        buy(bob, t, 500e18);
        assertEq(t.claimable(alice), aliceBefore);
        assertGt(t.claimable(carol), 0);

        // claim pays native USDC
        uint256 pre = alice.balance;
        vm.prank(alice);
        uint256 got = t.claim();
        assertEq(got, aliceBefore);
        assertEq(alice.balance - pre, aliceBefore);
        assertEq(t.claimable(alice), 0);
        vm.expectRevert(YeetToken.NothingToClaim.selector);
        vm.prank(alice);
        t.claim();
    }

    function test_sellerDoesNotEarnOnOwnSale() public {
        buy(alice, t, 1_000e18);
        buy(bob, t, 1_000e18);
        uint256 bobBefore = t.claimable(bob);
        uint256 aliceBefore = t.claimable(alice);
        sell(bob, t, t.balanceOf(bob));
        assertEq(t.claimable(bob), bobBefore); // no share of his own sale's dividend
        assertGt(t.claimable(alice), aliceBefore); // alice got all of it
    }

    function test_zeroTaxTokenIsPlain() public {
        YeetToken z = create(alice, 0, 0, 0);
        buy(alice, z, 1_000e18);
        assertEq(z.claimable(alice), 0);
        assertEq(z.totalDividends(), 0);
        assertEq(z.eligibleSupply(), 0); // ledger untouched
    }

    function testFuzz_ledgerConservation(uint96 a, uint96 b, uint96 c) public {
        uint256 ua = bound(a, 1e18, 3_000e18);
        uint256 ub = bound(b, 1e18, 3_000e18);
        uint256 uc = bound(c, 1e18, 3_000e18);
        buy(alice, t, ua);
        buy(bob, t, ub);
        buy(carol, t, uc);
        sell(bob, t, t.balanceOf(bob) / 2);
        uint256 sumClaimable = t.claimable(alice) + t.claimable(bob) + t.claimable(carol);
        // all dividends are attributable to holders, up to rounding dust
        assertLe(sumClaimable, t.totalDividends());
        assertApproxEqAbs(sumClaimable, t.totalDividends(), 1e6);
        assertEq(address(t).balance, t.totalDividends() - t.totalClaimed());
        assertEq(t.eligibleSupply(), t.balanceOf(alice) + t.balanceOf(bob) + t.balanceOf(carol));
    }
}
