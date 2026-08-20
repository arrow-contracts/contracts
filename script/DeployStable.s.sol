// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArrowFactoryStable} from "../src/ArrowFactoryStable.sol";
import {TokenDeployer} from "../src/deployers/TokenDeployer.sol";
import {CurveDeployerStable} from "../src/deployers/CurveDeployerStable.sol";

/// Deploys TokenDeployer, CurveDeployerStable, then ArrowFactoryStable wired to both.
/// Reads PLATFORM_OWNER, UNISWAP_ROUTER, QUOTE_TOKEN, VIRTUAL_QUOTE, MIGRATION_THRESHOLD
/// from the environment so this same script works on any stablecoin-quoted chain.
contract DeployStable is Script {
    function run() external returns (ArrowFactoryStable factory) {
        address owner = vm.envAddress("PLATFORM_OWNER");
        address router = vm.envAddress("UNISWAP_ROUTER");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");
        uint256 virtualQuote = vm.envUint("VIRTUAL_QUOTE");
        uint256 migrationThreshold = vm.envUint("MIGRATION_THRESHOLD");

        vm.startBroadcast();
        TokenDeployer tokenDeployer = new TokenDeployer();
        CurveDeployerStable curveDeployer = new CurveDeployerStable();
        factory = new ArrowFactoryStable(
            owner, router, quoteToken, virtualQuote, migrationThreshold,
            address(tokenDeployer), address(curveDeployer)
        );
        vm.stopBroadcast();

        console.log("TokenDeployer deployed at:", address(tokenDeployer));
        console.log("CurveDeployerStable deployed at:", address(curveDeployer));
        console.log("ArrowFactoryStable deployed at:", address(factory));
        console.log("  owner:", owner);
        console.log("  quoteToken:", quoteToken);
        console.log("  virtualQuote:", virtualQuote);
        console.log("  migrationThreshold:", migrationThreshold);
    }
}
