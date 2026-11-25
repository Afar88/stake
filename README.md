# stake

Lock ETH on a weekly goal. A friend confirms each week. Miss a week, lose that week's slice. Finish the goal, get the rest back. No bot, no server — a Reactive Network contract does the chasing.

**Testnet only.** Built for the Reactive Omni Buildathon (DoraHacks, "Set It and Forget It").

## How it works

```
You ── createGoal(referee, penalty, weeks, periodSeconds) ──▶ StakeVault (Base Sepolia)
                                        │  emits GoalCreated
                                        ▼
                              StakeWatcher (Reactive Lasna)
                                        │  mirrors the goal
   referee ── confirm(goalId) ──▶ vault │  emits CheckedIn ──▶ watcher marks week done
                                        │
   Cron100 tick (~2 min) ──────────────▶ watcher
                                        │  week ended, not confirmed ──▶ callback: forfeit()
                                        │  all weeks settled, last ended ──▶ callback: release()
                                        ▼
                          missed slice → penalty wallet · rest → you
```

- **StakeVault** (Base Sepolia) holds the stake, takes referee check-ins, and pays out. It is the source of truth: every callback is re-checked against its own `block.timestamp`. An early or repeated callback emits `Skipped` instead of reverting (failed callbacks are still billed).
- **StakeWatcher** (Reactive Lasna) subscribes to the vault's `GoalCreated`/`CheckedIn`/`Forfeited`/`Released` logs plus a `Cron100` heartbeat from the legacy system contract. Each tick it walks the mirrored goals (max 20 per tick), requests `forfeit()` for ended-unconfirmed periods, then `release()` once everything is settled. Sends are idempotent on the vault side, and unconfirmed sends retry after a 4-minute cooldown.

## Networks

| Contract | Chain | Chain ID | Auth |
| --- | --- | --- | --- |
| StakeVault | Base Sepolia | 84532 | callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585` + rvmId = watcher |
| StakeWatcher | Reactive Lasna | 5318007 | system contract `0x8888...8888` |

## Deployed addresses

| Contract | Address |
| --- | --- |
| StakeWatcher (Lasna, chain 5318007) | `0x1a4197d80997e285f0f2b928B0d6441444Cb1f8b` |
| StakeVault (Base Sepolia, chain 84532) | `0x1a4197d80997e285f0f2b928B0d6441444Cb1f8b` |
| Deployer wallet | `0x5874531C1981c1717263fA259Ee5f4099EA8D712` |

(Same address on both chains by coincidence — same deployer, same nonce.)

## Live run (10-minute "weeks")

A real 2-week goal, week 1 confirmed, week 2 skipped. The watcher did the rest on its own — no bot, no server. Stake 0.0015 ETH; week 2's slice (0.00075) went to the penalty wallet `0xeFfD2FA6190eF0b99213c746a5B8bC22A5000388`, the rest came back to the owner.

| Step | Chain | Tx hash |
| --- | --- | --- |
| GoalCreated | Base Sepolia | `0xaba8c015b7aec873d308dd93abb4b7f06a8939e3dd69c1676ef995cc1f295be5` |
| CheckedIn (week 1) | Base Sepolia | `0xa06d5fa461b16319315ff902e36784491d29ad7b6ed9ae90b872ddd65582b4d3` |
| Mirror: GoalCreated | Lasna | `0xf3068d5f575620f3cb46dc87247a7330eb77e0b1cb6ed0193d79efd10a7ec5dd` |
| Mirror: CheckedIn | Lasna | `0xc817a14a471b4c742770f635e67fc472fffb8c441c0b9e68ab63cf5a085563e2` |
| Cron tick → forfeit requested | Lasna | `0x68c35fc02046c950a7a28aacd8bcdc6ab214a6d50679d9689b442a9016be2914` |
| **Forfeited** — 0.00075 ETH → penalty | Base Sepolia | `0xf0c334581d5c5dacfdec55a7ece6d19c7e4765bdd369d15e87fcd9fa0f90ef05` |
| Mirror: Forfeited | Lasna | `0x31a7a34d815d790bb3d525d83b3387a401bb821eaef855d4c4dbf46b4b9a18c4` |
| Cron tick → release requested | Lasna | `0x31a82aeb9e2cd5be536d029aab1b41865ef978fe8218f734e7cbd918da13ff34` |
| **Released** — 0.00075 ETH → owner | Base Sepolia | `0x3bf42e4e9004e5b028d05c24623522ecede2e7ceb8885948b9108c8c5e13b181` |
| Mirror: Released | Lasna | `0x6dd414596d810d4802ed548d23ac7c578366f308a3df61ade598520b6e44a0fd` |

The forfeit callback landed about one minute after week 2 ended (one cron tick). The release followed one tick after the watcher saw the `Forfeited` log. The watcher is now paused (`pause()`) so it no longer pays for cron ticks.

## Develop

```bash
forge install
forge build
forge test
```

## Deploy

Needs Foundry and env vars (see `.env.example` — never commit `.env` or keys).

```bash
source .env

# 1. Reactive Lasna — watcher first
forge script script/Deploy.s.sol:DeployWatcher \
  --rpc-url $LASNA_RPC --broadcast --private-key $PRIVATE_KEY
# -> set WATCHER_ADDRESS

# 2. Base Sepolia — vault bound to watcher + callback proxy
forge script script/Deploy.s.sol:DeployVault \
  --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY
# -> set VAULT_ADDRESS

# 3. Lasna — wire watcher to vault
forge script script/Deploy.s.sol:SetVault \
  --rpc-url $LASNA_RPC --broadcast --private-key $PRIVATE_KEY

# 4. Fund both sides (depositTo credits fee reserves)
forge script script/Deploy.s.sol:FundReserves --rpc-url $LASNA_RPC --broadcast --private-key $PRIVATE_KEY
forge script script/Deploy.s.sol:FundReserves --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

# lREACT for Lasna gas: swap Base Sepolia ETH at the testnet faucet
forge script script/Deploy.s.sol:FaucetLReact --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY

# 5. Open a demo goal (10-minute weeks)
forge script script/Deploy.s.sol:CreateDemoGoal --rpc-url $BASE_SEPOLIA_RPC --broadcast --private-key $PRIVATE_KEY
```

## License

[MIT](LICENSE)
