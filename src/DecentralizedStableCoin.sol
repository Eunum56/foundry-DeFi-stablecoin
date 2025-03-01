// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Mohd Muzammil
 * @notice Collateral: Exogenous (ETH & BTC)
 * @notice Minting/Stability mechanism: Algorithmic
 * @notice Relative Stability: Pegged to USD
 * @dev This contract is meant to be governed by DSCEngine.
 * It serves as the ERC20 implementation of our stablecoin system.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    // ERRORS
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__InvalidAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount == 0) revert DecentralizedStableCoin__MustBeMoreThanZero();
        if (_amount > balance) revert DecentralizedStableCoin__BurnAmountExceedsBalance();

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) revert DecentralizedStableCoin__InvalidAddress();
        if (_amount == 0) revert DecentralizedStableCoin__MustBeMoreThanZero();

        _mint(_to, _amount);
        return true;
    }
}
