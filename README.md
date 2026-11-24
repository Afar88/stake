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

_Deployment pending — waiting on testnet funding._

| Contract | Address |
| --- | --- |
| StakeWatcher (Lasna) | TBD |
| StakeVault (Base Sepolia) | TBD |
| Deployer wallet | `0x5874531C1981c1717263fA259Ee5f4099EA8D712` |

## Live run (10-minute "weeks")

_Pending deploy._

| Step | Tx hash |
| --- | --- |
| GoalCreated | TBD |
| CheckedIn (week 1) | TBD |
| Cron reaction → forfeit (week 2) | TBD |
| Forfeited on Base | TBD |
| Cron reaction → release | TBD |
| Released on Base | TBD |

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
