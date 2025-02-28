// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.4;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Mohd Muzammil
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to a DAI if DAI had no geverence, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system will always be "overcollateralized". At no point should the value of all collateral <= the value $ backed of all DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic of minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the makerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    // ERRORS
    error DSCEngine__AmountLessThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthShouldBeSame();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__InvalidAddress();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOK();
    error DSCEngine__HealthFactorNotImproved();

    // STATE VARIABLES
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus.
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    // EVENTS
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event collateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    // MODIFIERS
    modifier moreThanZero(uint256 _amount) {
        require(_amount > 0, DSCEngine__AmountLessThanZero());
        _;
    }

    modifier isAllowedToken(address token) {
        require(s_priceFeeds[token] != address(0), DSCEngine__NotAllowedToken());
        _;
    }

    modifier checkAddress(address _address) {
        require(_address != address(0), DSCEngine__InvalidAddress());
        _;
    }

    // FUNCTIONS
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        require(
            tokenAddresses.length == priceFeedAddresses.length,
            DSCEngine__TokenAddressesAndPriceFeedAddressesLengthShouldBeSame()
        );
        // For example ETH / USD, BTC / USD, SOL / USD, POL / USD etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            require(tokenAddresses[i] != address(0) && priceFeedAddresses[i] != address(0), DSCEngine__InvalidAddress());
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // EXTERNAL FUNCTIONS

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit collateral
     * @param collateralAmount Amount of collateral to deposit
     * @param amountDSCToMint The amount to DSC to mint
     * @notice This function will deposit collateral and mint DSC in single transaction.
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 amountDSCToMint
    ) external {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDSC(amountDSCToMint);
    }

    /**
     *
     * @param tokenCollateralAddress Token address to redeem collateral
     * @param amountCollateral The amount to redeem collateral
     * @param amountDSCToBurn The amoun to burn collateral
     * @notice This function will burn DSC and redeem collateral in single transaction.
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
    {
        burnDSC(amountDSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral checks for health factor and reverts it.
    }

    // In order to redeem collateral.
    // Health factor must be over 1 AFTER collateral pulled.
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        checkAddress(tokenCollateralAddress)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    // Do we need to check if this breaks health factor?
    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(msg.sender, msg.sender, amount);
        revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hits....
    }
    // USER 1
    // Threshold to let's say 150%
    // $100 ETH Collateral -> $74 DSC (ETH value dump from 100$ to 74$)
    // UNDERCOLLATERALIZED! ! !

    // USER 2
    // I'll pay back the $50 DSC -> Get all your collateral 74$ ETH
    // -$50 DSC (USER 2 PAYS 50$ DSC)
    // gets 74$ collateral of USER 1 by system. (profit 24$)

    // If we do start nearing undercollateralization, we need someone to liquidate positions

    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <- DSC isn't worth $1!!!

    // $75 backing $50 DSC
    // Liquidator take $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     *
     * @param collateralAddress The ERC20 collateral address to liquidate from the user
     * @param user The user who broken the health factor.
     * @param debtToCover The amount of DSC you want to burn to imporve the user's health factor.
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     *
     */
    function liquidate(address collateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        checkAddress(user)
        checkAddress(collateralAddress)
        nonReentrant
    {
        // Need to check health factor of a user.
        uint256 startingUserHealthFactor = healthFactor(user);
        require(startingUserHealthFactor <= MIN_HEALTH_FACTOR, DSCEngine__HealthFactorIsOK());

        // We want to burn their DSC "debt" And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUSD(collateralAddress, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        // 0.05 ETH * 0.1 ETH = 0.005, Getting 0.055.
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateralAddress, totalCollateralToRedeem);
        // Burn the DSC of that user.
        _burnDSC(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = healthFactor(user);
        require(startingUserHealthFactor >= endingUserHealthFactor, DSCEngine__HealthFactorNotImproved());
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    // PUBLIC FUNCTIONS

    /**
     * @param amountDSCToMint the amount of decentralized stable coin to mint.
     * @notice They must have more collateral value than minimum thershold.
     */
    function mintDSC(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        // If they minted too much 150$ minted DSC (But have onlty 100$ ETH Collateral)
        revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_dsc.mint(msg.sender, amountDSCToMint);
        require(!success, DSCEngine__MintFailed());
    }

    /**
     * @param tokenCollateralAddress the address of the token to deposte as collateral
     * @param amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        checkAddress(tokenCollateralAddress)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit collateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        require(!success, DSCEngine__TransferFailed());
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        // 1. Loop through each collateral token.
        // 2. Get the amount this user has deposited.
        // 3. Map it to get the price, to get the USD price.
        address[] memory collateralTokens = s_collateralTokens;
        uint256 totalCollateralValueInUSD;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUSDValue(token, amount);
        }
        return totalCollateralValueInUSD;
    }

    function getUSDValue(address token, uint256 amount) public view checkAddress(token) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // suppose 1 ETH = 1000$
        // The retrned value from chainlink priceFeed will be 1000 * 1e8. (Chainlink returns ETH as 8 decimals)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @param collateralAddress The address of token to get actual price.
     * @param debtToCover Usd amount in wei.
     * @return
     */
    function getTokenAmountFromUSD(address collateralAddress, uint256 debtToCover) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH
        // $200 / ETH. $100 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateralAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * le18) / ($2000e8 * lel0)
        // 0.005000000000000000
        return (debtToCover * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    // INTERNAL FUNCTIONS
    function revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check helath factor (do they have enough collateral?)
        // 2. Revert if they don't have enough.
        uint256 userHealthFactor = healthFactor(user);
        require(userHealthFactor > MIN_HEALTH_FACTOR, DSCEngine__BreaksHealthFactor(userHealthFactor));
    }

    function getAccountInformation(address user) internal view returns (uint256, uint256) {
        uint256 totalDSCMinted = s_DSCMinted[user];
        uint256 collateralValueInUSD = getAccountCollateralValue(user);
        return (totalDSCMinted, collateralValueInUSD);
    }

    // PRIVATE FUNCTIONS

    /**
     * Returns how close to liquidation user is.
     * If a user goes below 1, than they can get liquidated.
     */
    function healthFactor(address user) private view returns (uint256) {
        // 1. Total DSC minted by this user.
        // 2. Total collateral VALUE this user holds.
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = getAccountInformation(user);
        uint256 collateralAdjustedThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedThreshold * PRECISION) / totalDSCMinted;
        // $1000 ETH * 50 = 50,000 / 100 = 500

        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = (75 / 100) < 1

        // return (collateralValueInUSD / totalDSCMinted);  (150 / 100)
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit collateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        require(!success, DSCEngine__TransferFailed());
    }

    /**
     * @dev Low—level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDSC(address onBehalfOf, address DSCFrom, uint256 amountDSCToBurn) private {
        s_DSCMinted[onBehalfOf] -= amountDSCToBurn;
        bool success = i_dsc.transferFrom(DSCFrom, address(this), amountDSCToBurn);
        require(!success, DSCEngine__TransferFailed());

        i_dsc.burn(amountDSCToBurn);
    }
}
