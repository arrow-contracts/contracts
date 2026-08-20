// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ArrowBondingCurve} from "./ArrowBondingCurve.sol";

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

interface ICurveDeployer {
    function deploy(address factory, address creator, address router) external returns (address);
}

/// @title ArrowFactory
/// @notice Launches a token + bonding curve pair in one atomic transaction (optionally
///         with the creator's first buy folded in, so nobody can front-run the launch
///         itself). Also holds the one platform-wide setting every token defers to:
///         who the platform's 1% cut currently pays out to.
/// @dev Delegates the actual `new ArrowToken(...)` / `new ArrowBondingCurve(...)` calls
///      to two small standalone deployer contracts (see src/deployers/). Doing `new`
///      directly here would inline both contracts' full creation bytecode into this
///      one, blowing past the 24576-byte EIP-170 contract size limit.
contract ArrowFactory {
    address public owner;
    address public platformFeeRecipient;
    address public immutable uniswapRouter;
    ITokenDeployer public immutable tokenDeployer;
    ICurveDeployer public immutable curveDeployer;

    address[] public allTokens;
    mapping(address => address) public curveOf; // token => curve

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

    constructor(address owner_, address uniswapRouter_, address tokenDeployer_, address curveDeployer_) {
        require(
            owner_ != address(0) && uniswapRouter_ != address(0) && tokenDeployer_ != address(0)
                && curveDeployer_ != address(0),
            "zero address"
        );
        owner = owner_;
        platformFeeRecipient = owner_;
        uniswapRouter = uniswapRouter_;
        tokenDeployer = ITokenDeployer(tokenDeployer_);
        curveDeployer = ICurveDeployer(curveDeployer_);
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
    function createTokenAndBuy(
        string calldata name,
        string calldata symbol,
        string calldata metadataURI,
        uint256 minTokensOut
    ) external payable returns (address token, address curve) {
        curve = curveDeployer.deploy(address(this), msg.sender, uniswapRouter);
        token = tokenDeployer.deploy(name, symbol, address(this), curve, msg.sender, metadataURI);
        ArrowBondingCurve(curve).initialize(token);

        allTokens.push(token);
        curveOf[token] = curve;
        emit TokenLaunched(token, curve, msg.sender, name, symbol, metadataURI);

        if (msg.value > 0) {
            ArrowBondingCurve(curve).buy{value: msg.value}(msg.sender, minTokensOut);
        }
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }
}
