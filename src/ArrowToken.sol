// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IArrowFactory} from "./interfaces/IArrowFactory.sol";

/// @title ArrowToken
/// @notice Fixed-supply ERC20 with a permanent 2% transfer tax (1% platform / 1% creator,
///         both claimable) and a 30-second launch tax that decays from 99% down to the
///         permanent 2% floor. Also enforces a 3% max-wallet cap, forever, except for the
///         bonding curve and the eventual Uniswap pair.
/// @dev All of this is enforced centrally in `_update`, the single choke point every
///      transfer (mint, curve buy/sell, wallet-to-wallet, DEX swap) goes through.
contract ArrowToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public constant BASE_FEE_BPS = 200; // 2%, forever
    uint256 public constant SHIELD_START_BPS = 9_900; // 99%, at launch
    uint256 public constant SHIELD_DURATION = 30 seconds;
    uint256 public constant MAX_WALLET_BPS = 300; // 3%
    uint256 private constant BPS_DENOM = 10_000;

    address public immutable factory;
    address public immutable curve;
    address public immutable creator;
    uint256 public immutable launchTime;

    /// @notice IPFS URI (ipfs://<cid>) of a JSON blob with logo/description/socials.
    ///         Set once at launch, never changed — same "immutable once live" spirit
    ///         as everything else here. Off-chain content, on-chain pointer: anyone
    ///         (an explorer, an aggregator, a future integration) can resolve it
    ///         without ever needing to ask Arrow's own servers.
    string public metadataURI;

    /// @notice Who receives the creator's 1% cut. Defaults to `creator`. Can be
    ///         reassigned by the current recipient (hand it off yourself) or by the
    ///         platform owner (CTO override for abandoned tokens).
    address public creatorFeeRecipient;

    uint256 public platformFeesAccrued;
    uint256 public creatorFeesAccrued;

    /// @notice Addresses exempt from the 3% max-wallet cap (the curve itself, and the
    ///         Uniswap pair once migration wires it up). Both also skip the tax check
    ///         on their *outgoing* transfers being taxed twice — see `_update`.
    mapping(address => bool) public capExempt;

    /// @dev Set for the duration of the one-off liquidity-provisioning transfer at
    ///      migration, so that internal move isn't taxed or cap-checked like a trade.
    bool internal migrating;

    event CreatorFeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);
    event FeesClaimed(address indexed recipient, uint256 amount, bool isPlatform);
    event CapExemptionSet(address indexed account, bool exempt);

    constructor(
        string memory name_,
        string memory symbol_,
        address factory_,
        address curve_,
        address creator_,
        string memory metadataURI_
    ) ERC20(name_, symbol_) {
        factory = factory_;
        curve = curve_;
        creator = creator_;
        creatorFeeRecipient = creator_;
        launchTime = block.timestamp;
        metadataURI = metadataURI_;

        capExempt[curve_] = true;
        emit CapExemptionSet(curve_, true);

        _mint(curve_, TOTAL_SUPPLY);
    }

    // ── Admin ────────────────────────────────────────────────────────────

    modifier onlyFactoryOwner() {
        require(msg.sender == IArrowFactory(factory).owner(), "not factory owner");
        _;
    }

    modifier onlyCurve() {
        require(msg.sender == curve, "not curve");
        _;
    }

    /// @notice One-time-per-address toggle, only ever expected to be called for the
    ///         Uniswap pair address, once, at migration.
    function setCapExempt(address account, bool exempt) external onlyCurve {
        capExempt[account] = exempt;
        emit CapExemptionSet(account, exempt);
    }

    /// @dev The bonding curve flips this on for exactly one transfer: the liquidity
    ///      it hands to the Uniswap router at migration. Nothing else may call this.
    function setMigrating(bool value) external onlyCurve {
        migrating = value;
    }

    function setCreatorFeeRecipient(address newRecipient) external {
        require(
            msg.sender == creatorFeeRecipient || msg.sender == IArrowFactory(factory).owner(),
            "not authorized"
        );
        require(newRecipient != address(0), "zero address");
        emit CreatorFeeRecipientChanged(creatorFeeRecipient, newRecipient);
        creatorFeeRecipient = newRecipient;
    }

    // ── Fee claiming ─────────────────────────────────────────────────────

    function claimPlatformFees() external returns (uint256 amount) {
        require(msg.sender == IArrowFactory(factory).platformFeeRecipient(), "not platform recipient");
        amount = platformFeesAccrued;
        platformFeesAccrued = 0;
        if (amount > 0) {
            migrating = true; // reuse the "internal, untaxed, uncapped" path for payout
            _transfer(address(this), msg.sender, amount);
            migrating = false;
        }
        emit FeesClaimed(msg.sender, amount, true);
    }

    function claimCreatorFees() external returns (uint256 amount) {
        require(msg.sender == creatorFeeRecipient, "not creator recipient");
        amount = creatorFeesAccrued;
        creatorFeesAccrued = 0;
        if (amount > 0) {
            migrating = true;
            _transfer(address(this), msg.sender, amount);
            migrating = false;
        }
        emit FeesClaimed(msg.sender, amount, false);
    }

    // ── Core transfer tax + cap ──────────────────────────────────────────

    function currentBuyFeeBps() public view returns (uint256) {
        if (block.timestamp >= launchTime + SHIELD_DURATION) return BASE_FEE_BPS;
        uint256 elapsed = block.timestamp - launchTime;
        // Linear decay from 9900bps at t=0 to 200bps at t=30s.
        uint256 decayed = (SHIELD_START_BPS - BASE_FEE_BPS) * (SHIELD_DURATION - elapsed) / SHIELD_DURATION;
        return BASE_FEE_BPS + decayed;
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mint (from == 0) and internal migration/claim transfers bypass tax + cap.
        if (from == address(0) || migrating) {
            super._update(from, to, value);
            return;
        }

        uint256 feeBps = (from == curve) ? currentBuyFeeBps() : BASE_FEE_BPS;
        uint256 totalFee = value * feeBps / BPS_DENOM;
        uint256 baseFee = value * BASE_FEE_BPS / BPS_DENOM;
        uint256 shieldExtra = totalFee - baseFee; // 0 outside the launch window
        uint256 platformCut = baseFee / 2;
        uint256 creatorCut = baseFee - platformCut;
        uint256 netToRecipient = value - totalFee;

        if (!capExempt[to]) {
            require(
                balanceOf(to) + netToRecipient <= TOTAL_SUPPLY * MAX_WALLET_BPS / BPS_DENOM,
                "exceeds max wallet"
            );
        }

        super._update(from, to, netToRecipient);
        if (platformCut > 0) {
            super._update(from, address(this), platformCut);
            platformFeesAccrued += platformCut;
        }
        if (creatorCut > 0) {
            super._update(from, address(this), creatorCut);
            creatorFeesAccrued += creatorCut;
        }
        if (shieldExtra > 0) {
            // Retained by the curve: fewer tokens leave circulation to early snipers,
            // and the curve keeps the extra backing for later sellers / migration LP.
            super._update(from, curve, shieldExtra);
        }
    }
}
