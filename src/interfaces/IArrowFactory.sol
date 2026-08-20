// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IArrowFactory {
    function owner() external view returns (address);
    function platformFeeRecipient() external view returns (address);
}
