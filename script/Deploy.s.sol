// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArrowFactory} from "../src/ArrowFactory.sol";
import {TokenDeployer} from "../src/deployers/TokenDeployer.sol";
import {CurveDeployer} from "../src/deployers/CurveDeployer.sol";

/// Deploys TokenDeployer, CurveDeployer, then ArrowFactory wired to both. Reads
/// PLATFORM_OWNER and UNISWAP_ROUTER from the environment so the same script works
/// unmodified against mainnet, a fork, or a future testnet.
contract Deploy is Script {
    function run() external returns (ArrowFactory factory) {
        address owner = vm.envAddress("PLATFORM_OWNER");
        address router = vm.envAddress("UNISWAP_ROUTER");

        vm.startBroadcast();
        TokenDeployer tokenDeployer = new TokenDeployer();
        CurveDeployer curveDeployer = new CurveDeployer();
        factory = new ArrowFactory(owner, router, address(tokenDeployer), address(curveDeployer));
        vm.stopBroadcast();

        console.log("TokenDeployer deployed at:", address(tokenDeployer));
        console.log("CurveDeployer deployed at:", address(curveDeployer));
        console.log("ArrowFactory deployed at:", address(factory));
        console.log("  owner:", owner);
        console.log("  platformFeeRecipient:", factory.platformFeeRecipient());
        console.log("  uniswapRouter:", router);
    }
}
