// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
// decomiplier https://ethervm.io/decompile
// proxy https://bartio.beratrail.io/address/
// impl https://bartio.beratrail.io/address/0xeB0De9A7Aee6ADC46A596d7b6BaA286af685cAfa/contract/80084/code

/*
0x00a718a9 liquidationCall(address,address,address,uint256,bool)
0x0148170e POOL_REVISION()
0x02c205f0 supplyWithPermit(address,uint256,address,uint16,uint256,uint8,bytes32,bytes32)
0x0542975c ADDRESSES_PROVIDER()
0x074b2e43 FLASHLOAN_PREMIUM_TOTAL()
0x1d2118f9 setReserveInterestRateStrategyAddress(address,address)
0x272d9072 BRIDGE_PROTOCOL_FEE()
0x28530a47 setUserEMode(uint8)
0x2dad97d4 repayWithATokens(address,uint256,uint256)
0x3036b439 updateBridgeProtocolFee(uint256)
0x35ea6a75 getReserveData(address)
0x386497fd getReserveNormalizedVariableDebt(address)
0x42b0b77c flashLoanSimple(address,address,uint256,bytes,uint16)
0x4417a583 getUserConfiguration(address)
0x52751797 getReserveAddressById(uint16)
0x573ade81 repay(address,uint256,uint256,address)
0x5a3b74b9 setUserUseReserveAsCollateral(address,bool)
0x617ba037 supply(address,uint256,address,uint16)
0x63c9b860 dropReserve(address)
0x69328dec withdraw(address,uint256,address)
0x69a933a5 mintUnbacked(address,uint256,address,uint16)
0x6a99c036 FLASHLOAN_PREMIUM_TO_PROTOCOL()
0x6c6f6ae1 getEModeCategoryData(uint8)
0x7a708e92 initReserve(address,address,address,address,address)
0x94ba89a2 swapBorrowRateMode(address,uint256)
0xa415bcad borrow(address,uint256,uint256,uint16,address)
0xab9c4b5d flashLoan(address,address[],uint256[],uint256[],address,bytes,uint16)
0xbcb6e522 updateFlashloanPremiums(uint128,uint128)
0xbf92857c getUserAccountData(address)
0xc44b11f7 getConfiguration(address)
0xc4d66de8 initialize(address)
0xcd112382 rebalanceStableBorrowRate(address,address)
0xcea9d26f rescueTokens(address,address,uint256)
0xd15e0053 getReserveNormalizedIncome(address)
0xd1946dbc getReservesList()
0xd2945054 Unknown
0xd579ea7d configureEModeCategory(uint8,(uint16,uint16,uint16,address,string))
0xd5ed3933 finalizeTransfer(address,address,address,uint256,uint256,uint256)
0xd65dc7a1 backUnbacked(address,uint256,uint256)
0xe43e88a1 resetIsolationModeTotalDebt(address)
0xe82fec2f MAX_STABLE_RATE_BORROW_SIZE_PERCENT()
0xe8eda9df deposit(address,uint256,address,uint16)
0xeddf1b79 getUserEMode(address)
0xee3e210b repayWithPermit(address,uint256,uint256,address,uint256,uint8,bytes32,bytes32)
0xf51e435b Unknown
0xf8119d51 MAX_NUMBER_RESERVES()
*/

import {DataTypes} from "./BeraBendDataTypes.sol";

interface IBeraBend {
    /**
     * @dev Emitted on deposit()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address initiating the deposit
     * @param onBehalfOf The beneficiary of the deposit, receiving the aTokens
     * @param amount The amount deposited
     * @param referral The referral code used
     *
     */
    event Deposit(
        address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referral
    );

