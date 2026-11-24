// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { IStakeVault } from "./interfaces/IStakeVault.sol";

/// @title StakeWatcher
/// @notice Reactive contract on Reactive Lasna. Mirrors StakeVault goals from Base Sepolia
///         event logs, and on every Cron100 tick asks the vault (via callbacks) to forfeit
///         ended-unconfirmed periods and to release finished goals. No bot, no server.
/// @dev The vault re-checks every rule with its own clock, so this contract only needs to be
///      eventually right: sends are idempotent on the vault side, and unacknowledged sends
///      (no matching Forfeited/Released log back) are retried after a cooldown.
contract StakeWatcher is AbstractReactive {
    // ------------------------------------------------------------------ constants

    uint256 public constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    uint256 internal constant CRON100_TOPIC_0 =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant GOAL_CREATED_TOPIC_0 = uint256(keccak256(
        "GoalCreated(uint256,address,address,address,uint256,uint8,uint64,uint64)"
    ));
    uint256 internal constant CHECKED_IN_TOPIC_0 = uint256(keccak256("CheckedIn(uint256,uint256)"));
    uint256 internal constant FORFEITED_TOPIC_0 = uint256(keccak256("Forfeited(uint256,uint256,uint256)"));
    uint256 internal constant RELEASED_TOPIC_0 = uint256(keccak256("Released(uint256,uint256)"));

    uint64 internal constant CALLBACK_GAS_LIMIT = 300_000;
    /// @notice How many goals a single tick may walk before deferring to the next tick.
    uint256 internal constant MAX_GOALS_PER_TICK = 20;
    /// @notice Re-request a forfeit/release if this long passed since the last attempt.
    uint256 public constant RESEND_COOLDOWN = 4 minutes;
    uint8 internal constant MAX_WEEKS = 12;

    // ------------------------------------------------------------------ storage

    address public owner;
    address public vault;
    bool public paused;

    struct MirrorGoal {
        uint64 startTime;
        uint64 periodSeconds;
        uint8 numWeeks;
        bool active;
        uint16 confirmedMask;    // from CheckedIn logs
        uint16 forfeitedMask;    // from Forfeited logs
        uint64 releaseSentAt;
        uint64[12] forfeitSentAt; // per period, last forfeit request timestamp
    }

    uint256[] public goalIds;
    mapping(uint256 => MirrorGoal) public mirror;
    uint256 public cursor;

    // ------------------------------------------------------------------ errors / events

    error NotOwner();
    error VaultAlreadySet();

    event VaultSet(address indexed vault);
    event GoalMirrored(uint256 indexed goalId);
    event ConfirmationMirrored(uint256 indexed goalId, uint256 periodIndex);
    event ForfeitMirrored(uint256 indexed goalId, uint256 periodIndex);
    event ReleaseMirrored(uint256 indexed goalId);
    event CallbackRequested(uint256 indexed goalId, uint256 periodIndex);
    event ReleaseRequested(uint256 indexed goalId);
    event Paused();
    event Resumed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Payable so the contract can hold REACT for billing from the start.
    constructor() payable {
        owner = msg.sender;
        _subscribeCron();
    }

    // ------------------------------------------------------------------ owner API

    /// @notice Point the watcher at the deployed StakeVault and subscribe to its logs.
    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
        _subscribeVault();
        emit VaultSet(vault_);
    }

    /// @notice Stop paying for Cron100 ticks.
    function pause() external onlyOwner {
        if (paused) return;
        paused = true;
        _unsubscribeCron();
        emit Paused();
    }

    /// @notice Resume Cron100 ticks.
    function resume() external onlyOwner {
        if (!paused) return;
        paused = false;
        _subscribeCron();
        emit Resumed();
    }

    /// @notice Settles outstanding debt to the system contract from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------ react

    /// @inheritdoc IReactive
    /// @dev Routes on topic0 and checks opCode (topic count) before decoding anything.
    function react(LogRecord memory log_) external onlySystem {
        if (log_.topic0 == CRON100_TOPIC_0) {
            if (log_.opCode != 1 || log_.contractAddress != LEGACY_SYSTEM_ADDR) return;
            if (!paused && vault != address(0)) _tick();
            return;
        }
        if (log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != vault) return;

        if (log_.topic0 == GOAL_CREATED_TOPIC_0) {
            if (log_.opCode != 3) return;
            _onGoalCreated(log_);
        } else if (log_.topic0 == CHECKED_IN_TOPIC_0) {
            if (log_.opCode != 2) return;
            _onCheckedIn(log_);
        } else if (log_.topic0 == FORFEITED_TOPIC_0) {
            if (log_.opCode != 2) return;
            _onForfeited(log_);
        } else if (log_.topic0 == RELEASED_TOPIC_0) {
            if (log_.opCode != 2) return;
            _onReleased(log_);
        }
    }

    // ------------------------------------------------------------------ vault log handlers

    function _onGoalCreated(LogRecord memory log_) internal {
        uint256 goalId = log_.topic1;
        MirrorGoal storage g = mirror[goalId];
        if (g.numWeeks != 0) return; // already mirrored
        (,,, uint8 weeks_, uint64 periodSeconds_, uint64 startTime_) = abi.decode(
            log_.data, (address, address, uint256, uint8, uint64, uint64)
        );
        if (weeks_ == 0 || weeks_ > MAX_WEEKS) return;

        goalIds.push(goalId);
        g.startTime = startTime_;
        g.periodSeconds = periodSeconds_;
        g.numWeeks = weeks_;
        g.active = true;
        emit GoalMirrored(goalId);
    }

    function _onCheckedIn(LogRecord memory log_) internal {
        uint256 goalId = log_.topic1;
        MirrorGoal storage g = mirror[goalId];
        if (!g.active) return;
        uint256 periodIndex = abi.decode(log_.data, (uint256));
        if (periodIndex >= g.numWeeks) return;
        g.confirmedMask |= uint16(1 << periodIndex);
        emit ConfirmationMirrored(goalId, periodIndex);
    }

    function _onForfeited(LogRecord memory log_) internal {
        uint256 goalId = log_.topic1;
        MirrorGoal storage g = mirror[goalId];
        if (!g.active) return;
        (uint256 periodIndex,) = abi.decode(log_.data, (uint256, uint256));
        if (periodIndex >= g.numWeeks) return;
        g.forfeitedMask |= uint16(1 << periodIndex);
        emit ForfeitMirrored(goalId, periodIndex);
    }

    function _onReleased(LogRecord memory log_) internal {
        uint256 goalId = log_.topic1;
        MirrorGoal storage g = mirror[goalId];
        g.active = false;
        emit ReleaseMirrored(goalId);
    }

    // ------------------------------------------------------------------ tick

    /// @dev Walks up to MAX_GOALS_PER_TICK mirrored goals, round-robin via `cursor`.
    ///      For each: request forfeit for any ended-unconfirmed-unsettled period, then
    ///      request release once every period is settled and the last one ended.
    function _tick() internal {
        uint256 total = goalIds.length;
        if (total == 0) return;

        uint256 scanned;
        for (uint256 i; i < total && scanned < MAX_GOALS_PER_TICK; ++i) {
            uint256 goalId = goalIds[(cursor + i) % total];
            MirrorGoal storage g = mirror[goalId];
            if (!g.active) continue;
            ++scanned;
            _settleGoal(goalId, g);
        }
        cursor = (cursor + MAX_GOALS_PER_TICK) % total;
    }

    function _settleGoal(uint256 goalId_, MirrorGoal storage g) internal {
        uint256 nowTs = block.timestamp;
        bool allSettled = true;

        for (uint256 p; p < g.numWeeks; ++p) {
            bool done = ((g.confirmedMask >> p) | (g.forfeitedMask >> p)) & 1 == 1;
            if (done) continue;

            allSettled = false;
            if (nowTs < _periodEnd(g, p)) break; // period running; later periods can't have ended
            if (nowTs >= uint256(g.forfeitSentAt[p]) + RESEND_COOLDOWN) {
                g.forfeitSentAt[p] = uint64(nowTs);
                _requestForfeit(goalId_, p);
            }
        }

        bool lastEnded = nowTs >= _periodEnd(g, g.numWeeks - 1);
        if (allSettled && lastEnded && nowTs >= uint256(g.releaseSentAt) + RESEND_COOLDOWN) {
            g.releaseSentAt = uint64(nowTs);
            _requestRelease(goalId_);
        }
    }

    function _periodEnd(MirrorGoal storage g, uint256 periodIndex_) internal view returns (uint256) {
        return uint256(g.startTime) + (periodIndex_ + 1) * uint256(g.periodSeconds);
    }

    // ------------------------------------------------------------------ callbacks to the vault

    function _requestForfeit(uint256 goalId_, uint256 periodIndex_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: ORIGIN_CHAIN_ID,
                recipient: vault,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeCall(IStakeVault.forfeit, (address(0), goalId_, periodIndex_))
            })
        );
        emit CallbackRequested(goalId_, periodIndex_);
    }

    function _requestRelease(uint256 goalId_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: ORIGIN_CHAIN_ID,
                recipient: vault,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeCall(IStakeVault.release, (address(0), goalId_))
            })
        );
        emit ReleaseRequested(goalId_);
    }

    // ------------------------------------------------------------------ subscriptions

    function _subscribeCron() internal {
        SYSTEM.subscribe(
            block.chainid, LEGACY_SYSTEM_ADDR, CRON100_TOPIC_0,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function _unsubscribeCron() internal {
        SYSTEM.unsubscribe(
            block.chainid, LEGACY_SYSTEM_ADDR, CRON100_TOPIC_0,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function _subscribeVault() internal {
        // GoalCreated + CheckedIn keep the mirror in sync; Forfeited + Released tell us
        // which requested callbacks actually landed, so sends stay idempotent.
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, vault, GOAL_CREATED_TOPIC_0,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, vault, CHECKED_IN_TOPIC_0,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, vault, FORFEITED_TOPIC_0,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, vault, RELEASED_TOPIC_0,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }
}
