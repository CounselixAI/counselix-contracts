# counselix-contracts

Smart contracts for **Counselix**, a decentralized AI consulting marketplace built on a Bittensor subnet.

Miners run AI consulting agents. Users subscribe to the platform and pick one agent as their **Main AI Agent**. These
contracts record every subscription payment and the agent it is credited to, so that subnet validators can set miner
weights from verifiable on-chain revenue.

```
counselix-backend ──writes──▶ counselix-contracts ◀──reads── counselix-subnet (validators)
```

## Contracts

| Contract | Purpose |
|---|---|
| [`CounselixRegistry`](src/CounselixRegistry.sol) | Consulting categories (e.g. Education) and the agents offered in each, keyed by miner hotkey |
| [`CounselixLedger`](src/CounselixLedger.sol) | Subscription payments and refunds, credited to agents and aggregated per epoch |

## Revenue attribution: the Selected Agent model

Each user selects one agent as their **Main AI Agent**. **100% of every subscription payment the user makes is
credited to that agent**, and so to the miner whose hotkey operates it.

- **Attribution is fixed per payment.** The backend records the user's Main Agent at the time of payment. If the user
  switches Main Agent, the new agent is credited from the user's next payment.
- **Epochs close on their own.** A payment or refund is credited to the epoch that contains `block.timestamp`, not to
  a time supplied by the backend. Writes can only land in the current epoch, so every past epoch is immutable and
  there is no separate submit or finalize step.
- **Refunds** are booked in the epoch in which they happen, against the agent the original payment was credited to.
  Past epochs are never rewritten. Validators score **net revenue = revenue − refunded** summed over their window.
- **Only active agents in active categories** can receive payments.

### Data model

- **Agent:** `(agentId, hotkey, categoryId, active, registeredAt, metadataURI)`. `hotkey` is the miner's 32-byte
  sr25519 public key. There is at most one agent per hotkey per category. Validators map hotkey → UID with the
  metagraph; UIDs are not stored because they can be recycled.
- **Payment:** `(paymentId, userId, agentId, amount, refunded, paidAt, periodStart, periodEnd, epoch)`.
- **Per-epoch, per-agent stats:** `revenue`, `refunded`, `payments` and `uniquePayers`.

**Units:** all amounts are **micro-USD** (6 decimals), so `1_000_000` = $1.00.
**Privacy:** `userId` and `paymentId` are salted hashes. No personal data is stored on-chain.

### Roles

| Role | Contract | Holder |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | both | Admin multisig; grants and revokes roles |
| `OPERATOR_ROLE` | Registry | Platform backend; manages categories and agents |
| `RECORDER_ROLE` | Ledger | Platform backend; records payments and refunds |

## For validators

Read the closed epochs in your scoring window and sum net revenue per hotkey:

```python
# web3.py, illustrative
current = ledger.functions.currentEpoch().call()          # still open; do not score it
net = defaultdict(int)
for epoch in range(max(0, current - WINDOW), current):
    ids, revenues, refunds, payments, payers = ledger.functions.getEpochAttribution(epoch).call()
    for agent_id, rev, ref in zip(ids, revenues, refunds):
        hotkey = registry.functions.getAgent(agent_id).call()[0]
        net[hotkey] += rev - ref
scores = {hk: max(0, v) for hk, v in net.items()}         # map hotkey -> UID via the metagraph
```

Make `WINDOW` at least as long as the longest billing period. Otherwise a monthly payment counts in one window and
then drops out completely in the next. `uniquePayers` lets validators down-weight agents whose revenue comes from
very few payers, which can be a sign of self-dealing.

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recursive https://github.com/CounselixAI/counselix-contracts.git
forge build
forge test -vvv
forge fmt
```

Dependencies are git submodules pinned to OpenZeppelin Contracts `v5.1.0` and forge-std `v1.9.4`.

## Deployment

The target is the Bittensor EVM (subtensor). Configure the variables in `.env.example`, then run:

```bash
source .env
forge script script/Deploy.s.sol --rpc-url bittensor_testnet --private-key $PRIVATE_KEY --broadcast
```

RPC endpoints are set in [`foundry.toml`](foundry.toml). Check them against the current Bittensor documentation
before deploying.

## Trust model

The backend is the only writer, so validators trust it to report payments and Main Agent selections honestly. The
contracts make that reporting **public, permanent and auditable**: every payment, its agent and every refund are
on-chain, and closed epochs cannot be changed. Reducing this trust further (for example on-chain payments, or
user-signed Main Agent selections) is planned work.

## License

[MIT](LICENSE)
