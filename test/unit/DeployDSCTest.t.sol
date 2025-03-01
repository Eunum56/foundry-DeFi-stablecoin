// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract DeployDSCTest is Test {
    DeployDSC deployScript;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    function setUp() public {
        deployScript = new DeployDSC();
        (dsc, engine, config) = deployScript.run();
    }

    function testContractsDeployed() public view {
        assert(address(dsc) != address(0));
        assert(address(engine) != address(0));
        assert(address(config) != address(0));
    }

    function testOwnershipTransferred() public view {
        assertEq(dsc.owner(), address(engine));
    }
}
