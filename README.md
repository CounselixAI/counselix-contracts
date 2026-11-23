# counselix-contracts

Smart contracts for **Counselix**, a decentralized AI consulting marketplace built on a Bittensor subnet.

Miners run AI consulting agents. Users subscribe to the platform and choose the agents they like. These contracts
record subscription payments and how revenue is attributed to each agent, so that subnet validators can set miner
weights from verifiable on-chain data.

```
counselix-backend ──writes──▶ counselix-contracts ◀──reads── counselix-subnet (validators)
```

## Contracts

| Contract | Purpose |
|---|---|
| [`CounselixRegistry`](src/CounselixRegistry.sol) | Consulting categories (e.g. Education) and the agents offered in each, keyed by miner hotkey |
| [`CounselixLedger`](src/CounselixLedger.sol) | Subscription payments and finalized per-epoch revenue attribution to agents |

### Data model

- **Agent:** `(agentId, hotkey, categoryId, active, registeredAt, metadataURI)`. `hotkey` is the miner's 32-byte
  sr25519 public key. There is at most one agent per hotkey per category. Validators map hotkey → UID with the
  metagraph; UIDs are not stored because they can be recycled.
- **Payment:** `(paymentId, userId, amount, paidAt, periodStart, periodEnd)`. Each one is written when a user pays
  for a subscription.
- **Epoch attribution:** for each epoch (fixed length, starting at `genesis`), the revenue, consultation count and
  unique payer count credited to each agent.

**Units:** all amounts are **micro-USD** (6 decimals), so `1_000_000` = $1.00.
**Privacy:** `userId` and `paymentId` are salted hashes. No personal data is stored on-chain.

### Epoch lifecycle

1. The epoch ends (`block.timestamp >= epochBounds(epoch).end`).
2. The backend calls `submitAttribution(epoch, rows)` one or more times. Large epochs can be split into chunks.
3. The backend may call `resetEpoch(epoch)` to discard a bad submission and resubmit.
4. The backend calls `finalizeEpoch(epoch, usageRoot)`. Epochs are finalized strictly in order, and empty epochs are
   allowed. A finalized epoch cannot be changed. `usageRoot` is a Merkle root of the off-chain usage records behind
   the attribution, so the data can be audited later.

### Roles

| Role | Contract | Holder |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | both | Admin multisig; grants and revokes roles |
| `OPERATOR_ROLE` | Registry | Platform backend; manages categories and agents |
| `RECORDER_ROLE` | Ledger | Platform backend; records payments and attribution |

## For validators

Read every finalized epoch in your scoring window and sum revenue per hotkey:

```python
# web3.py, illustrative
n = ledger.functions.finalizedEpochCount().call()
for epoch in range(max(0, n - WINDOW), n):
    for row in zip(*ledger.functions.getEpochAttribution(epoch).call()):
        agent_id, revenue, consultations, unique_payers = row
        hotkey = registry.functions.getAgent(agent_id).call()[0]
        ...
```

`uniquePayers` is provided so that validators can down-weight revenue that comes from very few payers (a possible
sign of self-dealing).

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recursive <repo-url>    # or: git submodule update --init --recursive
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

The backend is the only writer, so validators trust it to report usage honestly. The contracts make that reporting
**public, permanent and auditable**: every payment and attribution row is on-chain, and finalized epochs cannot be
changed afterwards. Reducing this trust further (for example signed usage receipts from miners, or on-chain
payments) is planned work.

## License

[MIT](LICENSE)
