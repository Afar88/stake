// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Records subscription and callback calls so tests can assert on them.
///         Etched over 0x8888888888888888888888888888888888888888 in tests.
contract MockSystemContract {
    struct SubscriptionCall {
        uint256 chainId;
        address target;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    struct CallbackRequest {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    SubscriptionCall[] public subscriptions;
    SubscriptionCall[] public unsubscriptions;
    CallbackRequest[] public callbacks;

    function subscribe(
        uint256 chainId_, address contract_, uint256 topic0_,
        uint256 topic1_, uint256 topic2_, uint256 topic3_
    ) external {
        subscriptions.push(SubscriptionCall(chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
    }

    function unsubscribe(
        uint256 chainId_, address contract_, uint256 topic0_,
        uint256 topic1_, uint256 topic2_, uint256 topic3_
    ) external {
        unsubscriptions.push(SubscriptionCall(chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_)
        external
    {
        callbacks.push(CallbackRequest(config_.chainId, config_.recipient, config_.gasLimit, config_.payload));
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function unsubscriptionCount() external view returns (uint256) {
        return unsubscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbacks.length;
    }

    receive() external payable {}
}
