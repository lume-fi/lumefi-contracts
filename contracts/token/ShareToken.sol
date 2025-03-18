// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../owner/Operator.sol";
import "../interfaces/ITreasury.sol";

/**
 * @title ShareToken (NOVA)
 * @notice A burnable, capped ERC20 token with a dynamic, time-based cap.
 *         The cap increases linearly over a vesting period, while burned tokens permanently reduce the minting space.
 */
contract ShareToken is ERC20Burnable, ERC20Capped, Operator {
    // Total supply parameters (using 18 decimals)
    uint256 public constant TOTAL_MAX_SUPPLY = 21000 ether; // 21000 NOVA tokens
    uint256 public constant GENESIS_SUPPLY = 1 ether;

    // Allocation constants
    uint256 public constant LIQUIDITY_MINING_PROGRAM_ALLOCATION = 10500 ether; // 50% allocation
    uint256 public constant COLLATERAL_RESERVES_ALLOCATION = 8400 ether; // 40% allocation
    uint256 public constant DEV_FUND_ALLOCATION = 2099 ether; // ~10% allocation (accounting for genesis supply)

    // Vesting duration for additional minting (730 days = 2 years)
    uint256 public constant VESTING_DURATION = 730 days;

    // Addresses for treasury and reward funds
    address public treasury;
    address public collateralReserves;
    address public devFund;

    // Vesting and reward distribution timing
    uint256 public startTime;
    uint256 public vestingEndTime;
    uint256 public lastClaimedTime;

    // Delay period for auto-claiming rewards in minting and burning functions.
    uint256 public rewardClaimDelay = 24 hours;

    // Reward rates (tokens per second) for collateral reserves and dev funds
    uint256 public collateralReservesRewardRate;
    uint256 public devFundRewardRate;

    // Minting rate for new tokens (per second) over the vesting period
    uint256 public mintingRate;

    // Total tokens burned (which reduce minting space)
    uint256 public totalBurned;

    event TreasuryUpdated(address indexed newTreasury);
    event RewardClaimDelayUpdated(uint256 newDelay);

    /**
     * @dev Modifier to restrict functions to treasury or approved token printers.
     */
    modifier onlyPrinter() {
        require(treasury == msg.sender || ITreasury(treasury).isTokenPrinter(address(this), msg.sender), "!printer");
        _;
    }

    /**
     * @notice Constructor sets up the token, vesting schedule, and reward rates.
     * @param _startTime The timestamp when vesting starts.
     * @param _collateralReserves Address for collateral reserves rewards.
     * @param _devFund Address for dev fund rewards.
     */
    constructor(uint256 _startTime, address _collateralReserves, address _devFund) ERC20Capped(TOTAL_MAX_SUPPLY) ERC20("NOVA", "NOVA") {
        // Mint the initial GENESIS_SUPPLY to the deployer
        _mint(msg.sender, GENESIS_SUPPLY);

        startTime = _startTime; // 1742904000: Tuesday, 25 March 2025 12:00:00 UTC
        vestingEndTime = _startTime + VESTING_DURATION;
        lastClaimedTime = _startTime;

        collateralReservesRewardRate = COLLATERAL_RESERVES_ALLOCATION / VESTING_DURATION;
        devFundRewardRate = DEV_FUND_ALLOCATION / VESTING_DURATION;

        mintingRate = (TOTAL_MAX_SUPPLY - GENESIS_SUPPLY) / VESTING_DURATION;

        require(_collateralReserves != address(0), "Invalid collateralReserves address");
        collateralReserves = _collateralReserves;
        require(_devFund != address(0), "Invalid devFund address");
        devFund = _devFund;
    }

    /* ========== SETTERS ========== */

    /**
     * @notice Sets the treasury address.
     * @param _treasury The address of the treasury.
     * @dev Only callable by the owner.
     */
    function setTreasuryAddress(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Treasury cannot be zero");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /**
     * @notice Sets the collateral reserves address.
     * @param _collateralReserves The address for collateral reserves rewards.
     * @dev Only callable by the owner.
     */
    function setCollateralReserves(address _collateralReserves) external onlyOwner {
        require(_collateralReserves != address(0), "Collateral reserves cannot be zero");
        collateralReserves = _collateralReserves;
    }

    /**
     * @notice Sets the dev fund address.
     * @param _devFund The address for dev fund rewards.
     * @dev Only callable by the owner.
     */
    function setDevFund(address _devFund) external onlyOwner {
        require(_devFund != address(0), "Dev fund cannot be zero");
        devFund = _devFund;
    }

    /**
     * @notice Sets the reward claim delay period.
     * @param _newDelay The new delay period (in seconds) for auto-claiming rewards.
     * @dev Only callable by the owner.
     */
    function setRewardClaimDelay(uint256 _newDelay) external onlyOwner {
        require(_newDelay >= 1 hours, "Too short");
        rewardClaimDelay = _newDelay;
        emit RewardClaimDelayUpdated(_newDelay);
    }

    /* ========== VIEWS ========== */

    /**
     * @notice Returns the dynamic cap on the token's total supply.
     * @return The current cap which increases linearly over the vesting period and is reduced by burned tokens.
     */
    function cap() public view override returns (uint256) {
        uint256 currentTime = block.timestamp;
        if (currentTime <= startTime) {
            return GENESIS_SUPPLY;
        }
        if (currentTime > vestingEndTime) {
            currentTime = vestingEndTime;
        }
        uint256 dynamicCap = GENESIS_SUPPLY + ((currentTime + 1 - startTime) * mintingRate);
        // Adjust for tokens burned
        if (dynamicCap <= totalBurned) {
            return 0;
        } else {
            dynamicCap -= totalBurned;
        }
        if (dynamicCap > TOTAL_MAX_SUPPLY) {
            dynamicCap = TOTAL_MAX_SUPPLY;
        }
        return dynamicCap;
    }

    /**
     * @notice Returns the pending rewards for collateral reserves and dev funds since the last claim.
     * @return pendingReserves The pending rewards for collateral reserves.
     * @return pendingDev The pending rewards for the dev fund.
     */
    function unclaimedFunds() public view returns (uint256 pendingReserves, uint256 pendingDev) {
        uint256 currentTime = block.timestamp;
        if (currentTime > vestingEndTime) {
            currentTime = vestingEndTime;
        }
        if (lastClaimedTime < currentTime) {
            uint256 elapsed = currentTime - lastClaimedTime;
            pendingReserves = elapsed * collateralReservesRewardRate;
            pendingDev = elapsed * devFundRewardRate;
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Claims pending rewards and mints tokens to collateral reserves and dev fund addresses.
     * @dev Rewards are based on the elapsed time since the last claim.
     */
    function claimRewards() public {
        (uint256 pendingReserves, uint256 pendingDev) = unclaimedFunds();
        if (pendingReserves > 0) {
            _mint(collateralReserves, pendingReserves);
        }
        if (pendingDev > 0) {
            _mint(devFund, pendingDev);
        }
        lastClaimedTime = block.timestamp;
    }

    /**
     * @notice Mints new tokens to a recipient, ensuring the total supply does not exceed the dynamic cap.
     * @param recipient_ The address receiving the minted tokens.
     * @param amount_ The requested amount of tokens to mint.
     * @return A boolean indicating whether the minting operation was successful.
     * @dev Only callable by the treasury or approved token printers.
     */
    function mint(address recipient_, uint256 amount_) public onlyPrinter returns (bool) {
        if (lastClaimedTime + rewardClaimDelay <= block.timestamp) {
            claimRewards();
        }
        uint256 currentSupply = totalSupply();
        uint256 maxSupply = cap();
        if (currentSupply > maxSupply) return false;
        if (currentSupply + amount_ > maxSupply) {
            amount_ = maxSupply - currentSupply;
        }
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        return balanceOf(recipient_) > balanceBefore;
    }

    /**
     * @notice Burns tokens and updates the total burned count, reducing available minting space.
     * @param amount The amount of tokens to burn.
     * @dev Overridden from ERC20Burnable. Auto-claims rewards if the reward claim delay has elapsed.
     */
    function burn(uint256 amount) public override {
        if (lastClaimedTime + rewardClaimDelay <= block.timestamp) {
            claimRewards();
        }
        totalBurned += amount;
        super.burn(amount);
    }

    /**
     * @dev Internal function override to resolve multiple inheritance for _update.
     * @param from The address from which tokens are transferred.
     * @param to The address to which tokens are transferred.
     * @param value The amount of tokens transferred.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        ERC20Capped._update(from, to, value);
    }

    /**
     * @notice Allows the owner to recover any unsupported ERC20 tokens that were sent to this contract.
     * @param token The ERC20 token to recover.
     * @param amount The amount of tokens to recover.
     * @param to The address that will receive the recovered tokens.
     * @dev Only callable by the owner.
     */
    function governanceRecoverUnsupported(IERC20 token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Cannot transfer to zero address");
        token.transfer(to, amount);
    }
}
