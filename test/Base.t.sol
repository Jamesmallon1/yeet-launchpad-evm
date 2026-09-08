// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {YeetLaunchpad} from "../src/YeetLaunchpad.sol";
import {YeetToken} from "../src/YeetToken.sol";
import {YeetHook} from "../src/YeetHook.sol";
import {YeetGraduator} from "../src/YeetGraduator.sol";
import {YeetRouter} from "../src/YeetRouter.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

contract BaseTest is Test {
    uint256 constant BPS = 10_000;
    CurveMath.Params P;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    IPoolManager pm;
    YeetLaunchpad launchpad;
    YeetHook hook;
    YeetGraduator graduator;
    YeetRouter router;

    function setUp() public virtual {
        pm = new PoolManager(owner);
        launchpad = new YeetLaunchpad(owner, 3_500e18, 10_000e18);
        P = launchpad.curveParams();

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address hookAddr = address(uint160(0x4444 << 144) | flags);
        deployCodeTo("YeetHook.sol:YeetHook", abi.encode(pm, owner), hookAddr);
        hook = YeetHook(payable(hookAddr));

        graduator = new YeetGraduator(pm, hook, address(launchpad));
        router = new YeetRouter(pm, hook);

        vm.startPrank(owner);
        hook.setGraduator(address(graduator));
        launchpad.initialize(address(graduator), address(hook), address(pm));
        vm.stopPrank();

        vm.deal(alice, 100_000e18);
        vm.deal(bob, 100_000e18);
        vm.deal(carol, 100_000e18);
    }

    function create(address creator, uint16 taxBps, uint16 devBuyBps, uint256 value) internal returns (YeetToken t) {
        vm.prank(creator);
        t = YeetToken(launchpad.createToken{value: value}("Yeet Cat", "YCAT", "ipfs://meta", taxBps, devBuyBps));
    }

    function buy(address who, YeetToken t, uint256 usdc) internal returns (uint256 out) {
        vm.prank(who);
        out = launchpad.buy{value: usdc}(address(t), 0);
    }

    function sell(address who, YeetToken t, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        t.approve(address(launchpad), amount);
        out = launchpad.sell(address(t), amount, 0);
        vm.stopPrank();
    }

    /// buys in chunks until the curve completes (and graduates)
    function completeCurve(YeetToken t) internal {
        for (uint256 i; i < 50; ++i) {
            (,,, bool complete,,,,) = launchpad.curves(address(t));
            if (complete) return;
            buy(carol, t, 2_000e18);
        }
    }

    function curve(YeetToken t) internal view returns (YeetLaunchpad.Curve memory c) {
        (c.realUsdc, c.tokensSold, c.taxBps, c.complete, c.graduated, c.creator, c.createdAt, c.poolId) =
            launchpad.curves(address(t));
    }
}
