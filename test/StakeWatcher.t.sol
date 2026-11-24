// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { StakeWatcher } from "../src/StakeWatcher.sol";
import { IStakeVault } from "../src/interfaces/IStakeVault.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";

contract StakeWatcherTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant BASE = 84532;
    uint256 internal constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant GOAL_CREATED = uint256(keccak256(
        "GoalCreated(uint256,address,address,address,uint256,uint8,uint64,uint64)"
    ));
    uint256 internal constant CHECKED_IN = uint256(keccak256("CheckedIn(uint256,uint256)"));
    uint256 internal constant FORFEITED = uint256(keccak256("Forfeited(uint256,uint256,uint256)"));
    uint256 internal constant RELEASED = uint256(keccak256("Released(uint256,uint256)"));

    StakeWatcher internal watcher;
    MockSystemContract internal mock;
    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal referee = makeAddr("referee");
    address internal penalty = makeAddr("penalty");

    uint64 internal constant PERIOD = 600;

    function setUp() public {
        mock = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        mock = MockSystemContract(payable(SYSTEM_ADDR));

        vm.warp(1_700_000_000);
        vm.deal(owner, 10 ether);
        vm.prank(owner);
        watcher = new StakeWatcher{ value: 1 ether }();
        vm.prank(owner);
        watcher.setVault(vault);
    }

    function _log(uint256 topic0, uint256 opCode) internal view returns (IReactive.LogRecord memory l) {
        l.topic0 = topic0;
        l.opCode = opCode;
        l.chainId = BASE;
        l.contractAddress = vault;
    }

    function _cron() internal {
        IReactive.LogRecord memory l;
        l.topic0 = CRON100;
        l.opCode = 2;
        l.contractAddress = LEGACY;
        vm.prank(SYSTEM_ADDR);
        watcher.react(l);
    }

    function _goalCreated(uint256 goalId, uint64 startTime, uint8 weeks_) internal {
        IReactive.LogRecord memory l = _log(GOAL_CREATED, 3);
        l.topic1 = goalId;
        l.topic2 = uint256(uint160(owner));
        l.data = abi.encode(referee, penalty, uint256(1 ether), weeks_, PERIOD, startTime);
        vm.prank(SYSTEM_ADDR);
        watcher.react(l);
    }

    function _checkedIn(uint256 goalId, uint256 period) internal {
        IReactive.LogRecord memory l = _log(CHECKED_IN, 2);
        l.topic1 = goalId;
        l.data = abi.encode(period);
        vm.prank(SYSTEM_ADDR);
        watcher.react(l);
    }

    function _forfeited(uint256 goalId, uint256 period) internal {
        IReactive.LogRecord memory l = _log(FORFEITED, 2);
        l.topic1 = goalId;
        l.data = abi.encode(period, uint256(0.5 ether));
        vm.prank(SYSTEM_ADDR);
        watcher.react(l);
    }

    // ------------------------------------------------------------ auth + setup

    function test_ConstructorSubscribesCron() public {
        assertEq(mock.subscriptionCount(), 5); // 1 cron + 4 vault topics
    }

    function test_React_OnlySystem() public {
        IReactive.LogRecord memory l = _log(CRON100, 1);
        l.contractAddress = LEGACY;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, owner, SYSTEM_ADDR));
        watcher.react(l);
    }

    function test_SetVault_OnlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(StakeWatcher.NotOwner.selector);
        watcher.setVault(makeAddr("other"));
    }

    function test_SetVault_Once() public {
        vm.prank(owner);
        vm.expectRevert(StakeWatcher.VaultAlreadySet.selector);
        watcher.setVault(makeAddr("other"));
    }

    function test_PauseResume_TogglesCronSub() public {
        vm.prank(owner);
        watcher.pause();
        assertEq(mock.unsubscriptionCount(), 1);
        vm.prank(owner);
        watcher.resume();
        assertEq(mock.subscriptionCount(), 6);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(StakeWatcher.NotOwner.selector);
        watcher.pause();
    }

    // ------------------------------------------------------------ GoalCreated

    function test_GoalCreated_Mirrors() public {
        _goalCreated(0, uint64(block.timestamp), 2);
        (uint64 startTime, uint64 periodSeconds, uint8 weeks_, bool active,,,) = watcher.mirror(0);
        assertEq(startTime, block.timestamp);
        assertEq(periodSeconds, PERIOD);
        assertEq(weeks_, 2);
        assertTrue(active);
        assertEq(watcher.goalIds(0), 0);
    }

    function test_GoalCreated_WrongChain_Ignored() public {
        IReactive.LogRecord memory l = _log(GOAL_CREATED, 3);
        l.chainId = 1;
        l.topic1 = 9;
        l.data = abi.encode(referee, penalty, uint256(1 ether), uint8(2), PERIOD, uint64(block.timestamp));
        vm.prank(SYSTEM_ADDR);
        watcher.react(l);
        (,,, bool active,,,) = watcher.mirror(9);
        assertFalse(active);
    }

    function test_GoalCreated_WrongOpCode_Ignored() public {
        IReactive.LogRecord memory l = _log(GOAL_CREATED, 2); // lying about topic count
        l.topic1 = 9;
        l.data = abi.encode(referee, penalty, uint256(1 ether), uint8(2), PERIOD, uint64(block.timestamp));
        vm.prank(SYSTEM_ADDR);
        watcher.react(l);
        (,,, bool active,,,) = watcher.mirror(9);
        assertFalse(active);
    }

    // ------------------------------------------------------------ cron ticks

    function test_Tick_RequestsForfeit_WhenPeriodEnded() public {
        // Period 0 ended 1 second ago.
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 2);
        _cron();
        assertEq(mock.callbackCount(), 1);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = mock.callbacks(0);
        assertEq(chainId, BASE);
        assertEq(recipient, vault);
        assertEq(gasLimit, 300_000);
        assertEq(bytes4(payload), IStakeVault.forfeit.selector);
        (address rvm, uint256 gid, uint256 period) = _decodeForfeit(payload);
        assertEq(rvm, address(0)); // placeholder, proxy injects watcher address
        assertEq(gid, 0);
        assertEq(period, 0);
    }

    function test_Tick_NoForfeit_WhenPeriodRunning() public {
        _goalCreated(0, uint64(block.timestamp), 2); // period 0 just started
        _cron();
        assertEq(mock.callbackCount(), 0);
    }

    function test_Tick_NoForfeit_WhenConfirmed() public {
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 2);
        _checkedIn(0, 0);
        _cron();
        assertEq(mock.callbackCount(), 0);
    }

    function test_Tick_NoImmediateResend() public {
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 2);
        _cron();
        assertEq(mock.callbackCount(), 1);
        _cron(); // same tick window — cooldown blocks resend
        assertEq(mock.callbackCount(), 1);
    }

    function test_Tick_ResendsAfterCooldown() public {
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 2);
        _cron();
        assertEq(mock.callbackCount(), 1);
        vm.warp(block.timestamp + watcher.RESEND_COOLDOWN() + 1);
        _cron();
        assertEq(mock.callbackCount(), 2);
    }

    function test_Tick_ReleaseAfterForfeited() public {
        // One-week goal, period ended; first tick requests forfeit.
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 1);
        _cron();
        assertEq(mock.callbackCount(), 1);

        // Vault reports the forfeit landed; next tick requests release.
        _forfeited(0, 0);
        _cron();
        assertEq(mock.callbackCount(), 2);
        (, , , bytes memory payload) = mock.callbacks(1);
        assertEq(bytes4(payload), IStakeVault.release.selector);
    }

    function test_Tick_ReleaseWithoutForfeitLog_Waits() public {
        // All periods settled only via confirmations.
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 1);
        _checkedIn(0, 0);
        _cron();
        assertEq(mock.callbackCount(), 1); // straight to release
        (, , , bytes memory payload) = mock.callbacks(0);
        assertEq(bytes4(payload), IStakeVault.release.selector);
    }

    function test_Released_DeactivatesGoal() public {
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 1);
        IReactive.LogRecord memory l = _log(RELEASED, 2);
        l.topic1 = 0;
        l.data = abi.encode(uint256(0.5 ether));
        vm.prank(SYSTEM_ADDR);
        watcher.react(l);
        (,,, bool active,,,) = watcher.mirror(0);
        assertFalse(active);
        _cron();
        assertEq(mock.callbackCount(), 0);
    }

    function test_Tick_Paused_DoesNothing() public {
        _goalCreated(0, uint64(block.timestamp - PERIOD - 1), 1);
        vm.prank(owner);
        watcher.pause();
        _cron();
        assertEq(mock.callbackCount(), 0);
    }

    // ------------------------------------------------------------ helpers

    function _decodeForfeit(bytes memory payload)
        internal
        pure
        returns (address rvm, uint256 goalId, uint256 period)
    {
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i; i < args.length; ++i) args[i] = payload[i + 4];
        return abi.decode(args, (address, uint256, uint256));
    }
}
