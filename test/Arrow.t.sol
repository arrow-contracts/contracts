// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArrowFactory} from "../src/ArrowFactory.sol";
import {ArrowToken} from "../src/ArrowToken.sol";
import {ArrowBondingCurve} from "../src/ArrowBondingCurve.sol";
import {TokenDeployer} from "../src/deployers/TokenDeployer.sol";
import {CurveDeployer} from "../src/deployers/CurveDeployer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";

// Real Uniswap V2 Router02 on Robinhood Chain mainnet, verified on-chain (router.factory()
// matches the factory, factory.allPairsLength() returns a live pair count) before use here.
address constant ROBINHOOD_MAINNET_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

contract ArrowTest is Test {
    ArrowFactory factory;
    address owner = makeAddr("platformOwner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // Fork Robinhood Chain mainnet so the real Uniswap V2 router/factory/WETH
        // are actually present for the migration tests to interact with.
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);

        factory = new ArrowFactory(
            owner, ROBINHOOD_MAINNET_ROUTER, address(new TokenDeployer()), address(new CurveDeployer())
        );
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _launch(uint256 firstBuy) internal returns (ArrowToken token, ArrowBondingCurve curve) {
        vm.prank(creator);
        (address t, address c) =
            factory.createTokenAndBuy{value: firstBuy}("Test", "TST", "ipfs://bafytestcidplaceholder", 0);
        token = ArrowToken(t);
        curve = ArrowBondingCurve(c);
    }

    // ── Supply ───────────────────────────────────────────────────────────

    function test_fixedSupply_noMint() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        // No mint function exists on ArrowToken at all — this is a compile-time
        // guarantee (there is no external/public mint selector), not a runtime check.
    }

    function test_metadataURI_storedAtLaunch() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.metadataURI(), "ipfs://bafytestcidplaceholder");
    }

    // ── Base 2% fee, split 1/1, claimable ───────────────────────────────

    function test_baseFee_splitsAndAccrues() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31); // past the shield window, flat 2% from here

        vm.prank(alice);
        curve.buy{value: 0.02 ether}(alice, 0);

        assertGt(token.platformFeesAccrued(), 0);
        assertEq(token.platformFeesAccrued(), token.creatorFeesAccrued());

        uint256 owedToPlatform = token.platformFeesAccrued();
        uint256 before = token.balanceOf(owner);
        vm.prank(owner);
        token.claimPlatformFees();
        assertEq(token.balanceOf(owner) - before, owedToPlatform);
        assertEq(token.platformFeesAccrued(), 0);

        uint256 owedToCreator = token.creatorFeesAccrued();
        uint256 creatorBefore = token.balanceOf(creator);
        vm.prank(creator);
        token.claimCreatorFees();
        assertEq(token.balanceOf(creator) - creatorBefore, owedToCreator);
        assertEq(token.creatorFeesAccrued(), 0);
    }

    function test_onlyAuthorized_canClaim() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        vm.prank(alice);
        curve.buy{value: 0.02 ether}(alice, 0);

        vm.prank(alice);
        vm.expectRevert("not platform recipient");
        token.claimPlatformFees();

        vm.prank(alice);
        vm.expectRevert("not creator recipient");
        token.claimCreatorFees();
    }

    // ── Sniper shield: 99% -> 2% over 30s ───────────────────────────────

    function test_shieldFee_decaysFrom99To2Percent() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.currentBuyFeeBps(), 9_900, "t=0 should be 99%");

        vm.warp(block.timestamp + 15);
        assertEq(token.currentBuyFeeBps(), 200 + (9_900 - 200) / 2, "t=15s should be ~halfway");

        vm.warp(block.timestamp + 15); // t = 30
        assertEq(token.currentBuyFeeBps(), 200, "t=30s should have floored at 2%");

        vm.warp(block.timestamp + 1000);
        assertEq(token.currentBuyFeeBps(), 200, "stays at 2% forever after");
    }

    function test_shieldWindow_buyerReceivesFarFewerTokens() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);

        vm.prank(alice);
        curve.buy{value: 0.01 ether}(alice, 0);
        uint256 earlyBalance = token.balanceOf(alice);

        vm.warp(block.timestamp + 31);
        vm.prank(bob);
        curve.buy{value: 0.01 ether}(bob, 0);
        uint256 lateBalance = token.balanceOf(bob);

        // Same ETH in, but alice bought during the 99%-fee window: she should end up
        // with dramatically fewer tokens than bob, who bought after the shield lifted.
        assertLt(earlyBalance * 10, lateBalance, "shield window should tax buyers ~50x harder");
    }

    function test_shieldExtra_isRetainedByCurve_notFeeRecipients() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        uint256 curveBalBefore = token.balanceOf(address(curve));
        uint256 reserveBefore = curve.tokenReserve();

        vm.prank(alice);
        curve.buy{value: 0.01 ether}(alice, 0);

        uint256 grossSold = reserveBefore - curve.tokenReserve();
        uint256 actualLeftCurve = curveBalBefore - token.balanceOf(address(curve));

        // At t=0 the buy fee is 99%: only a sliver of what the curve's pricing math
        // says was "sold" should have actually left the curve's balance — the rest
        // (the shield premium) stays behind, not routed to the fee-claim buckets.
        assertLt(actualLeftCurve, grossSold);
        assertGt(grossSold - actualLeftCurve, grossSold * 90 / 100);
    }

    // ── 3% max wallet, cumulative ────────────────────────────────────────

    function test_maxWallet_singleBuyCapped() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31);

        uint256 cap = token.TOTAL_SUPPLY() * 300 / 10_000;

        // With a 1 ETH virtual reserve against a 1B supply, the curve is steep near
        // the start: 0.05 ETH alone already buys well past 3% of supply.
        vm.prank(alice);
        vm.expectRevert("exceeds max wallet");
        curve.buy{value: 0.05 ether}(alice, 0);

        // A buy sized to land comfortably under the cap should succeed.
        vm.prank(alice);
        curve.buy{value: 0.01 ether}(alice, 0);
        assertLt(token.balanceOf(alice), cap);
    }

    function test_maxWallet_cumulativeAcrossTransactions() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31);

        vm.prank(alice);
        curve.buy{value: 0.02 ether}(alice, 0);
        uint256 afterFirst = token.balanceOf(alice);
        assertGt(afterFirst, 0);
        assertLt(afterFirst, token.TOTAL_SUPPLY() * 300 / 10_000);

        // This second buy would land under the cap on its own (curve state has
        // moved, so it nets fewer tokens than the first) — it only fails because
        // it's added on top of the balance alice already holds. That's the
        // "cumulative, can't be split across transactions" rule doing its job.
        vm.prank(alice);
        vm.expectRevert("exceeds max wallet");
        curve.buy{value: 0.02 ether}(alice, 0);
    }

    function test_maxWallet_curveAndPairAreExempt() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        // The curve starts holding the entire 1B supply, far above the 3% cap —
        // this must not revert on construction, proving the curve is cap-exempt.
        assertEq(token.balanceOf(address(curve)), token.TOTAL_SUPPLY());
        assertTrue(token.capExempt(address(curve)));
    }

    // ── Migration at exactly 4 ETH, LP burned ───────────────────────────

    /// @dev The 3% per-wallet cap means no single buyer can push the raise anywhere
    ///      near 4 ETH alone — that's the point. So migration is reached here the way
    ///      it would be in reality: many distinct wallets, each buying under their cap.
    function _buyUntilMigrated(ArrowBondingCurve curve) internal {
        for (uint256 i = 0; i < 300 && !curve.migrated(); i++) {
            address buyer = makeAddr(string(abi.encodePacked("swarm", i)));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer);
            curve.buy{value: 0.02 ether}(buyer, 0);
        }
        require(curve.migrated(), "did not migrate within iteration budget");
    }

    function test_migratesAt4Eth_andBurnsLp() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31); // skip the shield so math is simple 2% flat

        _buyUntilMigrated(curve);

        assertTrue(curve.migrated());
        address pair = curve.pair();
        assertTrue(pair != address(0));

        // LP tokens must be burned (sent to 0xdead), not held by curve/creator/owner.
        assertEq(IERC20(pair).balanceOf(address(curve)), 0);
        assertGt(IERC20(pair).balanceOf(address(0xdead)), 0);

        assertTrue(token.capExempt(pair), "pair must be cap-exempt for pooled liquidity");
    }

    function test_cannotBuyOrSellAfterMigration() public {
        (, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        _buyUntilMigrated(curve);
        assertTrue(curve.migrated());

        vm.prank(bob);
        vm.expectRevert("migrated");
        curve.buy{value: 1 ether}(bob, 0);
    }

    // ── Creator fee recipient / CTO override ────────────────────────────

    function test_creatorCanReassignOwnRecipient() public {
        (ArrowToken token,) = _launch(0);
        address newWallet = makeAddr("newCreatorWallet");
        vm.prank(creator);
        token.setCreatorFeeRecipient(newWallet);
        assertEq(token.creatorFeeRecipient(), newWallet);
    }

    function test_platformOwnerCanOverrideCreatorRecipient_forCTO() public {
        (ArrowToken token,) = _launch(0);
        address communityWallet = makeAddr("communityCTO");
        vm.prank(owner);
        token.setCreatorFeeRecipient(communityWallet);
        assertEq(token.creatorFeeRecipient(), communityWallet);
    }

    function test_randomAddressCannotReassignCreatorRecipient() public {
        (ArrowToken token,) = _launch(0);
        vm.prank(alice);
        vm.expectRevert("not authorized");
        token.setCreatorFeeRecipient(alice);
    }

    // ── Platform fee recipient is global, owner-controlled ──────────────

    function test_platformFeeRecipient_defaultsToOwner_andIsChangeable() public {
        assertEq(factory.platformFeeRecipient(), owner);
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        factory.setPlatformFeeRecipient(treasury);
        assertEq(factory.platformFeeRecipient(), treasury);
    }
}
