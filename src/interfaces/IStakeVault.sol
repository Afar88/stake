// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Callback surface of StakeVault, used to build callback payloads on the reactive side.
interface IStakeVault {
    function forfeit(address rvmId, uint256 goalId, uint256 periodIndex) external;
    function release(address rvmId, uint256 goalId) external;
}
