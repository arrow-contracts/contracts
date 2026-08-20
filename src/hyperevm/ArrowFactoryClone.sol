// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ArrowTokenClone} from "../tempo/ArrowTokenClone.sol";
import {ArrowBondingCurveClone} from "./ArrowBondingCurveClone.sol";

/// @title ArrowFactoryClone
/// @notice Same role as ArrowFactory (native-quote), for HyperEVM specifically: instead
///         of a full `new ArrowToken(...)` / `new ArrowBondingCurve(...)` per launch —
///         which measured at 3,029,241 gas against the original from-scratch factory,
///         just over HyperEVM's 3,000,000 block gas limit, so no launch could ever be
///         mined — this factory clones two shared implementation contracts (EIP-1167
///         minimal proxies) and initializes them, the same technique already proven on
///         Tempo (for an unrelated reason — see ArrowFactoryStableClone).
contract ArrowFactoryClone {
    address public owner;
    address public platformFeeRecipient;
    address public immutable uniswapRouter;
    uint256 public immutable virtualEth;
    uint256 public immutable migrationThreshold;
    address public immutable tokenImplementation;
    address public immutable curveImplementation;

    address[] public allTokens;
    mapping(address => address) public curveOf;

    event TokenLaunched(
        address indexed token,
        address indexed curve,
        address indexed creator,
        string name,
        string symbol,
        string metadataURI
    );
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event PlatformFeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(
        address owner_,
        address uniswapRouter_,
        uint256 virtualEth_,
        uint256 migrationThreshold_,
        address tokenImplementation_,
        address curveImplementation_
    ) {
        require(
            owner_ != address(0) && uniswapRouter_ != address(0) && tokenImplementation_ != address(0)
                && curveImplementation_ != address(0),
            "zero address"
        );
        owner = owner_;
        platformFeeRecipient = owner_;
        uniswapRouter = uniswapRouter_;
        virtualEth = virtualEth_;
        migrationThreshold = migrationThreshold_;
        tokenImplementation = tokenImplementation_;
        curveImplementation = curveImplementation_;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setPlatformFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "zero address");
        emit PlatformFeeRecipientChanged(platformFeeRecipient, newRecipient);
        platformFeeRecipient = newRecipient;
    }

    /// @param name token name
    /// @param symbol token symbol
    /// @param metadataURI ipfs:// URI of a JSON blob with logo/description/socials
    /// @param minTokensOut slippage floor for the optional first buy (0 if msg.value == 0)
    function createTokenAndBuy(string calldata name, string calldata symbol, string calldata metadataURI, uint256 minTokensOut)
        external
        payable
        returns (address token, address curve)
    {
        curve = Clones.clone(curveImplementation);
        token = Clones.clone(tokenImplementation);

        ArrowTokenClone(token).initialize(name, symbol, address(this), curve, msg.sender, metadataURI);
        ArrowBondingCurveClone(curve).initialize(address(this), msg.sender, uniswapRouter, virtualEth, migrationThreshold, token);

        allTokens.push(token);
        curveOf[token] = curve;
        emit TokenLaunched(token, curve, msg.sender, name, symbol, metadataURI);

        if (msg.value > 0) {
            ArrowBondingCurveClone(curve).buy{value: msg.value}(msg.sender, minTokensOut);
        }
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Claims a token's accrued platform fees on behalf of whoever is
    ///         currently platformFeeRecipient — same inversion as
    ///         ArrowFactoryStableClone.claimPlatformFeesFor (ArrowTokenClone never
    ///         calls back into the factory itself).
    function claimPlatformFeesFor(address token) external returns (uint256 amount) {
        require(msg.sender == platformFeeRecipient, "not platform recipient");
        amount = ArrowTokenClone(token).claimPlatformFeesTo(msg.sender);
    }

    /// @notice CTO override for abandoned tokens — same inversion as above.
    function reassignCreatorFeeRecipient(address token, address newRecipient) external onlyOwner {
        ArrowTokenClone(token).setCreatorFeeRecipientByFactory(newRecipient);
    }
}
