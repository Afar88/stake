// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title StakeVault
/// @notice Holds a user's Base Sepolia ETH stake for a weekly goal. A referee confirms each
///         period on-chain; the StakeWatcher reactive contract calls back to forfeit missed
///         periods and to release whatever is left once every period is settled.
/// @dev This contract is the source of truth. Callback handlers re-check every rule with the
///      local block.timestamp and never revert on business-rule failures: they emit Skipped
///      instead, because callback attempts are billed regardless of outcome.
contract StakeVault is AbstractCallback {
    // ------------------------------------------------------------------ events

    event GoalCreated(
        uint256 indexed goalId,
        address indexed owner,
        address referee,
        address penaltyTo,
        uint256 stake,
        uint8 numWeeks,
        uint64 periodSeconds,
        uint64 startTime
    );
    event CheckedIn(uint256 indexed goalId, uint256 periodIndex);
    event Forfeited(uint256 indexed goalId, uint256 periodIndex, uint256 amount);
    event Released(uint256 indexed goalId, uint256 amount);
    /// @notice Emitted instead of reverting when a callback fails a business-rule check.
    /// @param periodIndex The period the callback targeted; type(uint256).max for release().
    /// @param reason 1=bad goal, 2=period not ended, 3=already confirmed, 4=already settled,
    ///               5=not all periods settled, 6=goal still running.
    event Skipped(uint256 indexed goalId, uint256 periodIndex, uint8 reason);

    // ------------------------------------------------------------------ errors

    error BadReferee();
    error BadPenaltyTo();
    error BadWeeks();
    error BadPeriodSeconds();
    error NoStake();
    error NotReferee();
    error GoalNotActive();
    error GoalFinished();
    error AlreadyCheckedIn();
    error PayoutFailed();

    // ------------------------------------------------------------------ storage

    uint8 public constant MAX_WEEKS = 12;
    uint256 internal constant ALL_PERIODS = type(uint256).max;

    uint8 internal constant SKIP_BAD_GOAL = 1;
    uint8 internal constant SKIP_NOT_ENDED = 2;
    uint8 internal constant SKIP_CONFIRMED = 3;
    uint8 internal constant SKIP_SETTLED = 4;
    uint8 internal constant SKIP_UNSETTLED = 5;
    uint8 internal constant SKIP_STILL_RUNNING = 6;

    struct Goal {
        address owner;
        address referee;
        address penaltyTo;
        uint256 stake;
        uint256 forfeited;
        uint8 numWeeks;
        uint64 periodSeconds;
        uint64 startTime;
        uint16 confirmedMask; // bit i = period i confirmed via confirm()
        uint16 settledMask;   // bit i = period i forfeited via forfeit()
        bool active;
    }

    uint256 public goalCount;
    mapping(uint256 => Goal) public goals;

    /// @param callbackProxy_ Callback proxy on Base Sepolia (the billing service provider).
    /// @param watcher_       StakeWatcher on Reactive Lasna allowed to drive callbacks.
    constructor(IPayable callbackProxy_, address watcher_)
        payable
        AbstractCallback(callbackProxy_, watcher_)
    {}

    // ------------------------------------------------------------------ user API

    /// @notice Lock a stake for a new goal. The stake is split into `weeks_` equal slices.
    /// @param referee_        Wallet allowed to call confirm() — a friend, not the owner.
    /// @param penaltyTo_      Wallet that receives forfeited slices.
    /// @param weeks_          Number of periods, 1..12.
    /// @param periodSeconds_  Length of one period; configurable so demos can use minutes.
    function createGoal(address referee_, address penaltyTo_, uint8 weeks_, uint64 periodSeconds_)
        external
        payable
        returns (uint256 goalId)
    {
        if (referee_ == address(0)) revert BadReferee();
        if (penaltyTo_ == address(0)) revert BadPenaltyTo();
        if (weeks_ == 0 || weeks_ > MAX_WEEKS) revert BadWeeks();
        if (periodSeconds_ == 0) revert BadPeriodSeconds();
        if (msg.value == 0) revert NoStake();

        goalId = goalCount++;
        goals[goalId] = Goal({
            owner: msg.sender,
            referee: referee_,
            penaltyTo: penaltyTo_,
            stake: msg.value,
            forfeited: 0,
            numWeeks: weeks_,
            periodSeconds: periodSeconds_,
            startTime: uint64(block.timestamp),
            confirmedMask: 0,
            settledMask: 0,
            active: true
        });

        emit GoalCreated(
            goalId, msg.sender, referee_, penaltyTo_, msg.value, weeks_, periodSeconds_, uint64(block.timestamp)
        );
    }

    /// @notice Referee confirms the current period once, while the goal is running.
    function confirm(uint256 goalId_) external {
        Goal storage g = goals[goalId_];
        if (!g.active) revert GoalNotActive();
        if (msg.sender != g.referee) revert NotReferee();

        uint256 period = currentPeriod(g);
        if (period >= g.numWeeks) revert GoalFinished();
        if ((g.confirmedMask >> period) & 1 == 1) revert AlreadyCheckedIn();

        g.confirmedMask |= uint16(1 << period);
        emit CheckedIn(goalId_, period);
    }

    // ------------------------------------------------------------------ callbacks

    /// @notice Called back by StakeWatcher to forfeit one ended, unconfirmed period.
    ///         Pays stake / numWeeks to penaltyTo. Skips (never reverts) on rule failures.
    function forfeit(address rvmId_, uint256 goalId_, uint256 periodIndex_)
        external
        onlyServiceProvider
        onlyCallbackSender(rvmId_)
    {
        Goal storage g = goals[goalId_];
        if (!g.active || periodIndex_ >= g.numWeeks) {
            emit Skipped(goalId_, periodIndex_, SKIP_BAD_GOAL);
            return;
        }
        if (block.timestamp < periodEnd(g, periodIndex_)) {
            emit Skipped(goalId_, periodIndex_, SKIP_NOT_ENDED);
            return;
        }
        if ((g.confirmedMask >> periodIndex_) & 1 == 1) {
            emit Skipped(goalId_, periodIndex_, SKIP_CONFIRMED);
            return;
        }
        if ((g.settledMask >> periodIndex_) & 1 == 1) {
            emit Skipped(goalId_, periodIndex_, SKIP_SETTLED);
            return;
        }

        g.settledMask |= uint16(1 << periodIndex_);
        uint256 slice = g.stake / g.numWeeks;
        g.forfeited += slice;
        _send(payable(g.penaltyTo), slice);
        emit Forfeited(goalId_, periodIndex_, slice);
    }

    /// @notice Called back by StakeWatcher once every period is settled and the last one ended.
    ///         Returns the remaining stake to the owner. Skips (never reverts) on rule failures.
    function release(address rvmId_, uint256 goalId_)
        external
        onlyServiceProvider
        onlyCallbackSender(rvmId_)
    {
        Goal storage g = goals[goalId_];
        if (!g.active) {
            emit Skipped(goalId_, ALL_PERIODS, SKIP_BAD_GOAL);
            return;
        }
        if (block.timestamp < periodEnd(g, g.numWeeks - 1)) {
            emit Skipped(goalId_, ALL_PERIODS, SKIP_STILL_RUNNING);
            return;
        }
        if (uint16(g.confirmedMask | g.settledMask) != _fullMask(g.numWeeks)) {
            emit Skipped(goalId_, ALL_PERIODS, SKIP_UNSETTLED);
            return;
        }

        g.active = false;
        uint256 remaining = g.stake - g.forfeited;
        _send(payable(g.owner), remaining);
        emit Released(goalId_, remaining);
    }

    /// @notice Settles outstanding debt to the callback proxy from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------ views

    /// @notice Index of the period currently running; may exceed numWeeks-1 once the goal is over.
    function currentPeriod(Goal storage g) internal view returns (uint256) {
        if (block.timestamp < g.startTime) return 0;
        return (block.timestamp - g.startTime) / g.periodSeconds;
    }

    /// @notice Timestamp at which `periodIndex_` ends.
    function periodEnd(Goal storage g, uint256 periodIndex_) internal view returns (uint256) {
        return uint256(g.startTime) + (periodIndex_ + 1) * uint256(g.periodSeconds);
    }

    function _fullMask(uint8 weeks_) internal pure returns (uint16) {
        return uint16((1 << weeks_) - 1);
    }

    function _send(address payable to_, uint256 amount_) internal {
        if (amount_ == 0) return;
        (bool ok,) = to_.call{ value: amount_ }(new bytes(0));
        if (!ok) revert PayoutFailed();
    }
}
