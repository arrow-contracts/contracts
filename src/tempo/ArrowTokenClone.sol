// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

/// @title ArrowTokenClone
/// @notice Same rules as ArrowToken (permanent 2% tax, 30s decaying sniper shield, 3%
///         max-wallet cap, forever) but built to be deployed once as a shared
///         implementation and cloned per launch via EIP-1167 minimal proxies, instead
///         of a full `new ArrowToken(...)` per launch. Tempo's transaction validation
///         rejects the large CREATE that a from-scratch deploy needs when embedded
///         inside a deployer contract (see TokenDeployer) — cloning sidesteps that
///         entirely, and is far cheaper besides.
/// @dev All tax/cap logic lives in `_update`, identical to ArrowToken. Construction
///      differs (immutable fields become regular storage set by `initialize`), and —
///      Tempo-specific — this contract makes NO external calls to the factory: an
///      `IArrowFactory(factory).owner()` staticcall in the bytecode was empirically
///      confirmed to trip Tempo's CREATE-transaction PolicyForbids revert (isolated
///      via diagnostic contracts; unrelated to size, gas cost, or the tax logic
///      itself). The CTO-override and platform-fee-claim paths that used to call out
///      to the factory are inverted instead: the factory calls into the token
///      (`onlyFactory`-gated) after checking its own local owner/platformFeeRecipient.
contract ArrowTokenClone is Initializable, ERC20Upgradeable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public constant BASE_FEE_BPS = 200; // 2%, forever
    uint256 public constant SHIELD_START_BPS = 9_900; // 99%, at launch
    uint256 public constant SHIELD_DURATION = 30 seconds;
    uint256 public constant MAX_WALLET_BPS = 300; // 3%
    uint256 private constant BPS_DENOM = 10_000;

    address public factory;
    address public curve;
    address public creator;
    uint256 public launchTime;

    string public metadataURI;
    address public creatorFeeRecipient;

    uint256 public platformFeesAccrued;
    uint256 public creatorFeesAccrued;

    mapping(address => bool) public capExempt;
    bool internal migrating;

    event CreatorFeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);
    event FeesClaimed(address indexed recipient, uint256 amount, bool isPlatform);
    event CapExemptionSet(address indexed account, bool exempt);

    /// @dev Locks initializers on the implementation contract itself — only clones
    ///      (which never run this constructor) can be initialized.
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address factory_,
        address curve_,
        address creator_,
        string memory metadataURI_
    ) external initializer {
        __ERC20_init(name_, symbol_);
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

    modifier onlyCurve() {
        require(msg.sender == curve, "not curve");
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == factory, "not factory");
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
        require(msg.sender == creatorFeeRecipient, "not authorized");
        require(newRecipient != address(0), "zero address");
        emit CreatorFeeRecipientChanged(creatorFeeRecipient, newRecipient);
        creatorFeeRecipient = newRecipient;
    }

    /// @notice CTO override for abandoned tokens. Only the factory may call this —
    ///         it does so on behalf of its own owner (see
    ///         ArrowFactoryStableClone.reassignCreatorFeeRecipient), which is the
    ///         Tempo-specific inversion of the "token asks factory who owns it" check
    ///         that used to live here (see class docs).
    function setCreatorFeeRecipientByFactory(address newRecipient) external onlyFactory {
        require(newRecipient != address(0), "zero address");
        emit CreatorFeeRecipientChanged(creatorFeeRecipient, newRecipient);
        creatorFeeRecipient = newRecipient;
    }

    // ── Fee claiming ─────────────────────────────────────────────────────

    /// @notice Only the factory may call this — it does so on behalf of the address
    ///         it already knows is its own platformFeeRecipient (see
    ///         ArrowFactoryStableClone.claimPlatformFeesFor), same inversion as above.
    function claimPlatformFeesTo(address recipient) external onlyFactory returns (uint256 amount) {
        amount = platformFeesAccrued;
        platformFeesAccrued = 0;
        if (amount > 0) {
            migrating = true; // reuse the "internal, untaxed, uncapped" path for payout
            _transfer(address(this), recipient, amount);
            migrating = false;
        }
        emit FeesClaimed(recipient, amount, true);
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
