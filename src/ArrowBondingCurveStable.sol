// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ArrowToken} from "./ArrowToken.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";

/// @title ArrowBondingCurveStable
/// @notice Same mechanics as ArrowBondingCurve, but the "money" side of the curve is
///         an ERC20 stablecoin instead of native ETH — for chains like Tempo that have
///         no native gas/value token at all. Buy/sell pull and push the quote token via
///         transferFrom/transfer instead of payable/call{value}; migration pairs the
///         launched token against the quote token on Uniswap V2 (addLiquidity, not
///         addLiquidityETH) and burns the LP exactly the same way.
contract ArrowBondingCurveStable is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev In the quote token's own decimals (6 for the USD stablecoins on Tempo),
    ///      not 18 — set per-deployment via the factory, not hardcoded, since a future
    ///      chain's stablecoin might use different decimals.
    uint256 public immutable MIGRATION_THRESHOLD;
    uint256 public immutable VIRTUAL_QUOTE;

    address public immutable factory;
    address public immutable creator;
    IERC20 public immutable quoteToken;
    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory public immutable uniFactory;

    ArrowToken public token;
    uint256 public k; // (VIRTUAL_QUOTE + quoteReserve) * tokenReserve
    uint256 public tokenReserve;
    uint256 public quoteReserve;
    bool public migrated;
    address public pair;

    event Buy(address indexed buyer, uint256 quoteIn, uint256 tokensOut);
    event Sell(address indexed seller, uint256 tokensIn, uint256 quoteOut);
    event Migrated(address indexed pair, uint256 quoteLiquidity, uint256 tokenLiquidity, uint256 lpBurned);

    modifier onlyFactory() {
        require(msg.sender == factory, "not factory");
        _;
    }

    constructor(
        address factory_,
        address creator_,
        address router_,
        address quoteToken_,
        uint256 virtualQuote_,
        uint256 migrationThreshold_
    ) {
        factory = factory_;
        creator = creator_;
        router = IUniswapV2Router02(router_);
        uniFactory = IUniswapV2Factory(router.factory());
        quoteToken = IERC20(quoteToken_);
        VIRTUAL_QUOTE = virtualQuote_;
        MIGRATION_THRESHOLD = migrationThreshold_;
    }

    function initialize(address token_) external onlyFactory {
        require(address(token) == address(0), "already initialized");
        token = ArrowToken(token_);
        tokenReserve = ArrowToken(token_).TOTAL_SUPPLY();
        k = VIRTUAL_QUOTE * tokenReserve;
    }

    function buy(address recipient, uint256 quoteAmountIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        require(!migrated, "migrated");
        require(quoteAmountIn > 0, "no quote sent");

        quoteToken.safeTransferFrom(msg.sender, address(this), quoteAmountIn);

        uint256 newQuoteReserve = quoteReserve + quoteAmountIn;
        uint256 newTokenReserve = k / (VIRTUAL_QUOTE + newQuoteReserve);
        tokensOut = tokenReserve - newTokenReserve;
        require(tokensOut > 0 && tokensOut <= tokenReserve, "bad curve state");
        require(tokensOut >= minTokensOut, "slippage");

        quoteReserve = newQuoteReserve;
        tokenReserve = newTokenReserve;

        IERC20(address(token)).safeTransfer(recipient, tokensOut);
        emit Buy(recipient, quoteAmountIn, tokensOut);

        if (quoteToken.balanceOf(address(this)) >= MIGRATION_THRESHOLD) {
            _migrate();
        }
    }

    function sell(uint256 tokenAmount, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        require(!migrated, "migrated");
        require(tokenAmount > 0, "zero amount");

        uint256 balBefore = token.balanceOf(address(this));
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 received = token.balanceOf(address(this)) - balBefore;

        uint256 newTokenReserve = tokenReserve + received;
        uint256 newQuoteReserve = k / newTokenReserve - VIRTUAL_QUOTE;
        quoteOut = quoteReserve - newQuoteReserve;
        require(quoteOut > 0 && quoteOut <= quoteReserve, "bad curve state");
        require(quoteOut >= minQuoteOut, "slippage");

        tokenReserve = newTokenReserve;
        quoteReserve = newQuoteReserve;

        quoteToken.safeTransfer(msg.sender, quoteOut);
        emit Sell(msg.sender, tokenAmount, quoteOut);
    }

    function _migrate() internal {
        migrated = true;

        uint256 tokensForLiquidity = token.balanceOf(address(this));
        uint256 quoteForLiquidity = quoteToken.balanceOf(address(this));

        token.setMigrating(true);
        IERC20(address(token)).forceApprove(address(router), tokensForLiquidity);
        quoteToken.forceApprove(address(router), quoteForLiquidity);
        (,, uint256 liquidity) = router.addLiquidity(
            address(token), address(quoteToken), tokensForLiquidity, quoteForLiquidity, 0, 0, address(this), block.timestamp
        );
        token.setMigrating(false);

        pair = uniFactory.getPair(address(token), address(quoteToken));
        token.setCapExempt(pair, true);

        IERC20(pair).safeTransfer(address(0xdead), liquidity);

        emit Migrated(pair, quoteForLiquidity, tokensForLiquidity, liquidity);
    }
}
