// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IYeetGraduator {
    function graduate(address token, uint256 tokens) external payable returns (bytes32 poolId);
}
