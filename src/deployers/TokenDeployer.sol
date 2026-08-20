// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArrowToken} from "../ArrowToken.sol";

/// @notice Split out of ArrowFactory purely to dodge EIP-170: a contract that calls
///         `new ArrowToken(...)` directly embeds ArrowToken's full creation bytecode,
///         and ArrowFactory already carries ArrowBondingCurve's too — together that's
///         over the 24576-byte limit. Isolating each `new` in its own tiny contract
///         keeps every deployed contract under the limit.
contract TokenDeployer {
    function deploy(
        string calldata name,
        string calldata symbol,
        address factory,
        address curve,
        address creator,
        string calldata metadataURI
    ) external returns (address) {
        return address(new ArrowToken(name, symbol, factory, curve, creator, metadataURI));
    }
}
