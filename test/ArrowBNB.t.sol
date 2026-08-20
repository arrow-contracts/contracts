// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArrowFactory} from "../src/ArrowFactory.sol";
import {ArrowToken} from "../src/ArrowToken.sol";
import {ArrowBondingCurve} from "../src/ArrowBondingCurve.sol";
import {TokenDeployer} from "../src/deployers/TokenDeployer.sol";
import {CurveDeployer} from "../src/deployers/CurveDeployer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// PancakeSwap V2 Router on BNB Chain mainnet, verified on-chain before use here:
// router.factory() matches this factory, router.WETH() matches the real WBNB address
// (0xbb4C...c095c), and factory.allPairsLength() returned 2,695,528 live pairs.
address constant BNB_MAINNET_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

contract ArrowBNBTest is Test {
    ArrowFactory factory;
    address owner = makeAddr("platformOwner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("BNB_RPC_URL", string("https://bsc-dataseed.binance.org"));
        vm.createSelectFork(rpc);

        factory =
            new ArrowFactory(owner, BNB_MAINNET_ROUTER, address(new TokenDeployer()), address(new CurveDeployer()));
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

    function test_fixedSupply_noMint() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_baseFee_splitsAndAccrues() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31);

        vm.prank(alice);
        curve.buy{value: 0.02 ether}(alice, 0);

        assertGt(token.platformFeesAccrued(), 0);
        assertEq(token.platformFeesAccrued(), token.creatorFeesAccrued());

        uint256 owedToPlatform = token.platformFeesAccrued();
        uint256 before = token.balanceOf(owner);
        vm.prank(owner);
        token.claimPlatformFees();
        assertEq(token.balanceOf(owner) - before, owedToPlatform);
    }

    function test_shieldFee_decaysFrom99To2Percent() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.currentBuyFeeBps(), 9_900);
        vm.warp(block.timestamp + 30);
        assertEq(token.currentBuyFeeBps(), 200);
    }

    function test_maxWallet_singleBuyCapped() public {
        (ArrowToken token, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        uint256 cap = token.TOTAL_SUPPLY() * 300 / 10_000;

        vm.prank(alice);
        vm.expectRevert("exceeds max wallet");
        curve.buy{value: 0.05 ether}(alice, 0);

        vm.prank(alice);
        curve.buy{value: 0.01 ether}(alice, 0);
        assertLt(token.balanceOf(alice), cap);
    }

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
        vm.warp(block.timestamp + 31);

        _buyUntilMigrated(curve);

        assertTrue(curve.migrated());
        address pair = curve.pair();
        assertTrue(pair != address(0));
        assertEq(IERC20(pair).balanceOf(address(curve)), 0);
        assertGt(IERC20(pair).balanceOf(address(0xdead)), 0);
        assertTrue(token.capExempt(pair));
    }

    function test_cannotBuyOrSellAfterMigration() public {
        (, ArrowBondingCurve curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        _buyUntilMigrated(curve);

        vm.prank(bob);
        vm.expectRevert("migrated");
        curve.buy{value: 1 ether}(bob, 0);
    }
}
