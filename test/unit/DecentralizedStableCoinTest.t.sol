// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;
    address owner = address(1);
    address user = address(2);

    function setUp() public {
        vm.prank(owner); // Set `owner` as the caller for deployment
        dsc = new DecentralizedStableCoin();
    }

    function testInitialSupplyIsZero() public view {
        assertEq(dsc.totalSupply(), 0, "Initial supply should be zero");
    }

    function testMintingByOwner() public {
        vm.prank(owner);
        dsc.mint(user, 100 ether);

        assertEq(dsc.balanceOf(user), 100 ether, "User should have 100 tokens");
        assertEq(dsc.totalSupply(), 100 ether, "Total supply should be 100");
    }

    function testMintingToZeroAddressFails() public {
        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__InvalidAddress.selector);
        dsc.mint(address(0), 100 ether);
    }

    function testBurningByOwner() public {
        vm.startPrank(owner);
        dsc.mint(owner, 100 ether);
        dsc.burn(50 ether);
        vm.stopPrank();

        assertEq(dsc.balanceOf(owner), 50 ether, "Owner should have 50 tokens left");
        assertEq(dsc.totalSupply(), 50 ether, "Total supply should be 50");
    }

    function testBurningFailsIfMoreThanBalance() public {
        vm.startPrank(owner);
        dsc.mint(owner, 100 ether);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(200 ether);
        vm.stopPrank();
    }

    function testBurningZeroTokensFails() public {
        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
    }
}
