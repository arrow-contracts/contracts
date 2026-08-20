// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArrowBondingCurveStable} from "../ArrowBondingCurveStable.sol";

/// @notice See TokenDeployer — same EIP-170 size reasoning, stablecoin-curve variant.
contract CurveDeployerStable {
    function deploy(
        address factory,
        address creator,
        address router,
        address quoteToken,
        uint256 virtualQuote,
        uint256 migrationThreshold
    ) external returns (address) {
        return address(new ArrowBondingCurveStable(factory, creator, router, quoteToken, virtualQuote, migrationThreshold));
    }
}
