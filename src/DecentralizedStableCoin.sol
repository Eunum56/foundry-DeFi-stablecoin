// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
* @title: DecentralizedStableCoin
* @author: Mohd Muzammil
* Collateral: Exogenous (ETH & BTC)
* Minting/Stability mechnanism: Algorithmic
* Relative Stability: Pegged to USD

* This is the contract meant to be geverned my DSCEngine. This contract is just the ERC20 implenentation of our stablecoin system.
*/

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    // ERRORS
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__InvalidAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        require(_amount > 0, DecentralizedStableCoin__MustBeMoreThanZero());
        require(_amount > balance, DecentralizedStableCoin__BurnAmountExceedsBalance());
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        require(_to != address(0), DecentralizedStableCoin__InvalidAddress());
        require(_amount > 0, DecentralizedStableCoin__MustBeMoreThanZero());
        _mint(_to, _amount);
        return true;
    }
}
