// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ArrowBondingCurveStable} from "./ArrowBondingCurveStable.sol";

interface ITokenDeployer {
    function deploy(
        string calldata name,
        string calldata symbol,
        address factory,
        address curve,
        address creator,
        string calldata metadataURI
    ) external returns (address);
}

interface ICurveDeployerStable {
    function deploy(
        address factory,
        address creator,
        address router,
        address quoteToken,
        uint256 virtualQuote,
        uint256 migrationThreshold
    ) external returns (address);
}

/// @title ArrowFactoryStable
/// @notice Same role as ArrowFactory, for chains whose bonding curves quote in an ERC20
///         stablecoin instead of native ETH (no payable, no msg.value — the first buy
///         is pulled via transferFrom, same as every other buy).
contract ArrowFactoryStable {
    using SafeERC20 for IERC20;

    address public owner;
    address public platformFeeRecipient;
    address public immutable uniswapRouter;
    address public immutable quoteToken;
    uint256 public immutable virtualQuote;
    uint256 public immutable migrationThreshold;
    ITokenDeployer public immutable tokenDeployer;
    ICurveDeployerStable public immutable curveDeployer;

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
        address tokenDeployer_,
        address curveDeployer_
    ) {
        require(
            owner_ != address(0) && uniswapRouter_ != address(0) && quoteToken_ != address(0)
                && tokenDeployer_ != address(0) && curveDeployer_ != address(0),
            "zero address"
        );
        owner = owner_;
        platformFeeRecipient = owner_;
        uniswapRouter = uniswapRouter_;
        quoteToken = quoteToken_;
        virtualQuote = virtualQuote_;
        migrationThreshold = migrationThreshold_;
        tokenDeployer = ITokenDeployer(tokenDeployer_);
        curveDeployer = ICurveDeployerStable(curveDeployer_);
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
        curve = curveDeployer.deploy(address(this), msg.sender, uniswapRouter, quoteToken, virtualQuote, migrationThreshold);
        token = tokenDeployer.deploy(name, symbol, address(this), curve, msg.sender, metadataURI);
        ArrowBondingCurveStable(curve).initialize(token);

        allTokens.push(token);
        curveOf[token] = curve;
        emit TokenLaunched(token, curve, msg.sender, name, symbol, metadataURI);

        if (firstBuyQuoteAmount > 0) {
            IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), firstBuyQuoteAmount);
            IERC20(quoteToken).forceApprove(curve, firstBuyQuoteAmount);
            ArrowBondingCurveStable(curve).buy(msg.sender, firstBuyQuoteAmount, minTokensOut);
        }
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }
}
