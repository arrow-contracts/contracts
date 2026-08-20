// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArrowFactoryStableClone} from "../src/tempo/ArrowFactoryStableClone.sol";
import {ArrowTokenClone} from "../src/tempo/ArrowTokenClone.sol";
import {ArrowBondingCurveCloneStable} from "../src/tempo/ArrowBondingCurveCloneStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// Real Uniswap V2 Router02 on Tempo mainnet, verified on-chain.
address constant TEMPO_MAINNET_ROUTER = 0x0FBac3c46F6F83B44C7fb4EA986d7309C701D73E;

/// Same MockStable stand-in as ArrowStable.t.sol — see that file for why pathUSD
/// itself can't be exercised against a local Anvil fork.
contract MockStable is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Same behavioral coverage as ArrowStable.t.sol, but exercising the clone-based
/// factory (ArrowFactoryStableClone + ArrowTokenClone + ArrowBondingCurveCloneStable)
/// instead of the deployer-based one — confirms the EIP-1167 clone path preserves
/// every rule (tax, shield, cap, migration, fee claiming) identically.
contract ArrowStableCloneTest is Test {
    ArrowFactoryStableClone factory;
    MockStable quote;
    address owner = makeAddr("platformOwner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    uint256 constant VIRTUAL_QUOTE = 1_000 * 1e6;
    uint256 constant MIGRATION_THRESHOLD = 4_000 * 1e6;

    function setUp() public {
        string memory rpc = vm.envOr("TEMPO_RPC_URL", string("https://rpc.tempo.xyz"));
        vm.createSelectFork(rpc);

        quote = new MockStable();
        ArrowTokenClone tokenImpl = new ArrowTokenClone();
        ArrowBondingCurveCloneStable curveImpl = new ArrowBondingCurveCloneStable();
        factory = new ArrowFactoryStableClone(
            owner, TEMPO_MAINNET_ROUTER, address(quote), VIRTUAL_QUOTE, MIGRATION_THRESHOLD,
            address(tokenImpl), address(curveImpl)
        );

        quote.mint(creator, 1_000_000 * 1e6);
        quote.mint(alice, 1_000_000 * 1e6);
    }

    function _launch(uint256 firstBuy) internal returns (ArrowTokenClone token, ArrowBondingCurveCloneStable curve) {
        vm.startPrank(creator);
        quote.approve(address(factory), firstBuy);
        (address t, address c) = factory.createTokenAndBuy("Test", "TST", "ipfs://bafytest", firstBuy, 0);
        vm.stopPrank();
        token = ArrowTokenClone(t);
        curve = ArrowBondingCurveCloneStable(c);
    }

    function test_implementationsCannotBeInitializedDirectly() public {
        ArrowTokenClone tokenImpl = new ArrowTokenClone();
        vm.expectRevert();
        tokenImpl.initialize("X", "X", address(this), address(this), address(this), "");

        ArrowBondingCurveCloneStable curveImpl = new ArrowBondingCurveCloneStable();
        vm.expectRevert();
        curveImpl.initialize(address(this), address(this), TEMPO_MAINNET_ROUTER, address(quote), 1, 1, address(this));
    }

    function test_cloneCannotBeInitializedTwice() public {
        (ArrowTokenClone token, ArrowBondingCurveCloneStable curve) = _launch(0);

        vm.expectRevert();
        token.initialize("X", "X", address(this), address(this), address(this), "");

        vm.expectRevert();
        curve.initialize(address(this), address(this), TEMPO_MAINNET_ROUTER, address(quote), 1, 1, address(this));
    }

    function test_fixedSupply_noMint() public {
        (ArrowTokenClone token,) = _launch(0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.name(), "Test");
        assertEq(token.symbol(), "TST");
    }

    function test_baseFee_splitsAndAccrues() public {
        (ArrowTokenClone token, ArrowBondingCurveCloneStable curve) = _launch(0);
        vm.warp(block.timestamp + 31); // past the shield window, flat 2%

        vm.startPrank(alice);
        quote.approve(address(curve), 20 * 1e6);
        curve.buy(alice, 20 * 1e6, 0);
        vm.stopPrank();

        assertGt(token.platformFeesAccrued(), 0);
        assertEq(token.platformFeesAccrued(), token.creatorFeesAccrued());
    }

    function test_shieldFee_decaysFrom99To2Percent() public {
        (ArrowTokenClone token,) = _launch(0);
        assertEq(token.currentBuyFeeBps(), 9_900);
        vm.warp(block.timestamp + 30);
        assertEq(token.currentBuyFeeBps(), 200);
    }

    function test_maxWallet_cumulativeAcrossTransactions() public {
        (ArrowTokenClone token, ArrowBondingCurveCloneStable curve) = _launch(0);
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

    function _buyUntilMigrated(ArrowBondingCurveCloneStable curve) internal {
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
        (ArrowTokenClone token, ArrowBondingCurveCloneStable curve) = _launch(0);
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
        (, ArrowBondingCurveCloneStable curve) = _launch(0);
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
        (ArrowTokenClone token,) = _launch(0);
        address communityWallet = makeAddr("communityCTO");
        vm.prank(owner);
        factory.reassignCreatorFeeRecipient(address(token), communityWallet);
        assertEq(token.creatorFeeRecipient(), communityWallet);
    }

    function test_nonOwnerCannotOverrideCreatorRecipient() public {
        (ArrowTokenClone token,) = _launch(0);
        vm.prank(alice);
        vm.expectRevert("not owner");
        factory.reassignCreatorFeeRecipient(address(token), alice);
    }

    function test_platformFeeRecipientCanClaimViaFactory() public {
        (ArrowTokenClone token, ArrowBondingCurveCloneStable curve) = _launch(0);
        vm.warp(block.timestamp + 31);
        vm.startPrank(alice);
        quote.approve(address(curve), 20 * 1e6);
        curve.buy(alice, 20 * 1e6, 0);
        vm.stopPrank();

        uint256 accrued = token.platformFeesAccrued();
        assertGt(accrued, 0);

        vm.prank(owner);
        uint256 claimed = factory.claimPlatformFeesFor(address(token));
        assertEq(claimed, accrued);
        assertEq(token.balanceOf(owner), accrued);
        assertEq(token.platformFeesAccrued(), 0);
    }

    function test_firstBuy_pulledViaApproval() public {
        (ArrowTokenClone token,) = _launch(20 * 1e6);
        assertGt(token.balanceOf(creator), 0);
    }

    function test_twoLaunches_areIndependentClones() public {
        (ArrowTokenClone tokenA,) = _launch(0);
        vm.startPrank(creator);
        quote.approve(address(factory), 0);
        (address tB,) = factory.createTokenAndBuy("Other", "OTH", "ipfs://other", 0, 0);
        vm.stopPrank();
        ArrowTokenClone tokenB = ArrowTokenClone(tB);

        assertTrue(address(tokenA) != address(tokenB));
        assertEq(tokenA.name(), "Test");
        assertEq(tokenB.name(), "Other");
    }
}
