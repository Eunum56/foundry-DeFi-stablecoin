// Have or invariant aka properties

// What are our invariants?
// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should nvert revert <— evergreen invariant

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    DeployDSC deployer;
    HelperConfig config;
    Handler handler;

    address weth;
    address wbtc;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dsc, engine);
        targetContract(address(handler));
        // targetContract(address(engine));
        // Hey don't call redeemCollateral function, unless you've collateral to redeem.
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();

        uint256 totalWETHDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWBTCDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUSDValue(weth, totalWETHDeposited);
        uint256 wbtcValue = engine.getUSDValue(wbtc, totalWBTCDeposited);

        console.log("weth Value", wethValue);
        console.log("wbtc Value", wbtcValue);
        console.log("Total Supply", totalSupply);
        console.log("Times Mint Called", handler.timesMintCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }
}
