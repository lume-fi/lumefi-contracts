// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IBasisAsset.sol";
import "../interfaces/IBoardroom.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IRegulationStats.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IUFragmentsPolicy.sol";

import "../utils/ContractGuard.sol";

/**
 * @title Treasury
 * @notice Manages seigniorage allocation and expansion for a multi-peg system.
 * @dev Supports multiple peg tokens (e.g., LUME and future lfUSD) using oracle price feeds.
 *      In each epoch, new tokens are minted based on the peg token price and then distributed
 *      among the Boardroom, Collateral Reserves, and Development Fund.
 *      This contract is upgradeable via OwnableUpgradeable.
 */
contract Treasury is ITreasury, ContractGuard, ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // Epoch management
    uint256 public startTime;
    uint256 public lastEpochTime;
    uint256 private epoch_ = 0;
    uint256 private epochLength_ = 0;

    // Core token components
    address public nova;
    address public novaOracle;
    address public override boardroom;

    // Price parameters (scaled by 1e18)
    uint256 public priceOne; // Target price (1e18)
    uint256 public priceCeiling; // Price above which expansion is triggered
    uint256 public priceLowerRangeToRebase; // Price below which rebase down is triggered
    uint256 public priceUpperRangeToRebase; // Price above which rebase up is triggered

    // Bootstrap parameters (initial fixed expansion for a number of epochs)
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    // Seigniorage salary (amount of LUME minted during expansion epochs)
    uint256 public allocateSeigniorageSalary;

    // Fund addresses and their shared percentages (in basis points)
    address public override collateralReserves;
    uint256 public override collateralReservesSharedPercent; // e.g., 2000 = 20%
    address public override devFund;
    uint256 public override devFundSharedPercent; // e.g., 1000 = 10%

    // Multi-Peg configuration
    address[] public pegTokens; // e.g., [LUME]
    mapping(address => address) public pegTokenOracle; // Oracle for each peg token
    mapping(address => address) public pegTokenOrchestrator; // Rebase orchestrator for each peg token
    mapping(address => address[]) public pegTokenLockedAccounts; // Locked accounts for each peg token
    mapping(address => uint256) public pegTokenEpochStart; // Epoch start for each peg token
    mapping(address => uint256) public pegTokenSupplyTarget; // Supply target for expansion
    mapping(address => uint256) public pegTokenMaxSupplyExpansionPercent; // Max expansion percent (e.g., 15000 = 1.5%)
    mapping(uint256 => mapping(address => bool)) public hasAllocatedPegToken; // Allocation flag per epoch per peg token

    // Access control for share printing and strategy.
    mapping(address => mapping(address => bool)) public tokenPrinters;
    mapping(address => bool) public strategist;

    address public theAI; // Address of the project AI.
    mapping(uint256 => mapping(address => uint256)) public aiGovernedExpansionPercent;

    /* =================== ADDED VARIABLES FOR PROXY COMPATIBILITY =================== */
    // Reserved for future variables added for proxy to work

    /* ========== EVENTS ========== */

    event FundingAdded(address indexed pegToken, uint256 indexed epoch, uint256 price, uint256 expanded, uint256 rebasedDown, uint256 boardroomFunded, uint256 collateralReservesFunded, uint256 devFunded);

    // Setter events (only new value(s) emitted)
    event BoardroomUpdated(address indexed newBoardroom);
    event NovaOracleUpdated(address indexed newOracle);
    event TheAIUpdated(address indexed newTheAI);
    event RegulationStatsUpdated(address indexed newRegulationStats);
    event PriceCeilingUpdated(uint256 newPriceCeiling);
    event PriceLowerRangeUpdated(uint256 newPriceLowerRange);
    event PriceUpperRangeUpdated(uint256 newPriceUpperRange);
    event TokenPrinterToggled(address indexed token, address indexed account, bool newStatus);
    event BootstrapUpdated(uint256 newBootstrapEpochs, uint256 newBootstrapSupplyExpansionPercent);
    event ExtraFundsUpdated(address newCollateralReserves, uint256 newCollateralReservesSharedPercent, address newDevFund, uint256 newDevFundSharedPercent);
    event PegTokenAdded(address indexed pegToken);
    event PegTokenConfigUpdated(address indexed pegToken, address newOracle, address newOrchestrator, uint256 newEpochStart, uint256 newSupplyTarget, uint256 newExpansionPercent);
    event PegTokenLockedAccountAdded(address indexed pegToken, address indexed lockedAccount);
    event AllocateSeigniorageSalaryUpdated(uint256 newSalary);
    event AIGovernedExpansionPercentUpdated(uint256 epoch, address indexed pegToken, uint256 newPercentage);
    event OperatorTransferred(address indexed targetContract, address indexed newOperator);
    event GovernanceRecovered(address indexed token, uint256 amount, address indexed to);

    /* ========== ERRORS ========== */
    error UnauthorizedCall();

    /* ========== MODIFIERS ========== */

    /**
     * @dev Ensures that the next epoch has started.
     */
    modifier checkEpoch() {
        uint256 _nextEpochPoint = nextEpochPoint();
        require(block.timestamp >= _nextEpochPoint, "Treasury: not opened");
        _;
        lastEpochTime = _nextEpochPoint;
        epoch_ += 1;
    }

    /**
     * @notice Modifier to restrict calls to only the AI or the owner.
     */
    modifier onlyAI() {
        if (msg.sender != owner() && msg.sender != theAI) {
            revert UnauthorizedCall();
        }
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Returns the current epoch.
     */
    function epoch() public view override returns (uint256) {
        return epoch_;
    }

    /**
     * @notice Returns the timestamp for the next epoch.
     */
    function nextEpochPoint() public view override returns (uint256) {
        return lastEpochTime + nextEpochLength();
    }

    /**
     * @notice Returns the length (in seconds) of the next epoch.
     */
    function nextEpochLength() public view override returns (uint256) {
        return epochLength_;
    }

    /**
     * @notice Gets the peg token price by consulting its oracle.
     * @param _token The peg token address.
     * @return The peg token price scaled by 1e18.
     */
    function getPegTokenPrice(address _token) public view override returns (uint256) {
        uint256 _decimals = IERC20Metadata(_token).decimals();
        try IOracle(pegTokenOracle[_token]).consult(_token, (10 ** _decimals)) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: oracle failed");
        }
    }

    /**
     * @notice Gets the peg token TWAP price from its oracle.
     * @param _token The peg token address.
     * @return The updated peg token price scaled by 1e18.
     */
    function getPegTokenUpdatedPrice(address _token) public view override returns (uint256) {
        uint256 _decimals = IERC20Metadata(_token).decimals();
        try IOracle(pegTokenOracle[_token]).twap(_token, (10 ** _decimals)) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: oracle failed");
        }
    }

    /**
     * @notice Returns the boardroom's share percentage (after subtracting reserved shares).
     */
    function boardroomSharedPercent() external view override returns (uint256) {
        return 10000 - collateralReservesSharedPercent - devFundSharedPercent;
    }

    /**
     * @notice Checks if an account is allowed to print token shares.
     * @param _token The token address.
     * @param _account The account address.
     * @return True if allowed.
     */
    function isTokenPrinter(address _token, address _account) external view override returns (bool) {
        return tokenPrinters[_token][_account];
    }

    /**
     * @notice Returns the number of peg tokens configured.
     */
    function pegTokenLength() external view returns (uint256) {
        return pegTokens.length;
    }

    /**
     * @notice Returns the total locked balance of a peg token (excluded from circulating supply).
     * @param _token The peg token address.
     * @return The locked balance.
     */
    function getPegTokenLockedBalance(address _token) public view override returns (uint256) {
        uint256 len = pegTokenLockedAccounts[_token].length;
        uint256 lockedBalance = 0;
        for (uint256 i = 0; i < len; i++) {
            lockedBalance += IERC20(_token).balanceOf(pegTokenLockedAccounts[_token][i]);
        }
        return lockedBalance;
    }

    /**
     * @notice Returns the circulating supply of a peg token.
     * @param _token The peg token address.
     * @return The circulating supply.
     */
    function getPegTokenCirculatingSupply(address _token) public view override returns (uint256) {
        return IERC20(_token).totalSupply() - getPegTokenLockedBalance(_token);
    }

    /**
     * @notice Calculates the expansion rate for a peg token.
     * @param _pegToken The peg token address.
     * @return The expansion rate in basis points (e.g. 1% = 1e16).
     */
    function getPegTokenExpansionRate(address _pegToken) public view override returns (uint256) {
        uint256 startEpoch = pegTokenEpochStart[_pegToken];
        if (startEpoch <= epoch_ + 1) {
            if (epoch_ < bootstrapEpochs) {
                return bootstrapSupplyExpansionPercent;
            }
            uint256 twap = getPegTokenUpdatedPrice(_pegToken);
            if (twap > priceCeiling) {
                uint256 percentage = twap - priceOne;
                uint256 maxExpansion = pegTokenMaxSupplyExpansionPercent[_pegToken];
                if (percentage > maxExpansion) {
                    percentage = maxExpansion;
                }
                return percentage;
            }
        }
        return 0;
    }

    /**
     * @notice Returns the expansion amount for a peg token.
     * @param _pegToken The peg token address.
     * @return The expansion amount.
     */
    function getPegTokenExpansionAmount(address _pegToken) external view override returns (uint256) {
        uint256 rate = getPegTokenExpansionRate(_pegToken);
        return (getPegTokenCirculatingSupply(_pegToken) * rate) / 1e6;
    }

    /* ========== GOVERNANCE FUNCTIONS ========== */

    /**
     * @notice Initializes the Treasury contract.
     * @param _tokens Array with addresses for LUME and NOVA.
     * @param _oracles Array with oracle addresses for LUME and NOVA.
     * @param _orchestrator The orchestrator address for LUME.
     * @param _farmingPool Address for the farming pool (used as a locked account).
     * @param _epochLength Epoch length in seconds.
     * @param _startTime Timestamp when vesting starts.
     * @param _boardroom Boardroom contract address.
     * @param _collateralReserves Address of the Collateral Reserves.
     * @param _devFund Address of the Development Fund.
     */
    function initialize(
        address[] memory _tokens,
        address[] memory _oracles,
        address _orchestrator,
        address _farmingPool,
        uint256 _epochLength,
        uint256 _startTime,
        address _boardroom,
        address _collateralReserves,
        address _devFund
    ) external initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);

        // Set token addresses.
        address _lume = _tokens[0];
        nova = _tokens[1];

        // Configure peg token for LUME.
        pegTokens.push(_lume);
        pegTokenOracle[_lume] = _oracles[0];
        pegTokenOrchestrator[_lume] = _orchestrator;
        pegTokenEpochStart[_lume] = 0;
        pegTokenSupplyTarget[_lume] = 1000000 gwei; // LUME's decimals = 9
        pegTokenMaxSupplyExpansionPercent[_lume] = 15000; // 1.5%

        // Set locked accounts for LUME.
        pegTokenLockedAccounts[_lume] = [_farmingPool, _collateralReserves];

        // Set oracle for NOVA.
        novaOracle = _oracles[1];

        boardroom = _boardroom;

        startTime = _startTime;
        epochLength_ = _epochLength;
        lastEpochTime = _startTime - _epochLength;

        // Price parameters.
        priceOne = 1e18;
        priceCeiling = (priceOne * 10001) / 10000; // 1.0001

        priceLowerRangeToRebase = (priceOne * 9800) / 10000; // 0.98
        priceUpperRangeToRebase = (priceOne * 11800) / 10000; // 1.18

        // Bootstrap settings: first 28 epochs with fixed 1% expansion.
        bootstrapEpochs = 28;
        bootstrapSupplyExpansionPercent = 10000; // 1%

        // Seigniorage salary.
        allocateSeigniorageSalary = (10 ** IERC20Metadata(_lume).decimals()); // 1 unit

        // Extra funds allocation.
        collateralReserves = _collateralReserves;
        collateralReservesSharedPercent = 3000; // 30%
        devFund = _devFund;
        devFundSharedPercent = 1000; // 10%
    }

    /// @notice Sets the boardroom address.
    function setBoardroom(address _boardroom) external onlyOwner {
        require(_boardroom != address(0), "Treasury: zero address");
        boardroom = _boardroom;
        emit BoardroomUpdated(_boardroom);
    }

    /// @notice Sets the NOVA oracle address.
    function setNovaOracle(address _novaOracle) external onlyOwner {
        require(_novaOracle != address(0), "Treasury: zero address");
        novaOracle = _novaOracle;
        emit NovaOracleUpdated(_novaOracle);
    }

    /**
     * @notice Sets the address of the project AI.
     * @param _theAI New AI address.
     */
    function setTheAI(address _theAI) external onlyOwner {
        require(_theAI != address(0), "Treasury: zero address");
        theAI = _theAI;
        emit TheAIUpdated(_theAI);
    }

    /**
     * @notice Sets a new price ceiling.
     * @param _priceCeiling The new price ceiling; must be between priceOne and 1.2 * priceOne.
     */
    function setPriceCeiling(uint256 _priceCeiling) external onlyOwner {
        require(_priceCeiling >= priceOne && _priceCeiling <= (priceOne * 12000) / 10000, "Treasury: out of range");
        priceCeiling = _priceCeiling;
        emit PriceCeilingUpdated(_priceCeiling);
    }

    /**
     * @notice Sets a new price lower range to trigger rebase.
     * @param _priceLowerRangeToRebase The new price lower range (at most 0.99 * priceOne).
     */
    function setPriceLowerRangeToRebase(uint256 _priceLowerRangeToRebase) external onlyOwner {
        require(_priceLowerRangeToRebase <= (priceOne * 9900) / 10000, "Treasury: out of range");
        priceLowerRangeToRebase = _priceLowerRangeToRebase;
        emit PriceLowerRangeUpdated(_priceLowerRangeToRebase);
    }

    /**
     * @notice Sets a new price upper range to trigger rebase.
     * @param _priceUpperRangeToRebase The new price upper range (at least 1.01 * priceOne).
     */
    function setPriceUpperRangeToRebase(uint256 _priceUpperRangeToRebase) external onlyOwner {
        require(_priceUpperRangeToRebase >= (priceOne * 10100) / 10000, "Treasury: out of range");
        priceUpperRangeToRebase = _priceUpperRangeToRebase;
        emit PriceUpperRangeUpdated(_priceUpperRangeToRebase);
    }

    /**
     * @notice Toggles the token printer status for a given token and account.
     * @param _token The token address.
     * @param _account The account address.
     */
    function toggleTokenPrinter(address _token, address _account) external onlyOwner {
        tokenPrinters[_token][_account] = !tokenPrinters[_token][_account];
        emit TokenPrinterToggled(_token, _account, tokenPrinters[_token][_account]);
    }

    /**
     * @notice Sets bootstrap parameters.
     * @param _bootstrapEpochs The number of bootstrap epochs.
     * @param _bootstrapSupplyExpansionPercent The fixed expansion percent during bootstrap epochs.
     */
    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOwner {
        require(_bootstrapEpochs <= 90, "Treasury: _bootstrapEpochs out of range");
        require(_bootstrapSupplyExpansionPercent >= 1000 && _bootstrapSupplyExpansionPercent <= 50000, "Treasury: _bootstrapSupplyExpansionPercent out of range");
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
        emit BootstrapUpdated(_bootstrapEpochs, _bootstrapSupplyExpansionPercent);
    }

    /**
     * @notice Sets extra funds addresses and their shared percentages.
     * @param _collateralReserves Address for Collateral Reserves.
     * @param _collateralReservesSharedPercent Share percentage for Collateral Reserves.
     * @param _devFund Address for the Development Fund.
     * @param _devFundSharedPercent Share percentage for Dev Fund.
     */
    function setExtraFunds(address _collateralReserves, uint256 _collateralReservesSharedPercent, address _devFund, uint256 _devFundSharedPercent) external onlyOwner {
        require(_collateralReservesSharedPercent == 0 || _collateralReserves != address(0), "Treasury: zero");
        require(_collateralReservesSharedPercent <= 4500, "Treasury: out of range");
        require(_devFundSharedPercent == 0 || _devFund != address(0), "Treasury: zero");
        require(_devFundSharedPercent <= 1500, "Treasury: out of range");
        collateralReserves = _collateralReserves;
        collateralReservesSharedPercent = _collateralReservesSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
        emit ExtraFundsUpdated(_collateralReserves, _collateralReservesSharedPercent, _devFund, _devFundSharedPercent);
    }

    /// @notice Adds a new peg token.
    function addPegToken(address _token) external onlyOwner {
        require(IERC20(_token).totalSupply() > 0, "Treasury: invalid token");
        pegTokens.push(_token);
        emit PegTokenAdded(_token);
    }

    /**
     * @notice Sets configuration for a peg token.
     * @param _token The peg token address.
     * @param _oracle The oracle address for the peg token.
     * @param _orchestrator The orchestrator address for the peg token.
     * @param _epochStart The starting epoch for the peg token.
     * @param _supplyTarget The supply target for expansion.
     * @param _expansionPercent The maximum expansion percentage (in basis points, where 1% = 10000).
     */
    function setPegTokenConfig(address _token, address _oracle, address _orchestrator, uint256 _epochStart, uint256 _supplyTarget, uint256 _expansionPercent) external onlyOwner {
        pegTokenOracle[_token] = _oracle;
        pegTokenOrchestrator[_token] = _orchestrator;
        pegTokenEpochStart[_token] = _epochStart;
        pegTokenSupplyTarget[_token] = _supplyTarget;
        pegTokenMaxSupplyExpansionPercent[_token] = _expansionPercent;
        emit PegTokenConfigUpdated(_token, _oracle, _orchestrator, _epochStart, _supplyTarget, _expansionPercent);
    }

    /**
     * @notice Adds an account to the locked accounts list for a peg token.
     * @param _token The peg token address.
     * @param _account The account address to add.
     */
    function addPegTokenLockedAccount(address _token, address _account) external onlyOwner {
        require(_account != address(0), "Treasury: invalid address");
        uint256 len = pegTokenLockedAccounts[_token].length;
        for (uint256 i = 0; i < len; i++) {
            if (pegTokenLockedAccounts[_token][i] == _account) return; // Already exists
        }
        pegTokenLockedAccounts[_token].push(_account);
        emit PegTokenLockedAccountAdded(_token, _account);
    }

    /* ========== AI ADMIN FUNCTIONS ========== */

    /**
     * @notice Sets the seigniorage salary for LUME.
     * @param _allocateSeigniorageSalary The new seigniorage salary.
     */
    function setAllocateSeigniorageSalary(uint256 _allocateSeigniorageSalary) external onlyAI {
        require(_allocateSeigniorageSalary <= 50 ** (1 + IERC20Metadata(pegTokens[0]).decimals()), "Treasury: too much");
        allocateSeigniorageSalary = _allocateSeigniorageSalary;
        emit AllocateSeigniorageSalaryUpdated(_allocateSeigniorageSalary);
    }

    /**
     * @notice Sets the AI-governed expansion percentage for a peg token in a given epoch.
     * @param _epoch The epoch.
     * @param _pegToken The peg token address.
     * @param _expandedPercentage The new expansion percentage (in basis points, where 1% = 10000).
     */
    function setAIGovernedExpansionPercent(uint256 _epoch, address _pegToken, uint256 _expandedPercentage) external onlyAI {
        require(_expandedPercentage <= pegTokenMaxSupplyExpansionPercent[_pegToken], "Treasury: expansion too high");
        aiGovernedExpansionPercent[_epoch][_pegToken] = _expandedPercentage;
        emit AIGovernedExpansionPercentUpdated(_epoch, _pegToken, _expandedPercentage);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /**
     * @dev Internal function to update a peg token's price via its oracle.
     * Errors during the update are swallowed.
     * @param _token The peg token address.
     */
    function _updatePegTokenPrice(address _token) internal {
        try IOracle(pegTokenOracle[_token]).update() {} catch {}
    }

    /**
     * @notice Allocates seigniorage for the current epoch.
     * Mints new tokens based on the peg token price and distributes them among the Boardroom, Collateral Reserves, and Development Fund.
     * Can only be called once per epoch.
     */
    function allocateSeigniorage() external onlyOneBlock checkEpoch nonReentrant {
        uint256 ptLength = pegTokens.length;
        for (uint256 i = 0; i < ptLength; ++i) {
            address pegToken = pegTokens[i];
            uint256 tokenEpochStart = pegTokenEpochStart[pegToken];
            if (tokenEpochStart <= epoch_ + 1) {
                _updatePegTokenPrice(pegToken);
                _allocateSeignioragePegToken(epoch_, pegToken);
            }
        }
        // Update the NOVA oracle.
        if (novaOracle != address(0)) {
            try IOracle(novaOracle).update() {} catch {}
        }
        // Mint seigniorage salary.
        if (allocateSeigniorageSalary > 0) {
            IBasisAsset(pegTokens[0]).mint(msg.sender, allocateSeigniorageSalary);
        }
    }

    /**
     * @dev Internal function to allocate seigniorage for a specific peg token.
     * Calculates the expansion amount and distributes minted tokens among funds.
     * @param _epoch The current epoch.
     * @param _pegToken The peg token address.
     */
    function _allocateSeignioragePegToken(uint256 _epoch, address _pegToken) internal {
        if (hasAllocatedPegToken[_epoch + 1][_pegToken]) return;
        hasAllocatedPegToken[_epoch + 1][_pegToken] = true;

        uint256 supply = getPegTokenCirculatingSupply(_pegToken);
        if (supply >= pegTokenSupplyTarget[_pegToken]) {
            // Increase target supply by 20%.
            pegTokenSupplyTarget[_pegToken] = (pegTokenSupplyTarget[_pegToken] * 12000) / 10000;
            // Decrease maximum expansion percentage by 10%.
            pegTokenMaxSupplyExpansionPercent[_pegToken] = (pegTokenMaxSupplyExpansionPercent[_pegToken] * 9000) / 10000;
            if (pegTokenMaxSupplyExpansionPercent[_pegToken] < 2500) {
                pegTokenMaxSupplyExpansionPercent[_pegToken] = 2500; // Minimum 0.25%
            }
        }

        uint256 percentage = 0;
        uint256 pegTokenTwap = getPegTokenPrice(_pegToken);
        if (epoch_ < bootstrapEpochs) {
            percentage = bootstrapSupplyExpansionPercent * 1e12;
        } else if (pegTokenTwap > priceCeiling) {
            percentage = pegTokenTwap - priceOne;
            uint256 mse = pegTokenMaxSupplyExpansionPercent[_pegToken] * 1e12;
            if (percentage > mse) {
                percentage = mse;
            }
        } else if (pegTokenTwap < priceLowerRangeToRebase) {
            address _orchestrator = pegTokenOrchestrator[_pegToken];
            if (_orchestrator != address(0)) {
                uint256 _currentSupply = IERC20(_pegToken).totalSupply();
                uint256 _newSupply = IUFragmentsPolicy(_orchestrator).rebase();
                if (_newSupply < _currentSupply) {
                    uint256 rebasedDown = _currentSupply - _newSupply;
                    IBoardroom(boardroom).sync();
                    emit FundingAdded(_pegToken, _epoch + 1, pegTokenTwap, 0, rebasedDown, 0, 0, 0);
                }
            }
        } else if (pegTokenTwap > priceUpperRangeToRebase) {
            // TODO: implement rebase up
        }

        if (percentage > 0) {
            if (aiGovernedExpansionPercent[_epoch + 1][_pegToken] > 0) {
                percentage = aiGovernedExpansionPercent[_epoch + 1][_pegToken] * 1e12;
            }
            uint256 expanded = (supply * percentage) / 1e18;
            uint256 collateralReservesAmount = 0;
            uint256 devFundAmount = 0;
            uint256 boardroomAmount = 0;
            if (expanded > 0) {
                IBasisAsset(_pegToken).mint(address(this), expanded);
                if (collateralReservesSharedPercent > 0) {
                    collateralReservesAmount = (expanded * collateralReservesSharedPercent) / 10000;
                    IERC20(_pegToken).transfer(collateralReserves, collateralReservesAmount);
                }
                if (devFundSharedPercent > 0) {
                    devFundAmount = (expanded * devFundSharedPercent) / 10000;
                    IERC20(_pegToken).transfer(devFund, devFundAmount);
                }
                boardroomAmount = expanded - collateralReservesAmount - devFundAmount;
                IERC20(_pegToken).safeIncreaseAllowance(boardroom, boardroomAmount);
                IBoardroom(boardroom).allocateSeignioragePegToken(_pegToken, boardroomAmount);
            }
            emit FundingAdded(_pegToken, _epoch + 1, pegTokenTwap, expanded, 0, boardroomAmount, collateralReservesAmount, devFundAmount);
        }
    }

    /**
     * @notice Allows the owner to recover unsupported tokens sent to this contract.
     * @param _token The ERC20 token contract address.
     * @param _amount The amount to recover.
     * @param _to The recipient address.
     */
    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOwner {
        require(_to != address(0), "Treasury: Cannot transfer to zero address");
        _token.safeTransfer(_to, _amount);
        emit GovernanceRecovered(address(_token), _amount, _to);
    }

    /**
     * @notice Transfers operator role of a specified contract.
     * @param _contract The address of the contract whose operator role will be transferred.
     * @param _operator The new operator address.
     */
    function transferContractOperator(address _contract, address _operator) external onlyOwner {
        IBasisAsset(_contract).transferOperator(_operator);
        emit OperatorTransferred(_contract, _operator);
    }
}
