// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {YeetLaunchpad} from "../src/YeetLaunchpad.sol";
import {YeetHook} from "../src/YeetHook.sol";
import {YeetGraduator} from "../src/YeetGraduator.sol";
import {YeetRouter} from "../src/YeetRouter.sol";
import {YeetBuyback} from "../src/YeetBuyback.sol";
import {HookMiner} from "./HookMiner.sol";

/// Usage:
///   source ../yeet-devops/secrets.env
///   forge script script/Deploy.s.sol --rpc-url $ARC_TESTNET_RPC --broadcast --slow --gas-estimate-multiplier 300
/// Env:
///   DEPLOYER_PRIVATE_KEY   required
///   OWNER                  optional, defaults to deployer (set to the hardware wallet for mainnet)
///   POOL_MANAGER           optional; if unset and chain is Arc testnet we deploy v4-core's PoolManager
///   CURVE_V_USDC0          optional, default 3500e18
///   CURVE_TARGET           optional, default 10000e18   (testnet "lite" stack: 3.5e18 / 10e18)
///   DEPLOYMENT_SUFFIX      optional, e.g. "-lite" -> deployments/5042002-lite.json
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 constant ARC_TESTNET = 5042002;

    struct Deployed {
        address launchpad;
        address hook;
        address graduator;
        address router;
        address buyback;
        address poolManager;
        address owner;
        address deployer;
        bytes32 salt;
        uint256 vUsdc0;
        uint256 target;
    }

    Deployed d; // storage to keep run() under the stack limit

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        d.deployer = vm.addr(pk);
        d.owner = vm.envOr("OWNER", d.deployer);
        d.poolManager = vm.envOr("POOL_MANAGER", address(0));
        d.vUsdc0 = vm.envOr("CURVE_V_USDC0", uint256(3_500e18));
        d.target = vm.envOr("CURVE_TARGET", uint256(10_000e18));
        string memory suffix = vm.envOr("DEPLOYMENT_SUFFIX", string(""));

        console.log("chain", block.chainid, "deployer", d.deployer);
        console.log("owner", d.owner);
        console.log("curve vUsdc0 / target", d.vUsdc0, d.target);

        vm.startBroadcast(pk);

        if (d.poolManager == address(0)) {
            require(block.chainid == ARC_TESTNET, "POOL_MANAGER required on this chain");
            d.poolManager = address(new PoolManager(d.owner));
            console.log("PoolManager (self-deployed)", d.poolManager);
        } else {
            require(d.poolManager.code.length > 0, "POOL_MANAGER has no code");
            console.log("PoolManager (existing)", d.poolManager);
        }
        IPoolManager pm = IPoolManager(d.poolManager);

        YeetLaunchpad launchpad = new YeetLaunchpad(d.owner, d.vUsdc0, d.target);
        d.launchpad = address(launchpad);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(YeetHook).creationCode, abi.encode(pm, d.deployer));
        YeetHook hook = new YeetHook{salt: salt}(pm, d.deployer); // owner = deployer until wiring is done
        require(address(hook) == predicted, "hook address mismatch");
        d.hook = address(hook);
        d.salt = salt;

        YeetGraduator graduator = new YeetGraduator(pm, hook, d.launchpad);
        d.graduator = address(graduator);
        d.router = address(new YeetRouter(pm, hook));
        YeetBuyback buyback = new YeetBuyback(pm, d.hook, d.launchpad, d.owner);
        d.buyback = address(buyback);

        hook.setGraduator(d.graduator);
        hook.setBuyback(d.buyback);
        if (d.owner != d.deployer) hook.transferOwnership(d.owner); // owner must acceptOwnership()
        if (d.owner == d.deployer) launchpad.initialize(d.graduator, d.hook, d.poolManager, d.buyback);

        vm.stopBroadcast();

        _write(suffix);
        if (d.owner != d.deployer) {
            console.log("ACTION: owner must call launchpad.initialize(graduator, hook, poolManager, buyback), hook.acceptOwnership(), buyback.acceptOwnership()");
        }
    }

    function _write(string memory suffix) internal {
        string memory j = "deployments";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "launchpad", d.launchpad);
        vm.serializeAddress(j, "hook", d.hook);
        vm.serializeAddress(j, "graduator", d.graduator);
        vm.serializeAddress(j, "router", d.router);
        vm.serializeAddress(j, "buyback", d.buyback);
        vm.serializeAddress(j, "poolManager", d.poolManager);
        vm.serializeAddress(j, "usdc", USDC);
        vm.serializeAddress(j, "owner", d.owner);
        vm.serializeAddress(j, "deployer", d.deployer);
        vm.serializeUint(j, "deployBlock", block.number);
        vm.serializeUint(j, "curveVUsdc0", d.vUsdc0);
        vm.serializeUint(j, "curveTarget", d.target);
        vm.serializeBytes32(j, "hookSalt", d.salt);
        string memory out = vm.serializeUint(j, "timestamp", block.timestamp);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), suffix, ".json");
        vm.writeJson(out, path);
        console.log("wrote", path);
        console.log("launchpad", d.launchpad);
        console.log("hook", d.hook);
        console.log("graduator", d.graduator);
        console.log("router", d.router);
        console.log("buyback", d.buyback);
    }
}
