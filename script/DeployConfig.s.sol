// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArrowFactoryConfig} from "../src/ArrowFactoryConfig.sol";
import {TokenDeployer} from "../src/deployers/TokenDeployer.sol";
import {CurveDeployerConfig} from "../src/deployers/CurveDeployerConfig.sol";

/// Deploys TokenDeployer, CurveDeployerConfig, then ArrowFactoryConfig wired to both.
/// Reads PLATFORM_OWNER, UNISWAP_ROUTER, VIRTUAL_ETH, MIGRATION_THRESHOLD from the
/// environment — same shape as Deploy.s.sol, plus the two threshold params that
/// ArrowFactory.sol hardcodes as constants on ArrowBondingCurve itself.
contract DeployConfig is Script {
    function run() external returns (ArrowFactoryConfig factory) {
        address owner = vm.envAddress("PLATFORM_OWNER");
        address router = vm.envAddress("UNISWAP_ROUTER");
        uint256 virtualEth = vm.envUint("VIRTUAL_ETH");
        uint256 migrationThreshold = vm.envUint("MIGRATION_THRESHOLD");

        vm.startBroadcast();
        TokenDeployer tokenDeployer = new TokenDeployer();
        CurveDeployerConfig curveDeployer = new CurveDeployerConfig();
        factory = new ArrowFactoryConfig(
            owner, router, virtualEth, migrationThreshold, address(tokenDeployer), address(curveDeployer)
        );
        vm.stopBroadcast();

        console.log("TokenDeployer deployed at:", address(tokenDeployer));
        console.log("CurveDeployerConfig deployed at:", address(curveDeployer));
        console.log("ArrowFactoryConfig deployed at:", address(factory));
        console.log("  owner:", owner);
        console.log("  uniswapRouter:", router);
        console.log("  virtualEth:", virtualEth);
        console.log("  migrationThreshold:", migrationThreshold);
    }
}
