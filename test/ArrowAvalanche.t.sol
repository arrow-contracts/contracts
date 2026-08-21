// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArrowFactoryConfig} from "../src/ArrowFactoryConfig.sol";
import {ArrowToken} from "../src/ArrowToken.sol";
import {ArrowBondingCurveConfig} from "../src/ArrowBondingCurveConfig.sol";
import {TokenDeployer} from "../src/deployers/TokenDeployer.sol";
import {CurveDeployerConfig} from "../src/deployers/CurveDeployerConfig.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Official Uniswap V2 Router02 on Avalanche C-Chain, verified on-chain before use
// here: router.factory() matches this factory, router.WETH() resolves to the real
// WAVAX contract (symbol() == "WAVAX"), and factory.allPairsLength() returned
// 12,248 live pairs.
address constant AVALANCHE_MAINNET_ROUTER = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;

// AVAX was ~$6.90 at deploy time — "4 AVAX" (ArrowBondingCurve's hardcoded default,
// fine on ETH/BNB chains) would be a ~$28 migration bar, essentially meaningless.
// ArrowFactoryConfig/ArrowBondingCurveConfig make this configurable: 290 AVAX
// (~$2,000) as the migration threshold, keeping the same 1:4 virtual:threshold
// ratio the fixed-constant version uses (72.5 AVAX virtual reserve).
uint256 constant VIRTUAL_AVAX = 72.5 ether;
uint256 constant MIGRATION_THRESHOLD_AVAX = 290 ether;

contract ArrowAvalancheTest is Test {
    ArrowFactoryConfig factory;
    address owner = makeAddr("platformOwner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc"));
        vm.createSelectFork(rpc);

        factory = new ArrowFactoryConfig(
            owner,
            AVALANCHE_MAINNET_ROUTER,
            VIRTUAL_AVAX,
            MIGRATION_THRESHOLD_AVAX,
            address(new TokenDeployer()),
            address(new CurveDeployerConfig())
        );
        vm.deal(creator, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _launch(uint256 firstBuy) internal returns (ArrowToken token, ArrowBondingCurveConfig curve) {
        vm.prank(creator);
        (address t, address c) =
            factory.createTokenAndBuy{value: firstBuy}("Test", "TST", "ipfs://bafytestcidplaceholder", 0);
        token = ArrowToken(t);
        curve = ArrowBondingCurveConfig(c);
    }

    function test_fixedSupply_noMint() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_thresholds_areTheConfiguredAvaxAmounts() public {
        (, ArrowBondingCurveConfig curve) = _launch(0);
        assertEq(curve.VIRTUAL_ETH(), VIRTUAL_AVAX);
        assertEq(curve.MIGRATION_THRESHOLD(), MIGRATION_THRESHOLD_AVAX);
    }

    function test_baseFee_splitsAndAccrues() public {
        (ArrowToken token, ArrowBondingCurveConfig curve) = _launch(0);
        vm.warp(block.timestamp + 31);

        vm.prank(alice);
        curve.buy{value: 1.45 ether}(alice, 0);

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
        (ArrowToken token, ArrowBondingCurveConfig curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        uint256 cap = token.TOTAL_SUPPLY() * 300 / 10_000;

        // Same proportions as the 1-ETH-virtual version, scaled 72.5x: a buy sized
        // like "0.05 ETH" there is "3.625 AVAX" here against a 72.5 AVAX virtual
        // reserve, and should blow past the 3% cap the same way.
        vm.prank(alice);
        vm.expectRevert("exceeds max wallet");
        curve.buy{value: 3.625 ether}(alice, 0);

        vm.prank(alice);
        curve.buy{value: 0.725 ether}(alice, 0);
        assertLt(token.balanceOf(alice), cap);
    }

    function _buyUntilMigrated(ArrowBondingCurveConfig curve) internal {
        for (uint256 i = 0; i < 300 && !curve.migrated(); i++) {
            address buyer = makeAddr(string(abi.encodePacked("swarm", i)));
            vm.deal(buyer, 10 ether);
            vm.prank(buyer);
            curve.buy{value: 1.45 ether}(buyer, 0);
        }
        require(curve.migrated(), "did not migrate within iteration budget");
    }

    function test_migratesAt290Avax_andBurnsLp() public {
        (ArrowToken token, ArrowBondingCurveConfig curve) = _launch(0);
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
        (, ArrowBondingCurveConfig curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        _buyUntilMigrated(curve);

        vm.prank(bob);
        vm.expectRevert("migrated");
        curve.buy{value: 10 ether}(bob, 0);
    }
}
