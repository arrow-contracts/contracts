// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArrowFactoryClone} from "../src/hyperevm/ArrowFactoryClone.sol";
import {ArrowTokenClone} from "../src/tempo/ArrowTokenClone.sol";
import {ArrowBondingCurveClone} from "../src/hyperevm/ArrowBondingCurveClone.sol";

/// Deploys the two shared clone implementations, then ArrowFactoryClone wired to both.
/// Reads PLATFORM_OWNER, UNISWAP_ROUTER, VIRTUAL_ETH, MIGRATION_THRESHOLD from the
/// environment, same shape as DeployStableClone.s.sol but native-quote (no QUOTE_TOKEN).
contract DeployClone is Script {
    function run() external returns (ArrowFactoryClone factory) {
        address owner = vm.envAddress("PLATFORM_OWNER");
        address router = vm.envAddress("UNISWAP_ROUTER");
        uint256 virtualEth = vm.envUint("VIRTUAL_ETH");
        uint256 migrationThreshold = vm.envUint("MIGRATION_THRESHOLD");

        vm.startBroadcast();
        ArrowTokenClone tokenImpl = new ArrowTokenClone();
        ArrowBondingCurveClone curveImpl = new ArrowBondingCurveClone();
        factory = new ArrowFactoryClone(owner, router, virtualEth, migrationThreshold, address(tokenImpl), address(curveImpl));
        vm.stopBroadcast();

        console.log("ArrowTokenClone implementation deployed at:", address(tokenImpl));
        console.log("ArrowBondingCurveClone implementation deployed at:", address(curveImpl));
        console.log("ArrowFactoryClone deployed at:", address(factory));
        console.log("  owner:", owner);
        console.log("  uniswapRouter:", router);
        console.log("  virtualEth:", virtualEth);
        console.log("  migrationThreshold:", migrationThreshold);
    }
}
