// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { StakeVault } from "../src/StakeVault.sol";

/// @notice Minimal payable target exposing debt() so coverDebt() can be exercised.
contract MockProxy {
    uint256 public fixedDebt;

    constructor(uint256 debt_) {
        fixedDebt = debt_;
    }

    function debt(address) external view returns (uint256) {
        return fixedDebt;
    }

    receive() external payable {}
}

contract StakeVaultTest is Test {
    address internal constant PROXY = address(0x476F44b11F5C942c58f4c8E3d0300E5710743585);

    StakeVault internal vault;
    address internal watcher = makeAddr("watcher");
    address internal owner = makeAddr("owner");
    address internal referee = makeAddr("referee");
    address internal penalty = makeAddr("penalty");

    uint64 internal constant PERIOD = 600; // 10-minute "numWeeks"

    event GoalCreated(
        uint256 indexed goalId, address indexed owner, address referee, address penaltyTo,
        uint256 stake, uint8 numWeeks, uint64 periodSeconds, uint64 startTime
    );
    string internal constant GOAL_TEXT = "Run 3 times a week";
    event GoalText(uint256 indexed goalId, string text);
    event CheckedIn(uint256 indexed goalId, uint256 periodIndex);
    event Forfeited(uint256 indexed goalId, uint256 periodIndex, uint256 amount);
    event Released(uint256 indexed goalId, uint256 amount);
    event Skipped(uint256 indexed goalId, uint256 periodIndex, uint8 reason);

    function setUp() public {
        vault = new StakeVault(IPayable(payable(PROXY)), watcher);
        vm.deal(owner, 10 ether);
        vm.warp(1_700_000_000);
    }

    function _create(uint8 weeks_) internal returns (uint256 goalId) {
        vm.prank(owner);
        goalId = vault.createGoal{ value: 1 ether }(GOAL_TEXT, referee, penalty, weeks_, PERIOD);
    }

    // ------------------------------------------------------------ createGoal

    function test_CreateGoal() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit GoalCreated(0, owner, referee, penalty, 1 ether, 2, PERIOD, uint64(block.timestamp));
        uint256 goalId = vault.createGoal{ value: 1 ether }(GOAL_TEXT, referee, penalty, 2, PERIOD);
        assertEq(goalId, 0);
        (
            address o, address r, address p, uint256 stake,, uint8 w,
            uint64 periodSeconds, uint64 startTime,,, bool active
        ) = vault.goals(goalId);
        assertEq(o, owner);
        assertEq(r, referee);
        assertEq(p, penalty);
        assertEq(stake, 1 ether);
        assertEq(w, 2);
        assertEq(periodSeconds, PERIOD);
        assertEq(startTime, block.timestamp);
        assertTrue(active);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_CreateGoal_Validation() public {
        vm.startPrank(owner);
        vm.expectRevert(StakeVault.BadReferee.selector);
        vault.createGoal{ value: 1 ether }(GOAL_TEXT, address(0), penalty, 2, PERIOD);
        vm.expectRevert(StakeVault.BadPenaltyTo.selector);
        vault.createGoal{ value: 1 ether }(GOAL_TEXT, referee, address(0), 2, PERIOD);
        vm.expectRevert(StakeVault.BadWeeks.selector);
        vault.createGoal{ value: 1 ether }(GOAL_TEXT, referee, penalty, 0, PERIOD);
        vm.expectRevert(StakeVault.BadWeeks.selector);
        vault.createGoal{ value: 1 ether }(GOAL_TEXT, referee, penalty, 13, PERIOD);
        vm.expectRevert(StakeVault.BadPeriodSeconds.selector);
        vault.createGoal{ value: 1 ether }(GOAL_TEXT, referee, penalty, 2, 0);
        vm.expectRevert(StakeVault.NoStake.selector);
        vault.createGoal{ value: 0 }(GOAL_TEXT, referee, penalty, 2, PERIOD);
        vm.stopPrank();
    }


    function test_CreateGoal_StoresText() public {
        uint256 goalId = _create(2);
        assertEq(vault.goalText(goalId), GOAL_TEXT);
    }

    function test_CreateGoal_EmitsGoalText() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GoalText(0, GOAL_TEXT);
        vault.createGoal{ value: 1 ether }(GOAL_TEXT, referee, penalty, 2, PERIOD);
    }

    function test_CreateGoal_EmptyText_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(StakeVault.BadGoalText.selector);
        vault.createGoal{ value: 1 ether }("", referee, penalty, 2, PERIOD);
    }

    function test_CreateGoal_TooLongText_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(StakeVault.BadGoalText.selector);
        vault.createGoal{ value: 1 ether }(new string(141), referee, penalty, 2, PERIOD);
    }

    function test_CreateGoal_MaxLengthText_Ok() public {
        string memory text = new string(140);
        vm.prank(owner);
        uint256 goalId = vault.createGoal{ value: 1 ether }(text, referee, penalty, 2, PERIOD);
        assertEq(bytes(vault.goalText(goalId)).length, 140);
    }

    // ------------------------------------------------------------ confirm

    function test_Confirm() public {
        uint256 goalId = _create(2);
        vm.prank(referee);
        vm.expectEmit(true, false, false, true);
        emit CheckedIn(goalId, 0);
        vault.confirm(goalId);
    }

    function test_Confirm_NonReferee() public {
        uint256 goalId = _create(2);
        vm.prank(owner);
        vm.expectRevert(StakeVault.NotReferee.selector);
        vault.confirm(goalId);
    }

    function test_Confirm_Twice_SamePeriod() public {
        uint256 goalId = _create(2);
        vm.startPrank(referee);
        vault.confirm(goalId);
        vm.expectRevert(StakeVault.AlreadyCheckedIn.selector);
        vault.confirm(goalId);
        vm.stopPrank();
    }

    function test_Confirm_NextPeriod() public {
        uint256 goalId = _create(2);
        vm.prank(referee);
        vault.confirm(goalId);
        vm.warp(block.timestamp + PERIOD);
        vm.prank(referee);
        vault.confirm(goalId); // period 1 now — fine
    }

    function test_Confirm_AfterEnd() public {
        uint256 goalId = _create(2);
        vm.warp(block.timestamp + 2 * PERIOD + 1);
        vm.prank(referee);
        vm.expectRevert(StakeVault.GoalFinished.selector);
        vault.confirm(goalId);
    }

    // ------------------------------------------------------------ forfeit auth

    function test_Forfeit_OnlyProxy() public {
        uint256 goalId = _create(2);
        vm.warp(block.timestamp + PERIOD + 1);
        vm.prank(owner); // not the proxy
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, owner, PROXY));
        vault.forfeit(watcher, goalId, 0);
    }

    function test_Forfeit_OnlyRightRvmId() public {
        uint256 goalId = _create(2);
        vm.warp(block.timestamp + PERIOD + 1);
        address evil = makeAddr("evilWatcher");
        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, evil, watcher));
        vault.forfeit(evil, goalId, 0);
    }

    // ------------------------------------------------------------ forfeit rules

    function test_Forfeit_PaysSlice() public {
        uint256 goalId = _create(2);
        vm.warp(block.timestamp + PERIOD + 1); // period 0 ended
        uint256 before = penalty.balance;
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Forfeited(goalId, 0, 0.5 ether);
        vault.forfeit(watcher, goalId, 0);
        assertEq(penalty.balance - before, 0.5 ether);
    }

    function test_Forfeit_ConfirmedPeriod_Skips() public {
        uint256 goalId = _create(2);
        vm.prank(referee);
        vault.confirm(goalId);
        vm.warp(block.timestamp + PERIOD + 1);
        uint256 before = penalty.balance;
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Skipped(goalId, 0, 3); // confirmed
        vault.forfeit(watcher, goalId, 0);
        assertEq(penalty.balance, before);
    }

    function test_Forfeit_Early_Skips() public {
        uint256 goalId = _create(2); // period 0 still running
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Skipped(goalId, 0, 2); // not ended
        vault.forfeit(watcher, goalId, 0);
    }

    function test_Forfeit_Repeat_Skips() public {
        uint256 goalId = _create(2);
        vm.warp(block.timestamp + PERIOD + 1);
        vm.prank(PROXY);
        vault.forfeit(watcher, goalId, 0);
        uint256 before = penalty.balance;
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Skipped(goalId, 0, 4); // already settled
        vault.forfeit(watcher, goalId, 0);
        assertEq(penalty.balance, before);
    }

    function test_Forfeit_BadGoal_Skips() public {
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Skipped(77, 0, 1);
        vault.forfeit(watcher, 77, 0);
    }

    // ------------------------------------------------------------ release

    function test_Release_FullFlow() public {
        uint256 goalId = _create(2);

        // Period 0: referee confirms.
        vm.prank(referee);
        vault.confirm(goalId);

        // Period 1: missed. Warp past the end.
        vm.warp(block.timestamp + 2 * PERIOD + 1);
        vm.prank(PROXY);
        vault.forfeit(watcher, goalId, 1);

        // Release returns the unforfeited half.
        uint256 ownerBefore = owner.balance;
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Released(goalId, 0.5 ether);
        vault.release(watcher, goalId);
        assertEq(owner.balance - ownerBefore, 0.5 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_Release_StillRunning_Skips() public {
        uint256 goalId = _create(2);
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Skipped(goalId, type(uint256).max, 6);
        vault.release(watcher, goalId);
    }

    function test_Release_UnsettledPeriod_Skips() public {
        uint256 goalId = _create(2);
        vm.warp(block.timestamp + 2 * PERIOD + 1); // both periods ended, none settled
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Skipped(goalId, type(uint256).max, 5);
        vault.release(watcher, goalId);
    }

    function test_Release_AfterRelease_Skips() public {
        uint256 goalId = _create(1);
        vm.warp(block.timestamp + PERIOD + 1);
        vm.prank(PROXY);
        vault.forfeit(watcher, goalId, 0);
        vm.prank(PROXY);
        vault.release(watcher, goalId);
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true);
        emit Skipped(goalId, type(uint256).max, 1); // inactive now
        vault.release(watcher, goalId);
    }

    function test_Funding_Receive() public {
        (bool ok,) = address(vault).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_CoverDebt_PaysOwed() public {
        // Use the mock as a payable "proxy" that reports a fixed debt.
        MockProxy proxy = new MockProxy(0.01 ether);
        StakeVault v = new StakeVault(IPayable(payable(address(proxy))), watcher);
        (bool ok,) = address(v).call{ value: 1 ether }("");
        assertTrue(ok);
        v.coverDebt();
        assertEq(address(proxy).balance, 0.01 ether);
    }
}
