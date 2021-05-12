// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
import "./IERC20.sol";
import "./IWrappedERC20Events.sol";

interface IWETH is IERC20,IWrappedERC20Events{    
    function deposit() external payable;
    function withdraw(uint256 _amount) external;
    
}
