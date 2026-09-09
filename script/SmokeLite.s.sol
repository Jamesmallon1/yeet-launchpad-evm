// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {YeetLaunchpad} from "../src/YeetLaunchpad.sol";
import {YeetToken} from "../src/YeetToken.sol";

/// Cheap smoke: create (with dev buy + 60% burn split), one small buy, one small sell. ~1.5 USDC.
contract SmokeLite is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory j = vm.readFile(vm.envOr("DEPLOYMENTS", string("deployments/5042002-lite.json")));
        YeetLaunchpad launchpad = YeetLaunchpad(vm.parseJsonAddress(j, ".launchpad"));
        vm.startBroadcast(pk);
        YeetToken t = YeetToken(launchpad.createToken{value: 0.2e18}("Green Candle", "GREEN", "ipfs://green", 300, 6000, 500));
        console.log("token", address(t), "dev tokens", t.balanceOf(me));
        uint256 got = launchpad.buy{value: 0.5e18}(address(t), 0);
        console.log("bought", got, "snipeTaxBps now", launchpad.snipeTaxBps(address(t)));
        t.approve(address(launchpad), got / 2);
        uint256 usdc = launchpad.sell(address(t), got / 2, 0);
        console.log("sold half for", usdc);
        vm.stopBroadcast();
        YeetLaunchpad.Curve memory c = launchpad.curveOf(address(t));
        console.log("burnedTokens", c.burnedTokens, "burnedUsdc", c.burnedUsdc);
        console.log("holder dividends", t.totalDividends(), "accruedFees", launchpad.accruedFees());
    }
}
