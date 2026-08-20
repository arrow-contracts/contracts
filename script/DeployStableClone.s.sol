// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArrowFactoryStableClone} from "../src/tempo/ArrowFactoryStableClone.sol";
import {ArrowTokenClone} from "../src/tempo/ArrowTokenClone.sol";
import {ArrowBondingCurveCloneStable} from "../src/tempo/ArrowBondingCurveCloneStable.sol";

/// Deploys the two shared clone implementations, then ArrowFactoryStableClone wired
/// to both. Reads PLATFORM_OWNER, UNISWAP_ROUTER, QUOTE_TOKEN, VIRTUAL_QUOTE,
/// MIGRATION_THRESHOLD from the environment, same as DeployStable.s.sol.
contract DeployStableClone is Script {
    function run() external returns (ArrowFactoryStableClone factory) {
        address owner = vm.envAddress("PLATFORM_OWNER");
        address router = vm.envAddress("UNISWAP_ROUTER");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");
        uint256 virtualQuote = vm.envUint("VIRTUAL_QUOTE");
        uint256 migrationThreshold = vm.envUint("MIGRATION_THRESHOLD");

        vm.startBroadcast();
        ArrowTokenClone tokenImpl = new ArrowTokenClone();
        ArrowBondingCurveCloneStable curveImpl = new ArrowBondingCurveCloneStable();
        factory = new ArrowFactoryStableClone(
            owner, router, quoteToken, virtualQuote, migrationThreshold,
            address(tokenImpl), address(curveImpl)
        );
        vm.stopBroadcast();

        console.log("ArrowTokenClone implementation deployed at:", address(tokenImpl));
        console.log("ArrowBondingCurveCloneStable implementation deployed at:", address(curveImpl));
        console.log("ArrowFactoryStableClone deployed at:", address(factory));
        console.log("  owner:", owner);
        console.log("  quoteToken:", quoteToken);
        console.log("  virtualQuote:", virtualQuote);
        console.log("  migrationThreshold:", migrationThreshold);
    }
}
