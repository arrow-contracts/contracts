// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ArrowTokenClone} from "../tempo/ArrowTokenClone.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../interfaces/IUniswapV2.sol";

/// @title ArrowBondingCurveClone
/// @notice Same mechanics as ArrowBondingCurve (native-quote), built for cloning: every
///         field that used to be set once via the constructor is now regular storage
///         set by `initialize`, so this contract is deployed once as a shared
///         implementation and cheaply cloned (EIP-1167) per token launch.
/// @dev HyperEVM-specific reason (different from Tempo's): HyperEVM's real block gas
///      limit is only 3,000,000 gas. A from-scratch `createTokenAndBuy` — deploying a
///      full ArrowToken + ArrowBondingCurve in one user transaction — measured at
///      3,029,241 gas against the live deployed factory, just over the ceiling, so
///      every single launch reverted with no revert data (the tx can never fit in any
///      block). Cloning both contracts instead of deploying their full bytecode brings
///      a launch's total gas well under the limit. Reuses ArrowTokenClone as-is (its
///      logic doesn't reference the quote asset at all).
contract ArrowBondingCurveClone is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public MIGRATION_THRESHOLD;
    uint256 public VIRTUAL_ETH;

    address public factory;
    address public creator;
    IUniswapV2Router02 public router;
    IUniswapV2Factory public uniFactory;

    ArrowTokenClone public token;
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

    constructor() {
        _disableInitializers();
    }

    /// @dev Mirrors ArrowBondingCurveCloneStable.initialize, minus the ERC20 quote
    ///      token (the quote here is the chain's native asset).
    function initialize(
        address factory_,
        address creator_,
        address router_,
        uint256 virtualEth_,
        uint256 migrationThreshold_,
        address token_
    ) external initializer {
        factory = factory_;
        creator = creator_;
        router = IUniswapV2Router02(router_);
        uniFactory = IUniswapV2Factory(router.factory());
        VIRTUAL_ETH = virtualEth_;
        MIGRATION_THRESHOLD = migrationThreshold_;

        token = ArrowTokenClone(token_);
        tokenReserve = ArrowTokenClone(token_).TOTAL_SUPPLY();
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
