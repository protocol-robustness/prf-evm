# Hash Boundaries

## 1. `protocol-genesis.v1`

Authoritative PRF SHA-256 canonical identity.

Expected hash-bearing fields:

```text
genesis/schema
protocol/id
canonicalisation/root
semantics/root
governance/constitution-root
governance/evolution-policy-root
configuration/contract-root
evidence/contract-root
verification/contract-root
cross-domain/authority-policy-root
```

Explicitly excluded:

```text
chainId
contract addresses
runtime bytecode
CREATE2 salt
RPC/explorer metadata
deployment transaction/block/time
current configuration
current governance membership
EEZ membership
bridge/gateway addresses
```

## 2. `chain-instance-genesis.v1`

Authoritative PRF SHA-256 canonical identity.

Expected hash-bearing fields:

```text
genesis/schema
protocol/genesis-root
execution/chain-id
settlement/chain-id

control-plane/address
control-plane/runtime-code-keccak256

governance/authority-adapter
governance/authority-adapter-code-keccak256
governance/initial-authority-state-root

configuration/initial-root
```

Excluded deployment/provenance observations:

```text
deployment tx hash
block number/hash
timestamp
deployer/sealer identity
RPC endpoint
CI job
creation provenance
confirmation count
```

## 3. Solidity `localProjectionHash`

`PrfChainInstanceGenesis.localProjectionHash()` is **not** either canonical root.

It is:

```text
keccak256(abi.encode(
  PRF_CHAIN_INSTANCE_LOCAL_PROJECTION_V1,
  protocolGenesisRoot,
  executionChainId,
  settlementChainId,
  genesisAddress,
  genesisRuntimeCodeHash,
  authorityAdapter,
  authorityAdapterRuntimeCodeHash,
  initialAuthorityStateRoot,
  initialConfigurationRoot
))
```

Its role is to provide an EVM-local, inspectable binding while PRF canonical hashing remains authoritative.

## 4. Governance transition identity

The adapter does not derive `decisionRoot`. It accepts a canonical decision root only after a successful SEW governance proposal calls `GovGovernor.authorisePrfDecision`.

The registered authorization additionally binds:

```text
target mode
target root
expected parent configuration root
new configuration root
epoch
```

This protects the on-chain executor even before the exact PRF governance-decision schema is frozen.

## 5. Evidence anchor identity

The anchor ID is an EVM-local Keccak event/storage identity. Its committed PRF roots remain opaque `bytes32` values.

Block number, timestamp, and submitter are event observations and do not change evidence identity.

## 6. Sealer boundary

`PrfChainInstanceGenesis.sealer` is ordinary deployment storage, not an immutable
embedded in runtime bytecode. It is cleared on successful sealing. Therefore the
deployer/sealer does not indirectly enter `control-plane/runtime-code-keccak256`.
