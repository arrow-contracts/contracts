// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArrowBondingCurveConfig} from "./ArrowBondingCurveConfig.sol";

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

interface ICurveDeployerConfig {
    function deploy(address factory, address creator, address router, uint256 virtualEth, uint256 migrationThreshold)
        external
        returns (address);
}

/// @title ArrowFactoryConfig
/// @notice Same role as ArrowFactory, except virtualEth/migrationThreshold are set once
///         at construction and passed through to every curve it launches, instead of
///         each curve hardcoding "1 ether"/"4 ether". Built for chains whose native
///         token isn't worth thousands of dollars a unit (see ArrowBondingCurveConfig's
///         docs) — same fixed rules otherwise (2% tax, 3% cap, 30s shield, LP burn).
contract ArrowFactoryConfig {
    address public owner;
    address public platformFeeRecipient;
    address public immutable uniswapRouter;
    uint256 public immutable virtualEth;
    uint256 public immutable migrationThreshold;
    ITokenDeployer public immutable tokenDeployer;
    ICurveDeployerConfig public immutable curveDeployer;

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
        address tokenDeployer_,
        address curveDeployer_
    ) {
        require(
            owner_ != address(0) && uniswapRouter_ != address(0) && tokenDeployer_ != address(0)
                && curveDeployer_ != address(0),
            "zero address"
        );
        owner = owner_;
        platformFeeRecipient = owner_;
        uniswapRouter = uniswapRouter_;
        virtualEth = virtualEth_;
        migrationThreshold = migrationThreshold_;
        tokenDeployer = ITokenDeployer(tokenDeployer_);
        curveDeployer = ICurveDeployerConfig(curveDeployer_);
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

    function createTokenAndBuy(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint256 minTokensOut
    ) external payable returns (address token, address curve) {
        curve = curveDeployer.deploy(address(this), msg.sender, uniswapRouter, virtualEth, migrationThreshold);
        token = tokenDeployer.deploy(name, symbol, address(this), curve, msg.sender, metadataURI);
        ArrowBondingCurveConfig(curve).initialize(token);

        allTokens.push(token);
        curveOf[token] = curve;
        emit TokenLaunched(token, curve, msg.sender, name, symbol, metadataURI);

        if (msg.value > 0) {
            ArrowBondingCurveConfig(curve).buy{value: msg.value}(msg.sender, minTokensOut);
        }
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }
}
