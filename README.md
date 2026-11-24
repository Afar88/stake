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
| GoalCreated | Base Sepolia | `0xa9e80fe31e96b07411747469b743cc982a4136fc106058e4d9ceabd95f7b0bfe` |
| CheckedIn (week 1) | Base Sepolia | `0x17daaf0ded1adee12542e6901f58e2478f195a04014bcf7203b6b5a4106cbb08` |
| Mirror: GoalCreated | Lasna | `0x9d99986f35cd577c73b079b71f4b4be697db40acad980d3092644448efe7714a` |
| Mirror: CheckedIn | Lasna | `0xf8863f83665097b8c72789ec6f1d50f0afcdc6b6cf534472cccac877c9247f1b` |
| Cron tick → forfeit requested | Lasna | `0x20b2b063746c32ca21669ee4a1a4bfc6f1a71e46ba9a0f2ed60183415019c9fc` |
| **Forfeited** — 0.00075 ETH → penalty | Base Sepolia | `0x4feb88c73b9276e453fce3c78ca559f4d4f02b8eb9b8e6e029c50d7d7b914c5a` |
| Mirror: Forfeited | Lasna | `0x5676ea7c2625883956407ee88f1fbcc263b5c1ef5b8b1e5ad51135655ec0187f` |
| Cron tick → release requested | Lasna | `0xa3bc3d85cb171ddccd148381c138215e496a68481d23c856573492ad9029a5ba` |
| **Released** — 0.00075 ETH → owner | Base Sepolia | `0x347c8e833158fa8d32070096761b5af29c6a3f4ea03d4abcac9e4aa3c480528b` |
| Mirror: Released | Lasna | `0x5fd359976e86f0c286e08621a6574790a9cededb212a2abb654eb7f74747c0a6` |

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
