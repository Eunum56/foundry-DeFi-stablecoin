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

    // STATE VARIABLES
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    // EVENTS
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
    function depositCollateralAndMintDSC() external {}

    /**
     * @param tokenCollateralAddress the address of the token to deposte as collateral
     * @param amountCollateral the amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
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

    function redeemCollateralForDSC() external {}

    function redeemCollateral() external {}

    /**
     * @param amountDSCToMint the amount of decentralized stable coin to mint.
     * @notice They must have more collateral value than minimum thershold.
     */
    function mintDSC(uint256 amountDSCToMint) external moreThanZero(amountDSCToMint) {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        // If they minted too much 150$ minted DSC (But have onlty 100$ ETH Collateral)
        revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_dsc.mint(msg.sender, amountDSCToMint);
        require(!success, DSCEngine__MintFailed());
    }

    function burnDSC() external {}
    // USER 1
    // Threshold to let's say 150%
    // $100 ETH Collateral -> $74 DSC (ETH value dump from 100$ to 74$)
    // UNDERCOLLATERALIZED! ! !

    // USER 2
    // I'll pay back the $50 DSC -> Get all your collateral 74$ ETH
    // -$50 DSC (USER 2 PAYS 50$ DSC)
    // gets 74$ collateral of USER 1 by system. (profit 24$)

    function liquidate() external {}

    function getHealthFactor() external view {}

    // PUBLIC FUNCTIONS
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

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // suppose 1 ETH = 1000$
        // The retrned value from chainlink priceFeed will be 1000 * 1e8. (Chainlink returns ETH as 8 decimals)
        return ((uint256(price) * 1e10) * amount) / 1e18;
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
        uint256 collateralAdjustedThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedThreshold * 1e18) / totalDSCMinted;
        // $1000 ETH * 50 = 50,000 / 100 = 500

        // $150 ETH / 100 DSC = 1.5
        // 150 * 50 = 7500 / 100 = (75 / 100) < 1

        // return (collateralValueInUSD / totalDSCMinted);  (150 / 100)
    }
}
