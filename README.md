# SEW / PRF Genesis Solidity Package

Initial Solidity implementation of the two-genesis architecture:

- **`protocol-genesis.v1`** — chain-neutral constitutional PRF/SEW identity, computed canonically off-chain.
- **`chain-instance-genesis.v1`** — one EVM execution instance, bound to `chainId`, settlement domain, immutable control-plane deployment, SEW authority adapter, initial authority-state root, and initial configuration root.

This package deliberately does **not** invent an EVM replacement for PRF canonical hashing. PRF SHA-256 roots enter Solidity as `bytes32`.

## Contracts

### `GovGovernor.sol`

Modified version of the supplied SEW OpenZeppelin Governor.

Changes:

1. Adds immutable `prfProtocolGenesisRoot`.
2. Adds `onlyGovernance` PRF compatibility methods:
   - `authorisePrfDecision`
   - `revokePrfDecision`
   - `updatePrfAuthorityStateRoot`
3. Governance parameter mutations (`absoluteQuorum`, non-circulating list) now use `onlyGovernance`, not merely `msg.sender == timelock`.
4. Fixes `proposalNeedsQueuing` so the actual `proposalId` is forwarded.
5. Removes unchecked wrapping from the reporting-only circulating-supply helper.

The intent is that **SEW Governor + Timelock remain the authority mechanism**. PRF does not get a parallel administrator.

### `SewGovernanceAuthorityAdapter.sol`

Thin compatibility layer controlled only by `GovGovernor`.

A successful SEW governance proposal can register a canonical decision root with:

- direct target chain instance; or
- an EEZ-style target-set Merkle root;
- exact parent configuration root;
- exact next configuration root;
- exact epoch.

It also implements ERC-1271 as a contract/governance authority representation.

### `PrfChainInstanceGenesis.sol`

Two-stage sealed chain-instance identity.

The authoritative `chainInstanceGenesisRoot` is externally computed by the PRF canonical hash implementation. During sealing the contract verifies the runtime code hashes of:

- itself; and
- the SEW authority adapter.

It also exposes an explicitly non-canonical `localProjectionHash()` for EVM-local integrity/debugging.

### `SewConfigurationExecutor.sol`

Expected-parent configuration state machine:

```text
C0 --SEW decision D1--> C1 --SEW decision D2--> C2
```

Properties:

- decision must be registered by SEW governance;
- exact parent root must match current state;
- epoch must be `current + 1`;
- decision is consumed once;
- direct or target-set chain scoping;
- anyone may relay an already-authorised transition.

### `PrfEvidenceAnchor.sol`

Permissionless immutable anchoring.

It records **existence**, not correctness. Mutable forensic/status data is deliberately excluded.

### `PrfConfigurationSnapshot.sol`

Tiny example showing how a SEW object/escrow can snapshot:

- protocol genesis;
- chain-instance genesis;
- configuration root;
- configuration epoch.

Later governance updates do not silently alter that snapshot.

## Target-set / EEZ membership

`SewConfigurationExecutor` supports:

- target mode `0`: `targetRoot == chainInstanceGenesisRoot`
- target mode `1`: `targetRoot` is a sorted-pair Keccak Merkle root

Leaf construction:

```solidity
keccak256(
    abi.encode(
        keccak256("PRF_EEZ_TARGET_INSTANCE_LEAF_V1"),
        chainInstanceGenesisRoot
    )
)
```

This target-set root is an **EVM membership commitment**, not a replacement for a PRF canonical root.

## Deployment order

Recommended first deployment:

1. Compute/freeze `protocol-genesis.v1` in PRF/Clojure.
2. Deploy SEW token, TimelockController, and modified `GovGovernor`.
3. Deploy `SewGovernanceAuthorityAdapter(protocolGenesisRoot, governor, initialAuthorityStateRoot)`.
4. Deploy `PrfChainInstanceGenesis(...)`.
5. Read:
   - genesis contract address;
   - genesis runtime code hash;
   - adapter address;
   - adapter runtime code hash.
6. Construct canonical `chain-instance-genesis.v1` off-chain.
7. Compute its PRF SHA-256 canonical root.
8. Call `sealGenesis(...)`.
9. Deploy `SewConfigurationExecutor`.
10. Deploy `PrfEvidenceAnchor`.
11. Protocol objects snapshot the configuration state they are created under.

## Important deployment invariant

The TimelockController should not grant uncontrolled proposer/canceller authority to unrelated accounts. PRF adapter mutation is intentionally routed through `GovGovernor.onlyGovernance`.

## Not yet included

- SP1 verifier integration / `realized-allocation-statement.v1` adapter.
- A verifier/program registry whose storage is mechanically proven to equal `currentConfigurationRoot`.
- ERC-7930 encoding helpers.
- ERC-7786/crosschain transport adapter.
- Production asset-holding escrow.
- Clojure canonical schema/hash implementation and cross-language vectors.

Those should be layered on this boundary rather than folded into genesis.
