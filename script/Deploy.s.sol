// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { StakeVault } from "../src/StakeVault.sol";
import { StakeWatcher } from "../src/StakeWatcher.sol";

/// @notice Minimal depositTo() shared by the Lasna system contract and the Base Sepolia
///         callback proxy: credits fee reserves for a contract address.
interface IReserveSink {
    function depositTo(address contract_) external payable;
}

/// @notice Testnet lREACT faucet on Base Sepolia: request(address) swaps Base Sepolia ETH
///         for lREACT on Lasna (1 ETH = 100 lREACT, max 5 ETH per call).
interface ILReactFaucet {
    function request(address wallet_) external payable;
}

address constant CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
address constant SYSTEM_CONTRACT = 0x8888888888888888888888888888888888888888;
address constant LREACT_FAUCET = 0x2afaFD298b23b62760711756088F75B7409f5967;

/// @notice 1/5 · Reactive Lasna — deploy the watcher first. Run with --rpc-url $LASNA_RPC.
contract DeployWatcher is Script {
    function run() external returns (address watcher) {
        vm.startBroadcast();
        watcher = address(new StakeWatcher());
        vm.stopBroadcast();
        console.log("StakeWatcher:", watcher);
    }
}

/// @notice 2/5 · Base Sepolia — deploy the vault bound to the watcher and the callback proxy.
///         Run with --rpc-url $BASE_SEPOLIA_RPC and WATCHER_ADDRESS set.
contract DeployVault is Script {
    function run() external returns (address vault) {
        address watcher = vm.envAddress("WATCHER_ADDRESS");
        vm.startBroadcast();
        vault = address(new StakeVault(IPayable(payable(CALLBACK_PROXY)), watcher));
        vm.stopBroadcast();
        console.log("StakeVault:", vault);
    }
}

/// @notice 3/5 · Reactive Lasna — point the watcher at the vault (subscribes to its events).
///         Run with --rpc-url $LASNA_RPC and WATCHER_ADDRESS + VAULT_ADDRESS set.
contract SetVault is Script {
    function run() external {
        vm.startBroadcast();
        StakeWatcher(payable(vm.envAddress("WATCHER_ADDRESS"))).setVault(vm.envAddress("VAULT_ADDRESS"));
        vm.stopBroadcast();
    }
}

/// @notice 4/5 · Both chains — fund fee reserves via depositTo(). Run once per network:
///         --rpc-url $LASNA_RPC      -> credits the watcher's lREACT reserves
///         --rpc-url $BASE_SEPOLIA_RPC -> credits the vault's Base Sepolia ETH reserves
contract FundReserves is Script {
    function run() external {
        if (block.chainid == 5318007) {
            address watcher = vm.envAddress("WATCHER_ADDRESS");
            uint256 amount = vm.envOr("FUND_AMOUNT", uint256(0.5 ether));
            vm.startBroadcast();
            IReserveSink(SYSTEM_CONTRACT).depositTo{ value: amount }(watcher);
            // Also drop balance on the contract itself so pay()/coverDebt() have something to draw on.
            (bool ok,) = watcher.call{ value: amount }("");
            require(ok, "watcher funding failed");
            vm.stopBroadcast();
            console.log("Watcher funded with", amount);
        } else if (block.chainid == 84532) {
            address vault = vm.envAddress("VAULT_ADDRESS");
            uint256 amount = vm.envOr("FUND_AMOUNT", uint256(0.05 ether));
            vm.startBroadcast();
            IReserveSink(CALLBACK_PROXY).depositTo{ value: amount }(vault);
            vm.stopBroadcast();
            console.log("Vault reserves funded with", amount);
        } else {
            revert("unsupported chain");
        }
    }
}

/// @notice Optional · Base Sepolia — swap Base Sepolia ETH for testnet lREACT.
contract FaucetLReact is Script {
    function run() external {
        address wallet = vm.envAddress("WALLET_ADDRESS");
        uint256 amount = vm.envOr("FAUCET_AMOUNT", uint256(1 ether));
        vm.startBroadcast();
        ILReactFaucet(LREACT_FAUCET).request{ value: amount }(wallet);
        vm.stopBroadcast();
        console.log("Requested lREACT for", wallet);
    }
}

/// @notice 5/5 · Base Sepolia — open a demo goal. Configurable via env so the live run
///         can use 10-minute "weeks". Run with --rpc-url $BASE_SEPOLIA_RPC.
contract CreateDemoGoal is Script {
    function run() external returns (uint256 goalId) {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address referee = vm.envAddress("REFEREE_ADDRESS");
        address penaltyTo = vm.envAddress("PENALTY_ADDRESS");
        uint8 numWeeks = uint8(vm.envOr("GOAL_WEEKS", uint256(2)));
        uint64 periodSeconds = uint64(vm.envOr("GOAL_PERIOD_SECONDS", uint256(600)));
        uint256 stake = vm.envOr("GOAL_STAKE", uint256(0.02 ether));

        vm.startBroadcast();
        string memory text = vm.envOr("GOAL_TEXT", string("Run 3 times a week"));
        goalId = StakeVault(payable(vaultAddr)).createGoal{ value: stake }(
            text, referee, penaltyTo, numWeeks, periodSeconds
        );
        vm.stopBroadcast();
        console.log("Goal:", goalId);
    }
}
