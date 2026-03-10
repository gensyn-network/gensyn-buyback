// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}
