// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ArrowBondingCurve} from "../src/ArrowBondingCurve.sol";

/// Dry-run only: simulates many distinct wallets buying small amounts until the
/// curve migrates, to exercise the full migration path against a local Anvil fork.
/// Not meant for real deployments.
contract Swarm is Script {
    function run() external {
        address curveAddr = vm.envAddress("CURVE");
        ArrowBondingCurve curve = ArrowBondingCurve(curveAddr);

        for (uint256 i = 0; i < 250 && !curve.migrated(); i++) {
            uint256 pk = uint256(keccak256(abi.encode("swarm-dry-run", i)));
            address who = vm.addr(pk);
            vm.deal(who, 1 ether);
            vm.broadcast(pk);
            curve.buy{value: 0.02 ether}(who, 0);
        }

        console.log("migrated:", curve.migrated());
        console.log("eth reserve:", curve.ethReserve());
        console.log("pair:", curve.pair());
    }
}
