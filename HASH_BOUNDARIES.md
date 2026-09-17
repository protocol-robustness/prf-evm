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

## 7. Verifier registry identity & configuration binding

**Status: FROZEN.** This boundary is closed (CC1). No further changes
should be made unless a future integration uncovers an actual defect.

The verifier registry binds every on-chain proof-admission decision to a
deterministic commitment over adapter identity, SP1 program identity, and the
semantic schema of the public values the proof carries.

The binding chain is:

```text
SP1 guest semantics
    ↓
program ELF / VK
    ↓
statement schema version (hash)
    ↓
public-values schema (hash)
    ↓
verifierIdentityHash()
    ↓
canonical verifier-registry root
    ↓
chain configuration root
    ↓
PrfStatementAdmission expected configuration
```

### 7.1 `verifierIdentityHash()`

`PrfRealizedAllocationVerifierAdapter.verifierIdentityHash()` returns:

```text
keccak256(abi.encodePacked(
    address(sp1Verifier),
    programVKey,
    programElfSha256,
    statementSchemaVersion,
    publicValuesSchema
))
```

This binds the adapter's full identity: the SP1 verifier contract, the program's
verification key, the ELF SHA-256, the statement schema, and the public-values
schema.  Any change to any of these fields requires a different identity hash.

### 7.2 Canonical registry root

Each registry entry is hashed as:

```text
entryHash_i = SHA256(
    verifierId            (32 bytes)
    || adapter            (20 bytes, address)
    || programVKey        (32 bytes)
    || programElfSha256   (32 bytes)
    || programIdHash      (32 bytes, SHA-256 of UTF-8 programId)
    || statementSchema    (32 bytes, statement schema version hash)
    || publicValuesSchema (32 bytes, public-values schema hash)
    || active             (32 bytes, 0x00…01 or 0x00…00)
)
```

Entries are sorted by `verifierId` before hashing. The registry root is:

```text
registryRoot = SHA256(
    "PRF_VERIFIER_REGISTRY_V1" (25 bytes)
    || uint256(entry_count)     (32 bytes)
    || sorted(entryHash_0, …, entryHash_{n-1})
)
```

The `publicValuesSchema` field is included in this root so that a change to the
public-values schema requires a new registry root.

### 7.3 Configuration binding

`PrfStatementAdmission` only accepts the current `verifierRegistryRoot` that the
`SewConfigurationExecutor` binds from the sealed `chain-instance-genesis.v1`
configuration root.  A proof whose public-values schema does not match the schema
pinned in the active registry entry will not be admitted, because:

1. The registry root (and thus the configuration root) changes when the schema
   changes — a forged/stale registry root is rejected by the sealed configuration.
2. The adapter independently validates `publicValuesSchema` and reverts
   `PublicValuesSchemaMismatch` if the runtime public values do not match the
   pinned schema.

### 7.4 Versioned semantics

The `evm-bytes32-v1` public-values schema is the current profile.  When broader
realized-allocation semantics (caps, redistribution, haircuts, alternative
rounding) are eventually introduced, a **new** profile/schema identity — not an
in-place extension of `evm-bytes32-v1` — should be used.  Two generations that
both expose `bytes32 statementRoot` may still carry different semantic profile
identities and therefore must not share the same `publicValuesSchema`.

## 8. PRF EVM Assurance Admission/Consumption V1

The reusable boundary is:

```text
canonical PRF root
    → proof verification
    → admission-time authority snapshot
    → EVM-local admission receipt
    → application root precommitment
    → application acceptance policy
    → EVM-local consumption identity
    → one terminal local transition
```

Verification authority establishes the assurance fact; application authority
determines whether that assurance fact authorizes its local transition. The
admission receipt therefore does not imply that the proof established an
application address, operation ID, recipient, or future state transition unless
those values are part of the canonical proved result.

## 8.1 Admission receipt and application-consumption identities

`PrfStatementAdmission` derives `publicValuesDigest = sha256(publicValues)` after
verifying the proof. It persists an `AdmissionReceipt`; this records admission-time
facts rather than changing the SP1 public-values schema.

The EVM-local receipt ID is:

