// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {YeetLaunchpad} from "../src/YeetLaunchpad.sol";
import {YeetToken} from "../src/YeetToken.sol";
import {YeetRouter} from "../src/YeetRouter.sol";

/// Lifecycle smoke test against a live deployment (use the -lite stack: 10 USDC graduation).
///   DEPLOYMENTS=deployments/5042002-lite.json forge script script/Smoke.s.sol --rpc-url $ARC_TESTNET_RPC --broadcast --slow
contract Smoke is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory j = vm.readFile(vm.envOr("DEPLOYMENTS", string("deployments/5042002-lite.json")));
        YeetLaunchpad launchpad = YeetLaunchpad(vm.parseJsonAddress(j, ".launchpad"));
        YeetRouter router = YeetRouter(payable(vm.parseJsonAddress(j, ".router")));
        console.log("balance before", me.balance);

        vm.startBroadcast(pk);
        // 1. create with 3% dividends and a 5% dev buy
        uint256 devCost = launchpad.TARGET_USDC() * 2 / 100; // ~1.7% of target buys 5% on this curve; overpay is fine
        YeetToken t = YeetToken(launchpad.createToken{value: devCost}("Smoke Cat", "SMOKE", "ipfs://smoke", 300, 6000, 500));
        console.log("token", address(t), "dev tokens", t.balanceOf(me));

        // 2. sell a slice back
        uint256 slice = t.balanceOf(me) / 4;
        t.approve(address(launchpad), slice);
        uint256 got = launchpad.sell(address(t), slice, 0);
        console.log("sold slice for usdc", got);

        // 3. buy through to completion (graduation is atomic in the final buy)
        for (uint256 i; i < 12; ++i) {
            (,,,, bool complete,,,,,,) = launchpad.curves(address(t));
            if (complete) break;
            launchpad.buy{value: launchpad.TARGET_USDC() / 4}(address(t), 0);
        }
        _checkGraduated(launchpad, address(t));

        // 4. swap on the Uniswap pool through our router, both directions
        uint256 out = router.buy{value: launchpad.TARGET_USDC() / 20}(address(t), 0);
        console.log("router buy tokens", out);
        t.approve(address(router), out / 2);
        uint256 usdc = router.sell(address(t), out / 2, 0);
        console.log("router sell usdc", usdc);

        // 5. dividends accrued from curve + pool trades; claim
        _claim(t);
        vm.stopBroadcast();
        console.log("balance after", me.balance);
    }

    function _checkGraduated(YeetLaunchpad launchpad, address token) internal view {
        (,,,, bool done, bool graduated,,, bytes32 poolId,,) = launchpad.curves(token);
        console.log("complete", done, "graduated", graduated);
        console.logBytes32(poolId);
        require(graduated, "not graduated");
    }

    function _claim(YeetToken t) internal {
        console.log("claimable", t.claimable(msg.sender));
        console.log("totalDividends", t.totalDividends());
        uint256 claimed = t.claim();
        console.log("claimed", claimed);
    }
}
