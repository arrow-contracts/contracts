// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArrowFactoryStable} from "../src/ArrowFactoryStable.sol";
import {ArrowToken} from "../src/ArrowToken.sol";
import {ArrowBondingCurveStable} from "../src/ArrowBondingCurveStable.sol";
import {TokenDeployer} from "../src/deployers/TokenDeployer.sol";
import {CurveDeployerStable} from "../src/deployers/CurveDeployerStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// Real Uniswap V2 Router02 on Tempo mainnet, verified on-chain (router.factory()
// matches the factory, factory.allPairsLength() returns a live pair count).
address constant TEMPO_MAINNET_ROUTER = 0x0FBac3c46F6F83B44C7fb4EA986d7309C701D73E;

/// Standard mintable 6-decimal ERC20 standing in for pathUSD in these tests.
/// pathUSD itself is a TIP-20 token backed by a chain-native precompile that Anvil's
/// generic EVM can't execute when forking locally ("EVM error OpcodeNotFound") — this
/// mock is ERC20-standard-compliant the same way TIP-20 is documented to be, so it
/// exercises the exact same code paths (transfer/transferFrom/approve, 6 decimals)
/// without depending on precompile support Anvil doesn't have.
contract MockStable is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract ArrowStableTest is Test {
    ArrowFactoryStable factory;
    MockStable quote;
    address owner = makeAddr("platformOwner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    uint256 constant VIRTUAL_QUOTE = 1_000 * 1e6; // $1,000, 6 decimals
    uint256 constant MIGRATION_THRESHOLD = 4_000 * 1e6; // $4,000, 6 decimals

    function setUp() public {
        string memory rpc = vm.envOr("TEMPO_RPC_URL", string("https://rpc.tempo.xyz"));
        vm.createSelectFork(rpc);

        quote = new MockStable();
        factory = new ArrowFactoryStable(
            owner, TEMPO_MAINNET_ROUTER, address(quote), VIRTUAL_QUOTE, MIGRATION_THRESHOLD,
            address(new TokenDeployer()), address(new CurveDeployerStable())
        );

        quote.mint(creator, 1_000_000 * 1e6);
        quote.mint(alice, 1_000_000 * 1e6);
    }

    function _launch(uint256 firstBuy) internal returns (ArrowToken token, ArrowBondingCurveStable curve) {
        vm.startPrank(creator);
        quote.approve(address(factory), firstBuy);
        (address t, address c) = factory.createTokenAndBuy("Test", "TST", "ipfs://bafytest", firstBuy, 0);
        vm.stopPrank();
        token = ArrowToken(t);
        curve = ArrowBondingCurveStable(c);
    }

    function test_fixedSupply_noMint() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_baseFee_splitsAndAccrues() public {
        (ArrowToken token, ArrowBondingCurveStable curve) = _launch(0);
        vm.warp(block.timestamp + 31); // past the shield window, flat 2%

        vm.startPrank(alice);
        quote.approve(address(curve), 20 * 1e6);
        curve.buy(alice, 20 * 1e6, 0);
        vm.stopPrank();

        assertGt(token.platformFeesAccrued(), 0);
        assertEq(token.platformFeesAccrued(), token.creatorFeesAccrued());
    }

    function test_shieldFee_decaysFrom99To2Percent() public {
        (ArrowToken token,) = _launch(0);
        assertEq(token.currentBuyFeeBps(), 9_900);
        vm.warp(block.timestamp + 30);
        assertEq(token.currentBuyFeeBps(), 200);
    }

    function test_maxWallet_cumulativeAcrossTransactions() public {
        (ArrowToken token, ArrowBondingCurveStable curve) = _launch(0);
        vm.warp(block.timestamp + 31);

        vm.startPrank(alice);
        quote.approve(address(curve), 100 * 1e6);
        curve.buy(alice, 20 * 1e6, 0);
        uint256 afterFirst = token.balanceOf(alice);
        assertGt(afterFirst, 0);
        assertLt(afterFirst, token.TOTAL_SUPPLY() * 300 / 10_000);

        vm.expectRevert("exceeds max wallet");
        curve.buy(alice, 20 * 1e6, 0);
        vm.stopPrank();
    }

    /// 3% per-wallet cap means migration needs many distinct buyers, same as the
    /// ETH-denominated curves — see ArrowTest for why.
    function _buyUntilMigrated(ArrowBondingCurveStable curve) internal {
        for (uint256 i = 0; i < 300 && !curve.migrated(); i++) {
            address buyer = makeAddr(string(abi.encodePacked("swarm", i)));
            quote.mint(buyer, 100 * 1e6);
            vm.startPrank(buyer);
            quote.approve(address(curve), 20 * 1e6);
            curve.buy(buyer, 20 * 1e6, 0);
            vm.stopPrank();
        }
        require(curve.migrated(), "did not migrate within iteration budget");
    }

    function test_migratesAt4000Quote_andBurnsLp() public {
        (ArrowToken token, ArrowBondingCurveStable curve) = _launch(0);
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
        (, ArrowBondingCurveStable curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        _buyUntilMigrated(curve);

        address bob = makeAddr("bob");
        quote.mint(bob, 20 * 1e6);
        vm.startPrank(bob);
        quote.approve(address(curve), 20 * 1e6);
        vm.expectRevert("migrated");
        curve.buy(bob, 20 * 1e6, 0);
        vm.stopPrank();
    }

    function test_platformOwnerCanOverrideCreatorRecipient_forCTO() public {
        (ArrowToken token,) = _launch(0);
        address communityWallet = makeAddr("communityCTO");
        vm.prank(owner);
        token.setCreatorFeeRecipient(communityWallet);
        assertEq(token.creatorFeeRecipient(), communityWallet);
    }

    function test_firstBuy_pulledViaApproval() public {
        (ArrowToken token,) = _launch(20 * 1e6);
        assertGt(token.balanceOf(creator), 0);
    }
}
