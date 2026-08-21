// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArrowBondingCurveConfig} from "../ArrowBondingCurveConfig.sol";

/// @notice See TokenDeployer — same reasoning, other contract. Deploys
///         ArrowBondingCurveConfig instead of ArrowBondingCurve, passing through the
///         per-chain virtualEth/migrationThreshold the factory was constructed with.
contract CurveDeployerConfig {
    function deploy(address factory, address creator, address router, uint256 virtualEth, uint256 migrationThreshold)
        external
        returns (address)
    {
        return address(new ArrowBondingCurveConfig(factory, creator, router, virtualEth, migrationThreshold));
    }
}
