// Handler is going to narrow down the way we call functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;

    ERC20Mock weth;
    ERC20Mock wbtc;

    MockV3Aggregator public ethUsdPriceFeed;
    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timesMintCalled;
    address[] public usersWithCollateralDeposited;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _engine) {
        dsc = _dsc;
        engine = _engine;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    // Deposit collateral
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // Double push
        usersWithCollateralDeposited.push(msg.sender);
    }

    // Redeem Collateral
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) return;
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    // Mint Collateral
    function mintDsc(uint256 amount, uint256 collateralSeed) public {
        if (usersWithCollateralDeposited.length == 0) return;
        address sender = usersWithCollateralDeposited[collateralSeed % usersWithCollateralDeposited.length];
        amount = bound(amount, 1, MAX_DEPOSIT_SIZE);
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = engine.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUSD) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) return;
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) return;
        timesMintCalled++;
        vm.startPrank(sender);
        engine.mintDSC(amount);
        vm.stopPrank();
    }

    /**
     *
     * Breaks
     */
    // function updateCollateralPrice(uint96 price) public {
    //     int256 intNewPrice = int256(uint256(price));
    //     ethUsdPriceFeed.updateAnswer(intNewPrice);
    // }

    // Helper functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
