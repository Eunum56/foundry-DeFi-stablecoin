//SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    // EVENTS
    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event collateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;

    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 public AMOUNT_TO_MINT = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    address public USER = makeAddr("USER");

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    // CONSTRUCTOR TESTS
    function testContructorReverts() public {
        tokenAddresses.push(weth);

        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesLengthShouldBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        tokenAddresses.push(address(0));
        vm.expectRevert(DSCEngine.DSCEngine__InvalidAddress.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // PRICE TESTS
    function testGetUSDPrice() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUSD = 30000e18;
        uint256 actualUSD = engine.getUSDValue(weth, ethAmount);
        assertEq(expectedUSD, actualUSD);
    }

    function testGetTokenAmountFromUSD() public view {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH , $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUSD(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    // DEPOSITE_COLLATERAL TESTS
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__AmountLessThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsAnUnapprovedCollateral() public {
        ERC20Mock token = new ERC20Mock("Tk", "tk");
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        vm.startPrank(USER);
        engine.depositCollateral(address(token), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositeCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralAndGetAccountInfo() public depositeCollateral {
        (uint256 totalDSCMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(USER);

        uint256 expectedTotalDSCMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUSD(weth, collateralValueInUSD);

        assertEq(totalDSCMinted, expectedTotalDSCMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanDepositCollateralWithoutMinting() public depositeCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    // MINT FUNCTION
    function testMintFunctionReverts() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AmountLessThanZero.selector);
        engine.mintDSC(0);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositeCollateral {
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        AMOUNT_TO_MINT =
            (AMOUNT_COLLATERAL * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(AMOUNT_TO_MINT, engine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDSC(AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositeCollateral {
        vm.prank(USER);
        engine.mintDSC(AMOUNT_TO_MINT);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    // DEPOSIT COLLATERAL AND MINT DSC TESTS
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    // BURN FUNCTION TESTS
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_TO_MINT);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__AmountLessThanZero.selector);
        engine.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDSC(1);
    }

    // REDEEM COLLATERAL TESTS
    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__AmountLessThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositeCollateral {
        vm.startPrank(USER);
        uint256 userBalanceBeforeRedeem = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalanceBeforeRedeem, AMOUNT_COLLATERAL);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalanceAfterRedeem = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositeCollateral {
        vm.expectEmit(true, true, true, true, address(engine));
        emit collateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // HEALTH FACTOR TESTS
    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    // LIQUIDUATION TESTS
    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDSC(weth, collateralToCover, AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOK.selector);
        engine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    // VIEW AND PURE TESTS
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, wethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositeCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
