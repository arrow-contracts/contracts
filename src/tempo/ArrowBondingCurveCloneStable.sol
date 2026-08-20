// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ArrowTokenClone} from "./ArrowTokenClone.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../interfaces/IUniswapV2.sol";

/// @title ArrowBondingCurveCloneStable
/// @notice Same mechanics as ArrowBondingCurveStable, built for cloning: every field
///         that used to be set once via the constructor is now regular storage set by
///         `initialize`, so this contract can be deployed once as a shared
///         implementation and cheaply cloned (EIP-1167) per token launch — see
///         ArrowTokenClone for why that split exists on Tempo specifically.
contract ArrowBondingCurveCloneStable is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public MIGRATION_THRESHOLD;
    uint256 public VIRTUAL_QUOTE;

    address public factory;
    address public creator;
    IERC20 public quoteToken;
    IUniswapV2Router02 public router;
    IUniswapV2Factory public uniFactory;

    ArrowTokenClone public token;
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

    constructor() {
        _disableInitializers();
    }

    /// @dev Takes what used to be the constructor args plus the token address (which
    ///      the two-stage constructor+initialize(token_) pattern used to split across
    ///      two calls, since the token's own constructor needed this curve's address
    ///      first). With clones, this curve's address is known as soon as it's cloned
    ///      (before it's initialized), so the factory can create the token first and
    ///      wire everything in one call here.
    function initialize(
        address factory_,
        address creator_,
        address router_,
        address quoteToken_,
        uint256 virtualQuote_,
        uint256 migrationThreshold_,
        address token_
    ) external initializer {
        factory = factory_;
        creator = creator_;
        router = IUniswapV2Router02(router_);
        uniFactory = IUniswapV2Factory(router.factory());
        quoteToken = IERC20(quoteToken_);
        VIRTUAL_QUOTE = virtualQuote_;
        MIGRATION_THRESHOLD = migrationThreshold_;

        token = ArrowTokenClone(token_);
        tokenReserve = ArrowTokenClone(token_).TOTAL_SUPPLY();
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