    /**
     * @dev Emitted on withdraw()
     * @param reserve The address of the underlyng asset being withdrawn
     * @param user The address initiating the withdrawal, owner of aTokens
     * @param to Address that will receive the underlying
     * @param amount The amount to be withdrawn
     *
     */
    event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);

    /**
     * @dev Emitted on borrow() and flashLoan() when debt needs to be opened
     * @param reserve The address of the underlying asset being borrowed
     * @param user The address of the user initiating the borrow(), receiving the funds on borrow() or just
     * initiator of the transaction on flashLoan()
     * @param onBehalfOf The address that will be getting the debt
     * @param amount The amount borrowed out
     * @param borrowRateMode The rate mode: 1 for Stable, 2 for Variable
     * @param borrowRate The numeric rate at which the user has borrowed
     * @param referral The referral code used
     *
     */
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 borrowRateMode,
        uint256 borrowRate,
        uint16 indexed referral
    );

    /**
     * @dev Emitted on repay()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The beneficiary of the repayment, getting his debt reduced
     * @param repayer The address of the user initiating the repay(), providing the funds
     * @param amount The amount repaid
     *
     */
    event Repay(address indexed reserve, address indexed user, address indexed repayer, uint256 amount);

    /**
     * @dev Emitted on swapBorrowRateMode()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address of the user swapping his rate mode
     * @param rateMode The rate mode that the user wants to swap to
     *
     */
    event Swap(address indexed reserve, address indexed user, uint256 rateMode);

    /**
     * @dev Emitted on setUserUseReserveAsCollateral()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address of the user enabling the usage as collateral
     *
     */
    event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);

    /**
     * @dev Emitted on setUserUseReserveAsCollateral()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address of the user enabling the usage as collateral
     *
     */
    event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);

    /**
     * @dev Emitted on rebalanceStableBorrowRate()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address of the user for which the rebalance has been executed
     *
     */
    event RebalanceStableBorrowRate(address indexed reserve, address indexed user);

    /**
     * @dev Emitted on flashLoan()
     * @param target The address of the flash loan receiver contract
     * @param initiator The address initiating the flash loan
     * @param asset The address of the asset being flash borrowed
     * @param amount The amount flash borrowed
     * @param premium The fee flash borrowed
     * @param referralCode The referral code used
     *
     */
    event FlashLoan(
        address indexed target,
        address indexed initiator,
        address indexed asset,
        uint256 amount,
        uint256 premium,
        uint16 referralCode
    );

    /**
     * @dev Emitted when the pause is triggered.
     */
    event Paused();

    /**
     * @dev Emitted when the pause is lifted.
     */
    event Unpaused();

    /**
     * @dev Emitted when a borrower is liquidated. This event is emitted by the LendingPool via
     * LendingPoolCollateral manager using a DELEGATECALL
     * This allows to have the events in the generated ABI for LendingPool.
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param liquidatedCollateralAmount The amount of collateral received by the liiquidator
     * @param liquidator The address of the liquidator
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     *
     */
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator,
        bool receiveAToken
    );

    /**
     * @dev Emitted when the state of a reserve is updated. NOTE: This event is actually declared
     * in the ReserveLogic library and emitted in the updateInterestRates() function. Since the function is internal,
     * the event will actually be fired by the LendingPool contract. The event is therefore replicated here so it
     * gets added to the LendingPool ABI
     * @param reserve The address of the underlying asset of the reserve
     * @param liquidityRate The new liquidity rate
     * @param stableBorrowRate The new stable borrow rate
     * @param variableBorrowRate The new variable borrow rate
     * @param liquidityIndex The new liquidity index
     * @param variableBorrowIndex The new variable borrow index
     *
     */
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex
    );

    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external;
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    struct ReserveData {
        //stores the reserve configuration
        uint256 configuration;
        //the liquidity index. Expressed in ray
        uint128 liquidityIndex;
        //variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        //the current supply rate. Expressed in ray
        uint128 currentLiquidityRate;
        //the current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        //the current stable borrow rate. Expressed in ray
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        //tokens addresses
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        //address of the interest rate strategy
        address interestRateStrategyAddress;
        //the id of the reserve. Represents the position in the list of the active reserves
        uint8 id;
    }

    function getReserveData(address asset)
        external
        view
        returns (uint256, uint128, uint128, uint128 currentLiquidityRate);
}

// cast call 0x30A3039675E5b5cbEA49d9a5eacbc11f9199B86D "getReserveData(address)" 0x0E4aaF1351de4c0264C5c7056Ef3777b41BD8e03 --rpc-url https://bartio.rpc.berachain.com/
