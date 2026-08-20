// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArrowBondingCurve} from "../ArrowBondingCurve.sol";

/// @notice See TokenDeployer — same reasoning, other contract.
contract CurveDeployer {
    function deploy(address factory, address creator, address router) external returns (address) {
        return address(new ArrowBondingCurve(factory, creator, router));
    }
}
