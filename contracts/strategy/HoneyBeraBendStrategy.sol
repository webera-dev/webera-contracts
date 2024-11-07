// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseStrategy, ERC20} from "contracts/tokenized-strategy/BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBeraBend} from "contracts/interfaces/IBeraBend.sol";
import {IPoolDataProvider} from "contracts/interfaces/IPoolDataProvider.sol";

contract HoneyBeraBendStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    uint256 public constant MAX_BPS = 10000; // 10000 bps = 100%

    // $HONEY Token on Bera Chain
    address public honeyToken;

    // $aHONEY is the interest bearing token of $HONEY, issued when $HONEY is supplied to Berabend
    address public aHoneyToken;

    // BeraBend main contract address, this is the contract we interact with to supply and withdraw $HONEY
    address public beraBend;

    // Get data from BeraBend
    IPoolDataProvider public beraBendDataProvider;

    // Referral code of Webera for BeraBend
    uint16 public referralCode;

    // If true, the strategy will deploy funds to Berabend after harvesting
    bool public isAutoCompound = true;

    event StrategyHarvestAndReport(uint256 totalAssets);

    constructor(
        address _asset,
        string memory _name,
        address honeyToken_,
        address aHoneyToken_,
        address beraBend_,
        uint16 referralCode_,
        address tokenizedStrategyAddress_,
        address poolDataProvider_
    ) BaseStrategy(_asset, _name, tokenizedStrategyAddress_) {
        require(address(asset) == honeyToken, "HoneyBendingStrategy: asset must be honeyToken");

        honeyToken = honeyToken_;
        aHoneyToken = aHoneyToken_;
        beraBend = beraBend_;
        referralCode = referralCode_;
        beraBendDataProvider = IPoolDataProvider(poolDataProvider_);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        _checkAllowance(beraBend, _amount);
        IBeraBend(beraBend).supply(address(asset), _amount, address(this), referralCode);
    }

    function _checkAllowance(address _to, uint256 _amount) internal {
        if (IERC20(asset).allowance(address(this), _to) < _amount) {
            IERC20(asset).approve(_to, type(uint256).max);
        }
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed, this could be type(uint256).max for withdraw all assets
     */
    function _freeFunds(uint256 _amount) internal override {
        IBeraBend(beraBend).withdraw(address(asset), _amount, address(this));
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        uint256 aHoneyBalance = IERC20(aHoneyToken).balanceOf(address(this));

        // withdraw all assets from beraBend
        if (aHoneyBalance > 0) {
            // max withdraw amount using all aHoney balance
            IBeraBend(beraBend).withdraw(address(asset), type(uint256).max, address(this));
        }

        _totalAssets = asset.balanceOf(address(this));

        if (isAutoCompound && _totalAssets != 0) {
            // deposit all assets to beraBend
            _deployFunds(_totalAssets);
        }

        emit StrategyHarvestAndReport(_totalAssets);
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // withdraw all assets from beraBend
        _freeFunds(type(uint256).max);
    }

    //@return The utilization rate of $HONEY from Berabend, expressed in MAX_BPS
    function getUtilizationRate() public view returns (uint256) {
        // $HONEY borrowed
        uint256 totalHoneyDebt = beraBendDataProvider.getTotalDebt(address(asset));

        // $HONEY supplied in Berabend
        uint256 totalHoneySuppliedToBeraBend = beraBendDataProvider.getATokenTotalSupply(address(asset));

        return totalHoneyDebt * MAX_BPS / totalHoneySuppliedToBeraBend;
    }
}