```text
authoritySnapshot = keccak256(abi.encode(
  protocolGenesisRoot,
  chainInstanceGenesisRoot,
  expectedConfigurationRoot,
  expectedConfigurationEpoch,
  verifierRegistryRoot
))

verifierSnapshot = keccak256(abi.encode(
  verifierId,
  verifierAdapter,
  programVKey,
  programElfSha256,
  statementSchemaVersionHash,
  publicValuesSchema
))

admissionReceiptId = keccak256(abi.encode(
  keccak256("PRF_STATEMENT_ADMISSION_V1"),
  admissionContract,
  chainId,
  authoritySnapshot,
  verifierSnapshot,
  statementRoot,
  publicValuesDigest
))
```

This is **not** a proof-byte identity and does not claim that SP1 proved any
consumer or application operation. It identifies the durable EVM admission fact.

`PrfAssuredOperationConsumer` separately derives an operation-scoped consumption
identity:

```text
consumptionId = keccak256(abi.encode(
  keccak256("PRF_ASSURED_OPERATION_CONSUMPTION_V1"),
  consumer,
  chainId,
  operationId,
  admissionReceiptId,
  expectedStatementRoot,
  requiredConfigurationRoot,
  requiredConfigurationEpoch
))
```

The consumer writes the consumption flag and terminal `Applied` operation state
before emitting its event and performs no external calls. It accepts an immutable
receipt from its configured admission contract only when the receipt's statement
root, configuration root, and configuration epoch equal the operation's immutable
precommitment. Admission facts are historical: a receipt remains a record of what
was valid at admission time after later governed configuration changes. Consumer
acceptance is separate: an operation accepts only the snapshot it explicitly fixed,
so a later-snapshot receipt cannot satisfy an earlier operation merely because it
commits the same statement root.

The frozen V1 consumer policy binds configuration root and epoch, not a particular
`verifierId`. If a configuration permits multiple verifier identities to admit the
same statement, any receipt matching the operation's statement root and snapshot
is accepted. This intentionally means **trust this configuration**, rather than
**trust only verifier X**. Verifier-specific acceptance, exact receipt binding,
expiry, cancellation, custody, recovery, and emergency policy remain concrete
consumer concerns.

### 7.6 Schema identity is semantic, not merely encoding

A public-values schema identifier **MUST** change whenever the interpretation,
ordering, domain, number, or semantic meaning of the committed public values
changes — even if their ABI encoding and total byte length remain unchanged.

For example, extending the `bytes32` payload from:

```text
bytes32  statementRoot
```

to:

```text
bytes32  statementRoot
bytes32  executionEpoch
```

does **not** qualify as a minor encoding change.  The new layout carries
different semantics (an additional domain component).  It requires a new
`publicValuesSchema` and therefore a new registry root, configuration root,
and admission binding.

The adversarial test `test_Adversarial_SameWidthSchemaReplay_RejectedByConfigBinding`
demonstrates this: two adapters with identical SP1 verifier, VKey, ELF, and
statement schema but different `publicValuesSchema` strings
(`evm-bytes32-v1` vs `evm-bytes32-v2`), both accepting 32-byte public values,
produce different `verifierIdentityHash()` values and different canonical
registry roots.  A proof valid under one schema cannot be replayed through
an admission bound to the other schema's configuration.

### 7.7 Identity levels

Three distinct identities participate in this system.  They must not be
treated as interchangeable:

1. **Verifier implementation identity** — `PrfRealizedAllocationVerifierAdapter.verifierIdentityHash()`.
   Encodes: SP1 verifier address, program VKey, ELF SHA-256, statement schema hash,
   and public-values schema hash.  Used for runtime adapter self-check and external
   identity binding.

2. **Registry entry identity** — the per-entry hash inside `computeCanonicalRoot`.
   Encodes: verifierId, adapter address, programVKey, ELF SHA-256, programId hash,
   statement schema hash, public-values schema hash, active flag.
   The registry root is a sorted, SHA-256 Merkle over entry identities.

3. **Registry canonical root** — `registry.canonicalRoot()`.
   Deterministic off-chain computable SHA-256 aggregate.  Bound into the chain
   configuration root and ultimately into `PrfStatementAdmission.expectedConfigurationRoot`.
