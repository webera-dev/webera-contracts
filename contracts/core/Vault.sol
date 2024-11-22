// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IFactory} from "../interfaces/IFactory.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Vault is ERC4626Upgradeable, OwnableUpgradeable, ReentrancyGuard {
    // protocolFee is the fee charged by the protocol when harvesting profits, Basic Points 0.5% = 50, 1% = 100, 5% = 500,
    uint256 public protocolFee;
    // 10000 bps = 100%
    uint256 public constant MAX_BPS = 10000;
    // for profit locking calculation, 1_000_000_000_000 bps = 100%
    uint256 public constant MAX_BPS_EXTENDED = 1_000_000_000_000;

    address public accountant; // responsible for accounting the fees and refunds, it also receives the fees

    // Maximum number of strategies the vault can have
    uint256 public constant MAX_STRATEGIES = 5;

    // An array to store all strategies of the vault
    address[] public strategies;

    // Ordering of strategies to withdraw from by the `currentDebt`, if the first strategy doesn't have enough assets, the next one is used
    // `withdrawQueue` is the sorted array of strategies
    // `withdraw` progress will stop if encounter `address(0)` in the queue
    address[] public withdrawQueue;

    // Total debt allocated to strategies
    uint256 public totalOutstandingDebt;
    // total idle assets currently in the vault, it is `totalAssets` - `totalOutstandingDebt`
    uint256 public totalIdleAssets;
    // min idle assets to keep in the vault for users to withdraw
    uint256 public minTotalIdleAssets;

    // Profit vesting
    uint256 public profitMaxUnlockTime; // seconds to lock the profit
    uint256 public fullProfitUnlockTime; // timestamp to unlock the full profit
    uint256 public profitUnlockingRate; // Shares to unlock per second, goes with `MAX_BPS_EXTENDED`
    uint256 public lastProfitHarvest;

    // withdraw limit to prevent from draining the vault
    uint256 internal _withdrawLimit = type(uint256).max;

    struct StrategyParams {
        // is strategy activated
        bool isActivated;
        // last harvest timestamp, called by vault to the strategy
        uint256 lastHarvest;
        // current debt of the strategy, vault allocates debt to the strategy
        uint256 currentDebt;
        // max debt of the strategy can borrow from vault
        uint256 maxDebt;
    }

    mapping(address => StrategyParams) internal _strategyParams;

    // *** Events ***
    event Harvest(
        address indexed strategy,
        uint256 profit,
        uint256 loss,
        uint256 currentDebt,
        uint256 totalFees,
        uint256 totalRefunds
    );

    event DebtUpdated(address indexed strategy, uint256 oldDebt, uint256 newDebt);
    event StrategyAdded(address indexed strategy, uint256 length);
    event StrategyRevoked(address indexed strategy);
    event WithdrawQueueUpdated(address[] oldStrategyQueue, address[] newStrategyQueue);
    event SetProfitMaxUnlockTime(uint256 profitMaxUnlockTime);

    // *** Initilizer ***
    function initialize(
        address owner_,
        address asset_,
        string memory vaultTokenName_,
        string memory vaultTokenSymbol_,
        uint256 profitMaxUnlockTime_,
        uint256 protocolFee_
    ) public initializer {
        __Ownable_init(owner_);
        __ERC4626_init(IERC20(asset_));
        __ERC20_init(vaultTokenName_, vaultTokenSymbol_);

        profitMaxUnlockTime = profitMaxUnlockTime_;
        protocolFee = protocolFee_;
        accountant = owner_;

        _withdrawLimit = type(uint256).max;
    }

    // ** Share Management (ERC4626) **

    /// @dev See {IERC4626-deposit}.
    /// @dev Deposit assets to the vault
    /// @param assets The amount of assets to deposit
    /// @param receiver The receiver of the shares
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /// @dev Deposit assets to the vault
    /// @param caller The caller of the function
    /// @param receiver The receiver of the shares
    /// @param assets The amount of assets to deposit
    /// @param shares The amount of shares to mint
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        IERC20(asset()).transferFrom(caller, address(this), assets);

        _mint(receiver, shares);

        totalIdleAssets += assets;

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev See {IERC4626-withdraw}.
    /// @dev Withdraw assets from the vault
    /// @notice check `setWithdrawalQueue` function for further details of withdrawal ordering and behavior.
    /// @param assets The amount of assets to withdraw
    /// @param receiver The receiver of the asset amount
    /// @param owner The owner of the shares, msg.sender has the spend allowance of owner's shares
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        nonReentrant
        returns (uint256)
    {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        if (assets > totalIdleAssets) {
            uint256 assetsToPull = assets - totalIdleAssets;

            for (uint256 i = 0; i < withdrawQueue.length; i++) {
                // If the strategy is not activated, stop withdrawing from strategies
                if (withdrawQueue[i] == address(0)) {
                    break;
                }

                // Pull assets until `assetsToPull` comes to zero
                if (assetsToPull == 0) {
                    break;
                }

                address strategyToPullFrom = withdrawQueue[i];
                // To avoid pulling more than the strategy current debt
                uint256 assetsToPullFromStrategy =
                    Math.min(assetsToPull, _strategyParams[strategyToPullFrom].currentDebt);
                // Withdraw assets from the strategy
                uint256 actualAssetsWithdrawn = _withdrawFromStrategy(strategyToPullFrom, assetsToPullFromStrategy);

                // the loop should continue
                if (actualAssetsWithdrawn == 0) {
                    continue;
                }

                // Update the remaining assets to pull
                assetsToPull -= actualAssetsWithdrawn;
            }
        }

        uint256 shares = previewWithdraw(assets);

        require(totalIdleAssets >= assets, "Vault: Not enough assets in the vault");

        _withdraw(_msgSender(), receiver, owner, assets, shares);

        totalIdleAssets -= assets;

        return shares;
    }

    /**
     * @dev No implementation {IERC4626-mint}.
     */
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        revert("Vault: Minting shares is not allowed");
    }

    /**
     * @dev No implementation for {IERC4626-redeem}.
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        revert("Vault: Redeeming shares is not allowed");
    }

    // *** Harvest ***

    /**
     * @dev Harvest a strategy means comparing the debt the strategy has taken with the current amount of assets it is making
     * Profit is the positive difference between the current assets and the debt
     * @notice Asset profit is put into vesting to avoid price spikes
     * Any fees occurred during the harvest are sent to the `accountant` immediately
     * It is chronically called by the system admin
     */
    function harvest(address strategy_) public onlyOwner {
        IERC4626 strategy = IERC4626(strategy_);
        StrategyParams memory strategyParameters = _strategyParams[strategy_];

        // Total shares of strategy in the vault
        // Calculate profit and loss based on the current debt of the strategy and the actual assets in the strategy
        (uint256 profit, uint256 loss) = _calcuateProfitLoss(
            strategy.convertToAssets(strategy.balanceOf(address(this))), strategyParameters.currentDebt
        );

        // Process protocol fee + refund
        // totalFees are sent to the accountant as protocol fee
        // totalRefunds the amount vault pulls from `accoutant` to reduce the loss
        (uint256 totalFees, uint256 totalRefunds) = _accountFees(profit, loss);

        // Make sure accountant has enough funds to refund
        if (totalRefunds > 0) {
            totalRefunds = Math.min(
                Math.min(totalRefunds, IERC20(asset()).balanceOf(accountant)),
                IERC20(asset()).allowance(accountant, address(this))
            );
        }

        // Shares to burn is the amount that vault will burn to reduce the PPS (Price per share) of strategy
        // = loss (need to burn shares) + totalFees (need to burn shares)
        uint256 sharesToBurn = strategy.convertToShares(loss + totalFees);

        // Shares to lock is the amount that vault will receives to increase the PPS (Price per share) of strategy
        uint256 sharesToLock = strategy.convertToShares(profit + totalRefunds);

        // shares to accountant as protocol fee
        uint256 totalFeeShares;
        if (loss + totalFees != 0) {
            totalFeeShares = sharesToBurn * totalFees / (loss + totalFees);
        }

        // Sync shares minted/burnt by vault
        _syncAssetsAndShares(sharesToLock, sharesToBurn);

        // Calcuate new `sharesToLock` and no need to use `sharesToBurn` from now on
        if (sharesToLock > sharesToBurn) {
            sharesToLock -= sharesToBurn;
        } else {
            sharesToLock = 0;
        }

        // Pull refunds from the accountant
        if (totalRefunds > 0) {
            IERC20(asset()).transferFrom(accountant, address(this), totalRefunds);
            totalIdleAssets += totalRefunds;
        }

        // Update strategy params
        _updateStrategyParams(strategy_, strategyParameters, profit, loss);

        // mint shares to accountant
        // Since accoutant is responsible for accounting the fees and refunds, it also receives the fees and refunds to vault for losses
        // `accountant` is only for receiving the fees
        if (totalFeeShares > 0) _mint(accountant, totalFeeShares);

        // Update unlocking schedule of locked shares in vault
        _updateUnlockingSchedule(sharesToLock);

        // double check the total locked shares
        if (loss + totalFees > profit + totalRefunds || profitMaxUnlockTime == 0) {
            totalFees = convertToAssets(totalFeeShares);
        }

        emit Harvest(strategy_, profit, loss, _strategyParams[strategy_].currentDebt, totalFees, totalRefunds);
    }

    /**
     * @dev Harvest all strategies
     */
    function harvestAll() public onlyOwner {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (_strategyParams[strategies[i]].isActivated) {
                harvest(strategies[i]);
            }
        }
    }

    /**
     * @dev Calculate profit and loss
     * @param vaultAssetsInStrategy_ the amount of assets in the strategy
     * @param strategyDebt_ the amount of debt the strategy has taken
     * @return profit the profit from the harvest
     * @return loss the loss from the harvest
     */
    function _calcuateProfitLoss(uint256 vaultAssetsInStrategy_, uint256 strategyDebt_)
        internal
        pure
        returns (uint256 profit, uint256 loss)
    {
        if (vaultAssetsInStrategy_ > strategyDebt_) {
            profit = vaultAssetsInStrategy_ - strategyDebt_;
            loss = 0;
        } else {
            profit = 0;
            loss = strategyDebt_ - vaultAssetsInStrategy_;
        }
    }

    /**
     * @dev sync assets and shares of vault
     * @param sharesToLock_ the amount of shares to lock
     * @param sharesToBurn_ the amount of shares to burn
     */
    function _syncAssetsAndShares(uint256 sharesToLock_, uint256 sharesToBurn_) internal {
        // The desired ending supply of the vault token
        uint256 endingSupply = totalSupply() + sharesToLock_ - sharesToBurn_;

        if (endingSupply > totalSupply()) {
            // Mint more shares to the vault
            _mint(address(this), endingSupply - totalSupply());
        } else if (endingSupply < totalSupply()) {
            // Burn shares from the vault
            _burn(address(this), totalSupply() - endingSupply);
        }
    }

    /**
     * @dev Update unlocking schedule
     * @param newSharesToLock_ the new amount of shares to lock
     */
    function _updateUnlockingSchedule(uint256 newSharesToLock_) internal {
        uint256 totalLockedShares = balanceOf(address(this));
        if (totalLockedShares > 0) {
            uint256 previousLockedTime;

            if (fullProfitUnlockTime > block.timestamp) {
                // If the full profit is not unlocked yet, there are locked shares remaining
                previousLockedTime = (totalLockedShares - newSharesToLock_) * (fullProfitUnlockTime - block.timestamp);
            }

            // `newProfitLockingPeriod` is a weighted average between the remaining time of the previously locked shares and the profit_max_unlock_time
            uint256 newProfitLockingPeriod =
                (previousLockedTime + newSharesToLock_ * profitMaxUnlockTime) / totalLockedShares;

            if (newProfitLockingPeriod > 0) {
                // shares unlock per second
                profitUnlockingRate = totalLockedShares * MAX_BPS_EXTENDED / newProfitLockingPeriod;
            }

            // How long until all locked shares are unlocked
            fullProfitUnlockTime = block.timestamp + newProfitLockingPeriod;

            // Update the last profit harvest time
            lastProfitHarvest = block.timestamp;
        } else {
            // All shares are unlocked
            fullProfitUnlockTime = 0;
        }
    }

    /**
     * @dev Update `_strategyParams` mapping and `totalOutstandingDebt`
     * @param strategy_ address of the strategy
     * @param oldStrategyParams_ old strategy params
     * @param profit_ profit from the harvest
     * @param loss_ loss from the harvest
     */
    function _updateStrategyParams(
        address strategy_,
        StrategyParams memory oldStrategyParams_,
        uint256 profit_,
        uint256 loss_
    ) internal {
        if (profit_ > 0) {
            _strategyParams[strategy_].currentDebt = oldStrategyParams_.currentDebt + profit_;

            totalOutstandingDebt += profit_;
        } else if (loss_ > 0) {
            _strategyParams[strategy_].currentDebt = oldStrategyParams_.currentDebt - loss_;

            totalOutstandingDebt -= loss_;
        }

        _strategyParams[strategy_].lastHarvest = block.timestamp;
    }

    /**
     * @dev Accountant accounts the fees + refunds from profit/loss
     * @param profit from the harvest
     * @param loss from the harvest
     */
    function _accountFees(uint256 profit, uint256 loss)
        internal
        view
        returns (uint256 totalFees, uint256 totalRefunds)
    {
        totalFees = 0;
        if (profit != 0) {
            // fees are calculated based on the profit
            totalFees = profit * protocolFee / MAX_BPS;
        }

        // accountant refunds the loss, max is all assets of accountant
        totalRefunds = Math.min(loss, IERC20(asset()).balanceOf(accountant));
    }

    // ** Strategy Management **

    /**
     * @dev Add a new strategy to the vault
     * @param strategy address of the strategy
     * @param maxDebt the maximum debt the strategy can borrow from the vault
     */
    function addStrategy(address strategy, uint256 maxDebt) external onlyOwner {
        require(strategy != address(0), "ZERO_ADDRESS");
        require(_strategyParams[strategy].isActivated == false, "Vault: Strategy already activated");
        require(strategies.length < MAX_STRATEGIES, "Vault: Max strategies reached");

        // add new strategy to _strategyParams
        _strategyParams[strategy] =
            StrategyParams({isActivated: true, lastHarvest: block.timestamp, currentDebt: 0, maxDebt: maxDebt});

        strategies.push(strategy);
        withdrawQueue.push(strategy);

        emit StrategyAdded(strategy, strategies.length);
    }

    /**
     * @dev Revoke a strategy, it can be re-added later
     * @param strategy address of the strategy
     */
    function revokeStrategy(address strategy) external onlyOwner {
        require(_strategyParams[strategy].isActivated == true, "Vault: Strategy not activated");

        // Check if the strategy has any debt
        if (_strategyParams[strategy].currentDebt > 0) {
            // Realize the full of strategy's debt
            uint256 loss = _strategyParams[strategy].currentDebt;
            // sync total vault debt
            totalOutstandingDebt -= loss;
        }

        // remove strategy from _strategyParams
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == strategy) {
                strategies[i] = strategies[strategies.length - 1];
                strategies.pop();
                break;
            }
        }

        // remove strategy from withdrawQueue
        for (uint256 i = 0; i < withdrawQueue.length; i++) {
            if (withdrawQueue[i] == strategy) {
                withdrawQueue[i] = withdrawQueue[withdrawQueue.length - 1];
                withdrawQueue.pop();
                break;
            }
        }

        emit StrategyRevoked(strategy);
    }

    function updateStrategyMaxDebt(address strategy_, uint256 maxDebt_) external onlyOwner {
        require(_strategyParams[strategy_].isActivated == true, "Vault: Strategy not activated");
        _strategyParams[strategy_].maxDebt = maxDebt_;
    }

    // ** Debt Management **

    /**
     * @notice Updates the debt (allocated assets) of a given strategy.
     * @dev This function can only be called by the owner of the contract.
     * It adjusts the debt of a strategy by either withdrawing assets from the strategy
     * or depositing assets into the strategy to match the target debt.
     * @param strategy_ The address of the strategy to update the debt for.
     * @param targetDebt_ The target debt amount for the strategy.
     * Requirements:
     * - The strategy must be activated.
     * - The target debt must be different from the current debt.
     * - The vault must have enough idle assets to cover the minimum required idle assets.
     * - The target debt must not exceed the strategy's maximum allowable debt.
     * Emits a {DebtUpdated} event.
     */
    function updateDebt(address strategy_, uint256 targetDebt_) external onlyOwner {
        require(_strategyParams[strategy_].isActivated == true, "Vault: Strategy not activated");
        uint256 currentDebt = _strategyParams[strategy_].currentDebt;
        require(currentDebt != targetDebt_, "Vault: Target debt is the same as the current debt");
        IERC4626 strategy = IERC4626(strategy_);
        uint256 newDebt;
        if (currentDebt > targetDebt_) {
            // Reduce debt, pull (withdraw) assets from the strategy to the vault
            uint256 assetsToPull = currentDebt - targetDebt_;

            // Secure minimum idle assets
            if (totalIdleAssets + assetsToPull < minTotalIdleAssets) {
                assetsToPull = minTotalIdleAssets - totalIdleAssets;

                // Can't withdraw more than debt
                if (assetsToPull > currentDebt) {
                    assetsToPull = currentDebt;
                }
            }

            // Check how much assets can be pulled from the strategy
            uint256 maxWithdrawable = strategy.maxWithdraw(address(this));
            require(maxWithdrawable != 0, "Vault: Max withdrawable is zero");

            if (assetsToPull > maxWithdrawable) {
                assetsToPull = maxWithdrawable;
            }

            // Withdraw assets from the strategy
            _withdrawFromStrategy(strategy_, assetsToPull);

            newDebt = currentDebt - assetsToPull;
        } else {
            // Increasing strategy debt

            require(targetDebt_ <= _strategyParams[strategy_].maxDebt, "Vault: Target debt exceeds strategy max debt");

            uint256 maxDepositable = strategy.maxDeposit(address(this));
            require(maxDepositable != 0, "Vault: Max depositable is zero");

            // Deposit the difference between the current debt and the target debt
            uint256 assetsToDeposit = targetDebt_ - currentDebt;
            if (assetsToDeposit > maxDepositable) {
                assetsToDeposit = maxDepositable;
            }

            // Secure the minimum idle assets
            require(totalIdleAssets > minTotalIdleAssets, "Vault: Not enough idle assets");

            uint256 availableIdleAssets = totalIdleAssets - minTotalIdleAssets;
            if (assetsToDeposit > availableIdleAssets) {
                assetsToDeposit = availableIdleAssets;
            }

            if (assetsToDeposit > 0) {
                // Approve the strategy to pull the assets
                IERC20(asset()).approve(strategy_, assetsToDeposit);

                // Deposit the funds into the strategy
                uint256 preBalance = IERC20(asset()).balanceOf(address(this));
                strategy.deposit(assetsToDeposit, address(this));
                uint256 postBalance = IERC20(asset()).balanceOf(address(this));

                assetsToDeposit = preBalance - postBalance;

                // Update the vault's total idle and total debt
                totalIdleAssets -= assetsToDeposit;
                totalOutstandingDebt += assetsToDeposit;
            }
            newDebt = currentDebt + assetsToDeposit;

            // Update strategy debt
            _strategyParams[strategy_].currentDebt = newDebt;
        }

        emit DebtUpdated(strategy_, currentDebt, _strategyParams[strategy_].currentDebt);
    }

    /**
     * @dev Withdraw assets from the strategy
     * @param strategy_ address of the strategy
     * @param assetsToWithdraw_ the amount of assets to withdraw
     */
    function _withdrawFromStrategy(address strategy_, uint256 assetsToWithdraw_)
        internal
        returns (uint256 actualAssetsWithdrawn)
    {
        require(strategy_ != address(0), "Vault: No strategy to pull assets from");
        require(_strategyParams[strategy_].isActivated, "Vault: Strategy not activated");
        require(_strategyParams[strategy_].currentDebt >= assetsToWithdraw_, "Vault: Not enough debt in the strategy");

        uint256 assetsPreWithdraw = IERC20(asset()).balanceOf(address(this));
        IERC4626(strategy_).withdraw(assetsToWithdraw_, address(this), address(this));
        uint256 assetsPostWithdraw = IERC20(asset()).balanceOf(address(this));

        actualAssetsWithdrawn = Math.min(assetsPostWithdraw - assetsPreWithdraw, assetsToWithdraw_);

        totalIdleAssets += actualAssetsWithdrawn;
        totalOutstandingDebt -= actualAssetsWithdrawn;

        // update strategy current debt
        _strategyParams[strategy_].currentDebt -= actualAssetsWithdrawn;
    }

    /**
     * @dev Returns the share of losses that a user would take if withdrawing from this strategy
     * This accounts for losses that have been realized at the strategy level but not yet
     * realized at the vault level.
     * e.g. if the strategy has unrealised losses for 10% of its current debt and the user
     * wants to withdraw 1_000 tokens, the losses that they will take is 100 token
     */
    function _assessSharesOfUnrealizedLosses(address strategy_, uint256 assets_needed)
        internal
        view
        returns (uint256 sharesOfLosses)
    {}

    // ** Getters **

    function strategyParams(address strategy_) public view returns (StrategyParams memory) {
        return _strategyParams[strategy_];
    }

    function strategiesLength() external view returns (uint256) {
        return strategies.length;
    }

    function withdrawQueueLength() external view returns (uint256) {
        return withdrawQueue.length;
    }

    function getWithdrawQueue() external view returns (address[] memory) {
        return withdrawQueue;
    }

    function getStrategies() external view returns (address[] memory) {
        return strategies;
    }

    function unlockedShares() public view returns (uint256) {
        return _unlockedShares();
    }

    /**
     * @dev Returns the amount of shares that have been unlocked
     * @return the amount of shares that have been unlocked
     * To avoid PPS spikes, profit shares are unlocked over time
     */
    function _unlockedShares() internal view returns (uint256) {
        uint256 unlockedShares_;
        if (fullProfitUnlockTime > block.timestamp) {
            unlockedShares_ = (block.timestamp - lastProfitHarvest) * profitUnlockingRate / MAX_BPS_EXTENDED;
        } else {
            // All shares are unlocked
            unlockedShares_ = balanceOf(address(this));
        }
        return unlockedShares_;
    }

    /**
     * @dev See {IERC4626-totalAssets}.
     * It is overrided since the assets are moved to the strategies as debt
     * @return the total amount of assets deposited in the vault
     */
    function totalAssets() public view virtual override returns (uint256) {
        return totalIdleAssets + totalOutstandingDebt;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     * It is overrided since some shares are locked due to profits from strategies
     */
    function totalSupply() public view virtual override(ERC20Upgradeable, IERC20) returns (uint256) {
        return super.totalSupply() - _unlockedShares();
    }

    /**
     * @dev Withdraw limit to prevent from draining the vault
     */
    function withdrawLimit() public view returns (uint256) {
        return _withdrawLimit;
    }

    // ** Setters **

    function setProfitMaxUnlockTime(uint256 profitMaxUnlockTime_) external onlyOwner {
        profitMaxUnlockTime = profitMaxUnlockTime_;

        emit SetProfitMaxUnlockTime(profitMaxUnlockTime_);
    }

    /**
     * @dev Set the withdraw queue for the vault
     *     This is order sensitive, specify the addresses in the order in which
     *     funds should be withdrawn (so `queue`[0] is the first Strategy withdrawn
     *     from, `queue`[1] is the second, etc.)
     *
     *     This means that the least impactful Strategy (the Strategy that will have
     *     its core positions impacted the least by having funds removed) should be
     *     at `queue`[0], then the next least impactful at `queue`[1], and so on.
     * @param queue array of strategies
     */
    function setWithdrawQueue(address[] calldata queue) external onlyOwner {
        require(queue.length <= MAX_STRATEGIES, "Vault: Queue exceeds max strategies");

        address[] memory oldQueue = withdrawQueue;

        for (uint256 i = 0; i < queue.length; i++) {
            if (queue[i] == address(0)) {
                require(oldQueue[i] == address(0), "Vault: Cannot remove strategies from queue");
                break;
            }

            require(oldQueue[i] != address(0), "Vault: Cannot add more strategies to queue");
            require(_strategyParams[queue[i]].isActivated, "Vault: Strategy not activated");

            bool existsInOldQueue = false;
            for (uint256 j = 0; j < oldQueue.length; j++) {
                if (queue[j] == address(0)) {
                    existsInOldQueue = true;
                    break;
                }
                if (queue[i] == oldQueue[j]) {
                    existsInOldQueue = true;
                }
                if (j <= i) {
                    continue;
                }
                require(queue[i] != queue[j], "Vault: Duplicate strategies");
            }

            require(existsInOldQueue, "Vault: New strategies not allowed");

            strategies[i] = queue[i];
        }

        emit WithdrawQueueUpdated(oldQueue, queue);
    }

    // ** Emgergency Functions **
    /**
     * @dev Emergency function to withdraw all assets from the vault and strategies
     */
    function emergencyWithdrawAll() external onlyOwner {
        // Withdraw all assets from strategies
        for (uint256 i = 0; i < strategies.length; i++) {
            address strategy = strategies[i];
            if (_strategyParams[strategy].isActivated) {
                uint256 strategyDebt = _strategyParams[strategy].currentDebt;
                if (strategyDebt > 0) {
                    _withdrawFromStrategy(strategy, strategyDebt);
                    _strategyParams[strategy].currentDebt = 0;
                }
            }
        }

        // Withdraw all idle assets from the vault
        uint256 totalAssetsInVault = IERC20(asset()).balanceOf(address(this));
        if (totalAssetsInVault > 0) {
            IERC20(asset()).transfer(owner(), totalAssetsInVault);
        }

        // Reset vault state
        totalOutstandingDebt = 0;
        totalIdleAssets = 0;
    }

    /**
     * @dev Emergency function to withdraw all assets from the vault
     */
    function emergencyVault() external onlyOwner {
        // Withdraw all idle assets from the vault
        uint256 totalAssetsInVault = IERC20(asset()).balanceOf(address(this));
        if (totalAssetsInVault > 0) {
            IERC20(asset()).transfer(owner(), totalAssetsInVault);
        }
    }

    /**
     * @dev Emergency function to withdraw assets from a strategy
     * @param strategy_ address of the strategy
     * @param amount_ the amount of assets to withdraw
     */
    function emergencyStrategy(address strategy_, uint256 amount_) external onlyOwner {
        require(_strategyParams[strategy_].isActivated, "Vault: Strategy not activated");

        _withdrawFromStrategy(strategy_, amount_);

        uint256 strategyDebt = _strategyParams[strategy_].currentDebt;
        if (strategyDebt > 0) {
            if (strategyDebt > amount_) {
                _strategyParams[strategy_].currentDebt -= amount_;
            } else {
                _strategyParams[strategy_].currentDebt = 0;
            }
        }
    }

    // ** Factory config for `TokenizedStrategy` **

    function protocol_fee_config() external view returns (uint16, address) {
        return (uint16(protocolFee), owner());
    }

    uint256[50] private __gap;
}
