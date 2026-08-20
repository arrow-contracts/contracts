// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {ArrowTokenClone} from "./ArrowTokenClone.sol";
import {ArrowBondingCurveCloneStable} from "./ArrowBondingCurveCloneStable.sol";

/// @title ArrowFactoryStableClone
/// @notice Same role as ArrowFactoryStable, for Tempo specifically: instead of a full
///         `new ArrowToken(...)` / `new ArrowBondingCurveStable(...)` per launch (which
///         Tempo's transaction validation rejects — see TokenDeployer's docs), this
///         factory clones two shared implementation contracts (EIP-1167 minimal
///         proxies) and initializes them. No deployer-split contracts needed: cloning
///         doesn't embed the implementations' bytecode, so there's nothing here at risk
///         of the EIP-170 size limit either.
contract ArrowFactoryStableClone {
    using SafeERC20 for IERC20;

    address public owner;
    address public platformFeeRecipient;
    address public immutable uniswapRouter;
    address public immutable quoteToken;
    uint256 public immutable virtualQuote;
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
        address quoteToken_,
        uint256 virtualQuote_,
        uint256 migrationThreshold_,
        address tokenImplementation_,
        address curveImplementation_
    ) {
        require(
            owner_ != address(0) && uniswapRouter_ != address(0) && quoteToken_ != address(0)
                && tokenImplementation_ != address(0) && curveImplementation_ != address(0),
            "zero address"
        );
        owner = owner_;
        platformFeeRecipient = owner_;
        uniswapRouter = uniswapRouter_;
        quoteToken = quoteToken_;
        virtualQuote = virtualQuote_;
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
    /// @param firstBuyQuoteAmount optional first buy, in quote-token units — caller
    ///        must have approved this factory for at least this amount beforehand
    /// @param minTokensOut slippage floor for the optional first buy
    function createTokenAndBuy(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint256 firstBuyQuoteAmount,
        uint256 minTokensOut
    ) external returns (address token, address curve) {
        curve = Clones.clone(curveImplementation);
        token = Clones.clone(tokenImplementation);

        ArrowTokenClone(token).initialize(name, symbol, address(this), curve, msg.sender, metadataURI);
        ArrowBondingCurveCloneStable(curve).initialize(
            address(this), msg.sender, uniswapRouter, quoteToken, virtualQuote, migrationThreshold, token
        );

        allTokens.push(token);
        curveOf[token] = curve;
        emit TokenLaunched(token, curve, msg.sender, name, symbol, metadataURI);

        if (firstBuyQuoteAmount > 0) {
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), firstBuyQuoteAmount);
            IERC20(quoteToken).forceApprove(curve, firstBuyQuoteAmount);
            ArrowBondingCurveCloneStable(curve).buy(msg.sender, firstBuyQuoteAmount, minTokensOut);
        }
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Claims a token's accrued platform fees on behalf of whoever is
    ///         currently platformFeeRecipient. Tempo-specific: the token itself makes
    ///         no external call back to this factory (see ArrowTokenClone docs), so
    ///         this authorization check happens here instead, then reaches into the
    ///         token via an onlyFactory-gated function.
    function claimPlatformFeesFor(address token) external returns (uint256 amount) {
        require(msg.sender == platformFeeRecipient, "not platform recipient");
        amount = ArrowTokenClone(token).claimPlatformFeesTo(msg.sender);
    }

    /// @notice CTO override for abandoned tokens — same inversion as above.
    function reassignCreatorFeeRecipient(address token, address newRecipient) external onlyOwner {
        ArrowTokenClone(token).setCreatorFeeRecipientByFactory(newRecipient);
    }
}
