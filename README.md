# counselix-contracts

Smart contracts for **Counselix**, a decentralized AI consulting marketplace built on a Bittensor subnet.

Miners run AI consulting agents. Users subscribe to an agent with **TAO** or **USDC**. These contracts move every
payment straight to the treasury, record it publicly, and record the revenue each agent earns per day. Subnet
validators then reward miners from this on-chain data.

```
                 ┌───────────── Bittensor EVM ─────────────┐        ┌──────── Base ────────┐
user ──TAO──▶ CounselixTaoPayments ──▶ treasury             │        │                      │
                 │  └─ records ─▶ CounselixLedger ◀──reads── validators ──checks──▶ CounselixUsdcPayments ◀──USDC── user
                 │                  ▲      ▲                │        │        └──▶ treasury (Base)
                 │   relays USDC ───┘      └─── daily revenue, heartbeat (counselix-backend)
                 └─────────────────────────────────────────┘        └──────────────────────┘
```

## Contracts

| Contract | Chain | Purpose |
|---|---|---|
| [`CounselixRegistry`](src/CounselixRegistry.sol) | Bittensor EVM | Consulting categories and the agents in each, keyed by miner hotkey |
| [`CounselixLedger`](src/CounselixLedger.sol) | Bittensor EVM | Payments, daily revenue per agent, and platform service status |
| [`CounselixTaoPayments`](src/CounselixTaoPayments.sol) | Bittensor EVM | TAO subscriptions: forwards TAO to the treasury and records the payment in one transaction |
| [`UniswapV3TaoUsdOracle`](src/oracles/UniswapV3TaoUsdOracle.sol) | Bittensor EVM | TAO market price: 30-minute average of the WTAO/USDC Uniswap V3 pool |
| [`CounselixUsdcPayments`](src/CounselixUsdcPayments.sol) | Base | USDC subscriptions: forwards native USDC to the treasury and emits the payment |

## Payments

Plans are **Monthly (30 days)** and **Annual (365 days)**. Every agent has the same price, which the admin sets in
each payments contract. Prices are in micro-USD, so `20_000_000` is $20.00.

**TAO (Bittensor EVM).** `CounselixTaoPayments.pay(paymentId, userId, agentId, plan)` does all of the following in
**one transaction**:
1. computes the TAO amount for the plan's USD price from the TAO market price (`quote(plan)` shows it in advance);
2. sends exactly that amount to the treasury and returns any excess to the payer;
3. records the payment in the Ledger with its fixed USD value and the TAO price used.

The payment fails if the agent is not active.

**USDC (Base).** Users approve the plan price, then call `CounselixUsdcPayments.pay(...)`. The USDC goes straight
to the treasury on Base, and the contract emits `UsdcPaymentReceived`. The backend relays each payment to
`CounselixLedger.recordBaseUsdcPayment` with the **Base transaction hash and log index**. Anyone, including
validators, can check each relayed record against the event on Base.

**Treasury.** The payments contracts never hold funds. Each forwards payments to a treasury address, which only
the admin can change. The dev team manages the treasury manually; no contract controls how it is used.

### TAO price

[`UniswapV3TaoUsdOracle`](src/oracles/UniswapV3TaoUsdOracle.sol) reads the time-weighted average tick of the WTAO/USDC
0.3% pool on Bittensor EVM over 30 minutes, and values 1 USDC at $1. Defaults used by the deploy script:

| | Address |
|---|---|
| WTAO/USDC 0.3% pool | `0x6647dcbeb030dc8E227D8B1A2Cb6A49F3C887E3c` |
| WTAO | `0x9Dc08C6e2BF0F1eeD1E00670f80Df39145529F81` |
| USDC (bridged, in the pool) | `0xB833E8137FEDf80de7E908dc6fea43a029142F20` |

The pool's liquidity is small, so the admin can replace the oracle with `setOracle` when a deeper price source
becomes available. The pool must keep enough observations to cover 30 minutes. If it does not, call
`increaseObservationCardinalityNext` on the pool once.

## Daily revenue

Days follow **UTC midnight** (`genesis` must be one). Revenue follows the agent that actually served the user. Each
subscription's USD value is spread evenly over its active days, and each day's share goes to the agent or agents
that served the user that day.

After a day ends, the backend calls `submitDailyRevenue(day, agentIds, usdAmounts, allocationRoot)`:
- `allocationRoot` is the Merkle root of the per-user allocations behind the totals, so they can be audited.
- A day can be submitted only once, and only after it has ended.
- **Total revenue recognized can never exceed total USD paid**, and the contract enforces this.

## Service status

The backend calls `heartbeat()` every minute. It calls `setNoAgentsAvailable(true)` while no agent on the whole
platform is available, and `false` once one is again. `isServiceDown()` is true while that flag is set or no
heartbeat arrived within `heartbeatTimeout` (180 seconds by default). Validators burn miner emissions while
`isServiceDown()` is true.

## Roles

| Role | Contract | Holder |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | all | Admin multisig: roles, treasury, prices, oracle, heartbeat timeout |
| `OPERATOR_ROLE` | Registry | Backend: categories and agents |
| `PAYMENTS_ROLE` | Ledger | `CounselixTaoPayments` |
| `RELAYER_ROLE` | Ledger | Backend: relays USDC payments from Base |
| `RECORDER_ROLE` | Ledger | Backend: daily revenue, heartbeat, no-agents flag |

## For validators

```python
# web3.py, illustrative
if ledger.functions.isServiceDown().call():
    ...  # burn: all weight to the burn UID
day = ledger.functions.currentDay().call() - 1          # last closed day
agent_ids, usd_amounts = ledger.functions.getDailyRevenue(day).call()
hotkey = registry.functions.getAgent(agent_id).call()[0]
```

The scoring itself (an EMA of daily revenue, rank-based rewards, USDC checks against Base) lives in
[counselix-subnet](https://github.com/CounselixAI/counselix-subnet).

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recursive https://github.com/CounselixAI/counselix-contracts.git
forge build
forge test -vvv
forge fmt
BITTENSOR_RPC_URL=https://lite.chain.opentensor.ai forge test --match-test Fork -vv   # oracle on the live pool
```

Dependencies are git submodules pinned to OpenZeppelin Contracts `v5.1.0` and forge-std `v1.9.4`.

## Deployment

Configure the variables in `.env.example`, then deploy to each chain:

```bash
source .env
# Bittensor EVM: Registry, Ledger, oracle, TAO payments
forge script script/Deploy.s.sol --rpc-url bittensor_mainnet --private-key $PRIVATE_KEY --broadcast
# Base: USDC payments
forge script script/DeployBase.s.sol --rpc-url base --private-key $PRIVATE_KEY --broadcast
```

Run either command without `--broadcast` first to simulate it. RPC endpoints are set in
[`foundry.toml`](foundry.toml).

## Trust model

- **Verifiable on-chain:** every payment, where its funds went, its USD value, the TAO price used, daily revenue
  totals, and that revenue never exceeds payments.
- **USDC:** relayed by the backend, but each record names its Base transaction, so anyone can check it.
- **Reported by the backend:** how each day's revenue is split between agents, published with a Merkle root of
  the per-user allocations for audit, and the service status signals.

## License

[MIT](LICENSE)
