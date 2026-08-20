// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ArrowToken} from "./ArrowToken.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";

/// @title ArrowBondingCurve
/// @notice Constant-product bonding curve that sells a token's entire supply for ETH.
///         At 4 ETH raised it auto-migrates: whatever tokens and ETH the curve is
///         holding go into a fresh Uniswap V2 pool, and the LP tokens are burned so
///         nobody — not the platform, not the creator — can ever pull the liquidity.
contract ArrowBondingCurve is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIGRATION_THRESHOLD = 4 ether;
    uint256 public constant VIRTUAL_ETH = 1 ether;

    address public immutable factory;
    address public immutable creator;
    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory public immutable uniFactory;

    ArrowToken public token;
    uint256 public k; // constant-product invariant: (VIRTUAL_ETH + ethReserve) * tokenReserve
    uint256 public tokenReserve;
    uint256 public ethReserve;
    bool public migrated;
    address public pair;

    event Buy(address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event Sell(address indexed seller, uint256 tokensIn, uint256 ethOut);
    event Migrated(address indexed pair, uint256 ethLiquidity, uint256 tokenLiquidity, uint256 lpBurned);

    modifier onlyFactory() {
        require(msg.sender == factory, "not factory");
        _;
    }

    constructor(address factory_, address creator_, address router_) {
        factory = factory_;
        creator = creator_;
        router = IUniswapV2Router02(router_);
        uniFactory = IUniswapV2Factory(router.factory());
    }

    /// @dev One-time wiring call from the factory, right after it deploys the token
    ///      (the token needs this curve's address to mint supply into, so the curve
    ///      has to exist first — this closes the loop).
    function initialize(address token_) external onlyFactory {
        require(address(token) == address(0), "already initialized");
        token = ArrowToken(token_);
        tokenReserve = ArrowToken(token_).TOTAL_SUPPLY();
        k = VIRTUAL_ETH * tokenReserve;
    }

    function buy(address recipient, uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        require(!migrated, "migrated");
        require(msg.value > 0, "no eth sent");

        uint256 newEthReserve = ethReserve + msg.value;
        uint256 newTokenReserve = k / (VIRTUAL_ETH + newEthReserve);
        tokensOut = tokenReserve - newTokenReserve;
        require(tokensOut > 0 && tokensOut <= tokenReserve, "bad curve state");
        require(tokensOut >= minTokensOut, "slippage");

        ethReserve = newEthReserve;
        tokenReserve = newTokenReserve;

        IERC20(address(token)).safeTransfer(recipient, tokensOut);
        emit Buy(recipient, msg.value, tokensOut);

        if (address(this).balance >= MIGRATION_THRESHOLD) {
            _migrate();
        }
    }

    function sell(uint256 tokenAmount, uint256 minEthOut) external nonReentrant returns (uint256 ethOut) {
        require(!migrated, "migrated");
        require(tokenAmount > 0, "zero amount");

        uint256 balBefore = token.balanceOf(address(this));
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 received = token.balanceOf(address(this)) - balBefore;

        uint256 newTokenReserve = tokenReserve + received;
        uint256 newEthReserve = k / newTokenReserve - VIRTUAL_ETH;
        ethOut = ethReserve - newEthReserve;
        require(ethOut > 0 && ethOut <= ethReserve, "bad curve state");
        require(ethOut >= minEthOut, "slippage");

        tokenReserve = newTokenReserve;
        ethReserve = newEthReserve;

        (bool ok,) = msg.sender.call{value: ethOut}("");
        require(ok, "eth transfer failed");
        emit Sell(msg.sender, tokenAmount, ethOut);
    }

    function _migrate() internal {
        migrated = true;

        uint256 tokensForLiquidity = token.balanceOf(address(this));
        uint256 ethForLiquidity = address(this).balance;

        token.setMigrating(true);
        IERC20(address(token)).forceApprove(address(router), tokensForLiquidity);
        (,, uint256 liquidity) = router.addLiquidityETH{value: ethForLiquidity}(
            address(token), tokensForLiquidity, 0, 0, address(this), block.timestamp
        );
        token.setMigrating(false);

        pair = uniFactory.getPair(address(token), router.WETH());
        token.setCapExempt(pair, true);

        IERC20(pair).safeTransfer(address(0xdead), liquidity);

        emit Migrated(pair, ethForLiquidity, tokensForLiquidity, liquidity);
    }
}
