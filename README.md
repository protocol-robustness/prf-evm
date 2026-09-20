# PRF / SEW Genesis Solidity Package

Solidity implementation of the SEW/PRF genesis, governance-authorisation, configuration-transition, verifier-registry, and proof-admission boundaries.

**Status: experimental / pre-production.** Core semantic boundaries are conformance-tested via Foundry (genesis sealing, configuration-authorisation, verifier-registry canonical roots, statement-admission rejection matrix). The package should **not** be treated as audited production infrastructure.

## Security and status

Before considering any real use, read this list:

- **Not audited.** No formal security audit has been performed.
- **Not production asset-holding infrastructure.** Nothing here is safe to use as an asset-holding escrow.
- **Governance authority is security-critical.** `GovGovernor` + `TimelockController` (via `SewGovernanceAuthorityAdapter`) are the only route that can authorise configuration transitions, register verifiers, or advance the authority-state root. Compromise of the SEW governance path compromises the chain instance.
- **PRF canonical roots are computed off-chain.** This package does **not** recreate `protocol-genesis.v1` / `chain-instance-genesis.v1` / the verifier-registry root with EVM hashing. Canonical roots enter Solidity as externally computed `bytes32` values and are only re-checked for equality, never rebuilt here. See `HASH_BOUNDARIES.md`.
- **There is no parallel PRF administrator.** `SEW Governor + Timelock` remain the sole authority; PRF does not get its own admin contract.
- **Evidence anchoring records existence, not correctness.** `PrfEvidenceAnchor` only proves that a commitment existed at a given block; it does not assert that any proof is valid, canonical, signed, or currently usable.
- **The `test` Foundry profile does not define production compilation settings.** Production builds must use the `default` profile (optimizer on, `via-ir`).
- **The test-time mock is not a real verifier.** `MockSP1Verifier` is a deterministic dev/test double and must never be used on a live chain or represented as a real proof system.

## Dependencies and toolchain provenance

Versions are pinned via `foundry.lock` and `foundry.toml`:

| Component | Version | Source |
|---|---|---|
| Solidity compiler | 0.8.33 | `foundry.toml` `solc_version` |
| Foundry | 1.5.1-stable (`b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2`) | toolchain |
| OpenZeppelin Contracts | v5.7.0 (`cab19933c33c2ad1d4c7a84864a3601dddfd16f3`) | `foundry.lock` git dep |
| sp1-contracts | v6.1.1, `main` branch (`d3629729c3216eb51bd4859d027a8eb729399fa4`) | `foundry.lock` git dep |
| forge-std | standard Foundry test library (submodule) | `lib/forge-std` |

`GovGovernor.sol` is derived from the SEW project's supplied `SewGovernor` base, itself built on OpenZeppelin Contracts v5.7.0 (`Governor`, `GovernorSettings`, `GovernorCountingSimple`, `GovernorVotes`, `GovernorTimelockControl`, `TimelockController`). The delta from the supplied SEW base is documented in `MIGRATION_NOTES.md`. Treat any Governor-derived contract as security-sensitive.

The `PrfStatementAdmissionRealProof` conformance tests exercise the real SP1 Groth16 Solidity verifier from `sp1-contracts` with a real (non-mock) SP1 CPU-prover proof (see `fixtures/realized-statement-proof-fixture.json`).

## Architecture

```
PRF canonical roots (SHA-256, off-chain)
        │
        ▼
SEW Governor + Timelock
        │
        ▼
SewGovernanceAuthorityAdapter        (configuration-authorisation boundary)
        │  registers decisionRoot:
        │   target, parent/new config root,
        │   parent/new verifier-registry root, epoch
        ▼
PrfChainInstanceGenesis  ──►  sealGenesis()
        │
        ▼
SewConfigurationExecutor   ──►  currentConfigurationRoot  (C0 → C1 → …)
                                  currentVerifierRegistryRoot  (R)
                                  currentEpoch
        │
        ▼
PrfVerifierRegistry                 (sealed snapshot of R; governance-managed)
        │  publicValuesSchema committed in root
        ▼
┌──────────────────────────────────────────────┐
│  PrfRealizedAllocationVerifierAdapter         │
│  • pins SP1 program VK + ELF SHA-256         │
│  • pins statement schema + public-values     │
│  • delegates proof check to ISP1Verifier       │
│  • validates public-values length at runtime  │
└──────────────────────────────────────────────┘
        │
        ▼
PrfStatementAdmission  ──►  durable admission receipt (fail-closed)
        │
        ├──► PrfAssuredOperationConsumer
        │      precommitted operation + matching receipt
        │             ↓
        │      one-shot Pending → Applied transition
        │
        ▼
PrfEvidenceAnchor       (existence only, NOT correctness)
```

The absence of any contract between `SEW Governor + Timelock` and `SewGovernanceAuthorityAdapter` that could carry independent PRF administrative authority is intentional: governance flows only through SEW.

## Two-genesis model

- **`protocol-genesis.v1`** — chain-neutral constitutional PRF/SEW identity, computed canonically off-chain.
- **`chain-instance-genesis.v1`** — one EVM execution instance, bound to `chainId`, settlement domain, immutable control-plane deployment, SEW authority adapter, initial authority-state root, and initial configuration root.

This package deliberately does **not** invent an EVM replacement for PRF canonical hashing. PRF SHA-256 roots enter Solidity as `bytes32`.

## Contracts

### Genesis and governance bootstrap

| Contract | Role |
|---|---|
| `GovGovernor.sol` | Modified SEW OpenZeppelin Governor: immutable `prfProtocolGenesisRoot`, `onlyGovernance` PRF compatibility methods (`authorisePrfDecision`, `revokePrfDecision`, `updatePrfAuthorityStateRoot`), parameter mutations under `onlyGovernance`. SEW Governor + Timelock remain the authority mechanism; PRF does not get a parallel administrator. See `MIGRATION_NOTES.md`. |
| `SewGovernanceAuthorityAdapter.sol` | **Configuration-authorisation boundary**, controlled only by `GovGovernor`. Registers canonical decision roots with target chain-instance, exact parent/next configuration roots, exact parent/new verifier-registry roots, and exact epoch. Implements ERC-1271. |
| `PrfChainInstanceGenesis.sol` | Sealed anchor for one PRF/SEW EVM execution instance. Verifies runtime code hashes of itself and the authority adapter at seal time. Exposes `localProjectionHash()` for EVM-local integrity/debugging. |
| `PrfConfigurationSnapshot.sol` | Example of the SEW prospective-governance pattern: a protocol object snapshots genesis, configuration root, and epoch at creation. Later governance updates do not silently alter that snapshot. |

### Proof-admission layer

| Contract | Role |
|---|---|
| `PrfRealizedAllocationVerifierAdapter.sol` | Binds the `realized-allocation-statement.v1` SP1 program to the EVM verification gateway. Pins the program verification key, ELF SHA-256, statement-schema version, and `publicValuesSchema`, and delegates SP1 proof verification to an `ISP1Verifier`. Validates public-values length against the pinned schema at runtime. `verifierIdentityHash()` commits the full verifier identity. |
| `PrfVerifierRegistry.sol` | Versioned, immutable verifier-registry snapshots keyed by canonical registry root `R`. Maintains entries (adapter, program VK, ELF SHA-256, programId, statement-schema hash, `publicValuesSchema`, active flag), sorted by `verifierId`. `sealRegistry(R)` verifies the committed root matches the canonical SHA-256 root computed from the actual entries. Only the configured governor may register/activate/deactivate verifiers and seal. |
| `PrfStatementAdmission.sol` | Admission gateway for `realized-allocation-statement.v1` proofs. It derives `sha256(publicValues)` internally, binds the chain-instance genesis root, current configuration root/epoch, and current sealed verifier-registry root, then persists a durable admission receipt containing the exact successful verifier/configuration facts. Fail-closed: any verification failure reverts. |
| `PrfAssuredOperationConsumer.sol` | Minimal non-custodial reference consumer. An authority precommits a pending operation to both a statement root and an immutable configuration-root/epoch acceptance snapshot; `applyOperation` requires a matching durable receipt from one fixed admission contract and atomically records one operation-scoped consumption before moving the operation to `Applied`. It has no generic callback or alternate apply route. |
| `PrfEvidenceAnchor.sol` | Permissionless immutable anchoring of PRF evidence commitments. Records **existence**, not correctness. Mutable forensic/status projections are deliberately excluded. |

### Verifier interfaces and SP1 bindings

| Contract | Role |
|---|---|
| `ISP1Verifier.sol` | SP1 verifier interface mirroring `sp1-contracts` (`verifyProof`, `VERIFIER_HASH`). |
| `MockSP1Verifier.sol` | Deterministic mock SP1 verifier for tests/dev only. Accepts only when `keccak256(proofBytes || programVKey || publicValues)` equals the deployment commitment. **Never use in production.** |
| `interfaces/IPrfProofVerifier.sol` | Prover-neutral interface: `verifyStatementProof(proof, programVKey, publicValues) → bytes32` statement root. The proof system is selected by the implementing adapter. |
| `interfaces/IPrfVerifierRegistry.sol` | `PrfVerifierRegistry` interface: `VerifierEntry` struct, registration, activation/deactivation, sealing, `canonicalRoot`, `computeCanonicalRoot`. |
| `interfaces/IPrfStatementAdmission.sol` | `PrfStatementAdmission` interface. |
| `interfaces/IPrfConfigurationExecutor.sol` | Configuration-transition and verifier-registry-root query interface (`currentConfigurationRoot`, `currentVerifierRegistryRoot`, `currentEpoch`). |
| `interfaces/IPrfChainInstanceGenesis.sol` | Sealed chain-instance identity interface. |
| `interfaces/IPrfEvidenceAnchor.sol` | Evidence-commitment anchoring and `computeAnchorId` interface. |
| `interfaces/ISewGovernanceAuthority.sol` | Read-only (`DecisionAuthorization`, ERC-1271 `isValidSignature`) and `ISewGovernanceAuthorityAdmin` mutation surfaces for the SEW → PRF bridge. |

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

## Deployment

Deployment is two layers: the genesis/governance bootstrap establishes constitutional identity, and the proof-admission layer is layered **on top of** (not folded into) that authority.

### Genesis and governance bootstrap

1. Compute/freeze `protocol-genesis.v1` (PRF/Clojure, off-chain).
2. Deploy SEW token, `TimelockController`, and `GovGovernor(prfProtocolGenesisRoot)`.
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
9. Deploy `SewConfigurationExecutor` — constructed against the sealed genesis and authority adapter with initial configuration root `C0` and initial verifier-registry root `R0`.

> **Implementation note:** `SewConfigurationExecutor` stores an immutable `PrfVerifierRegistry` reference supplied at construction, so the registry (next layer) must be deployed and sealed to `R0` first — or constructed at a deterministic address the executor can reference. The executor re-checks `verifierRegistry.canonicalRoot(R) == R` on every configuration transition, so the live configuration cannot diverge from a sealed registry.

### Proof-admission layer

1. Deploy the verifier implementation — the canonical SP1 Groth16 verifier from `sp1-contracts` (or `MockSP1Verifier` for tests only).
2. Deploy `PrfRealizedAllocationVerifierAdapter(sp1Verifier, programVKey, programElfSha256, "realized-allocation-statement.v1", "evm-bytes32-v1")`.
3. Deploy `PrfVerifierRegistry(governor)`.
4. Governor registers the adapter as a verifier entry; `R0` is the off-chain-computed canonical root (`PrfVerifierRegistry.computeCanonicalRoot`, a `pure` function).
5. Seal the registry via `sealRegistry(R0)` — `R0` is now committed to configuration identity. **This is the configuration-binding step:** the sealed registry root is the `SewConfigurationExecutor.currentVerifierRegistryRoot`, and `PrfStatementAdmission` is bound to the same `currentConfigurationRoot`/`currentEpoch`/registry. Later registry changes require a governance transition that advances the configuration root in lockstep (`C → C'`, `R → R'` under one decision).
6. Deploy `PrfStatementAdmission(genesis, configurationExecutor, verifierRegistry, expectedConfigurationRoot, expectedConfigurationEpoch)`.
7. Deploy any application consumer with the admission contract and its operation authority. For the reference path, deploy `PrfAssuredOperationConsumer(admission, operationAuthority)`, then precommit every operation's exact expected statement root **and** its required configuration root/epoch acceptance snapshot before application.
8. (Optional) Deploy `PrfEvidenceAnchor` — records existence only.

This layered design reinforces the architecture's strongest property: **proof admission is layered on genesis/configuration authority, rather than being part of genesis identity itself.** `PrfStatementAdmission` cannot be constructed until the genesis contract is sealed and the configuration executor is bound; the verifier registry and admission are governed, separable surfaces.

### PRF EVM Assurance Admission/Consumption V1

The reusable enforcement pattern is:

```text
1. portable semantic result exists as canonical PRF root
2. proof verifier establishes that root
3. admission snapshots verification authority/configuration
4. admission issues an EVM-local receipt identity
5. application independently precommits the root it requires
6. application checks the receipt against that precommitment
7. application applies its own acceptance policy
8. consumption receives a separate EVM-local identity
9. operation moves terminally exactly once
```

The authority boundary is intentional:

> Verification authority establishes the assurance fact; application authority determines whether that assurance fact authorizes its local transition.

Admission does not prove an application address, operation ID, recipient, or future state transition unless those values are part of the canonical proved result. The application must bind its own operation to the admitted root and enforce its own local policy.

### Durable admission and reference enforcement

`admitStatement(verifierId, statementRoot, proof, publicValues)` derives `sha256(publicValues)` inside the admission contract; callers cannot attach a competing audit digest. Successful admission persists an `AdmissionReceipt` keyed by an EVM-local `admissionReceiptId`. The receipt snapshots the genesis roots, configured root/epoch, registry root, verifier ID/adapter, program VK/ELF, statement/public-values schema identities, statement root, and derived public-values digest.

`admissionReceiptId` is **not** a proof-bytes identity and is not a claim that SP1 proved a consumer or operation. It is an EVM-local identity for the successful admission snapshot. It is derived from the admission domain, admission contract and chain, typed authority snapshot, typed verifier snapshot, statement root, and public-values digest.

Admission facts are frozen at admission time; consumer acceptance is determined independently by each operation's immutable policy. The reference policy requires an exact statement root, configuration root, and configuration epoch. Thus a receipt admitted under the required snapshot remains usable after later live configuration changes, while a receipt first admitted under a later snapshot cannot satisfy an earlier operation even for the same statement root. Each operation is immutable after creation. Its consumption identity binds the consumer address/chain, operation ID, admission receipt ID, expected statement root, required configuration root, and required configuration epoch. Consumption is one-shot **per operation**; the same receipt may be used for another independently precommitted operation only when it satisfies that operation's complete acceptance policy. This is application policy, not a new SP1 assertion.

### V1 freeze boundary

The `PRF EVM Assurance Admission/Consumption V1` reference pattern is frozen at:

```text
PRF canonical statement root
    → SP1 proof verification
    → durable admission receipt
    → immutable admission facts
    → consumer-owned immutable acceptance policy
    → operation-scoped one-shot consumption
    → enforced Pending → Applied transition
```

The reference operation binds the accepted `configurationRoot` and
`configurationEpoch`, but not a particular `verifierId`. If one configuration
permits multiple valid verifier identities capable of admitting the same
statement, the reference consumer accepts any receipt matching the operation's
statement root and configuration snapshot. This is the deliberate V1 policy:
**trust this configuration**, not **trust only verifier X**.

A concrete production consumer may later bind a verifier ID, verifier snapshot,
exact receipt ID, expiry, cancellation, custody, recovery, or emergency policy.
Those are consumer-specific extensions outside this frozen reference surface.

## Important deployment invariant

The `TimelockController` should not grant uncontrolled proposer/canceller authority to unrelated accounts. PRF adapter mutation is intentionally routed through `GovGovernor.onlyGovernance`.

## Configuration/schema binding — V1 compatibility boundary

The V1 configuration/schema binding is frozen: `publicValuesSchema` forms part of verifier-registry identity and therefore configuration identity. The verifier registry commits `publicValuesSchema` into the canonical registry root, closing the binding (CC1). See `HASH_BOUNDARIES.md` §7 for the full binding chain and identity levels.

Two independent protections now exist:

1. **Runtime decoding compatibility** — `PrfRealizedAllocationVerifierAdapter` validates the public-values length against the pinned schema at runtime (reverts `InvalidPublicValuesLength`).
2. **Configuration-bound semantic identity** — the registry root includes the schema hash, so a schema change requires a new configuration authorisation.

The adversarial test `test_Adversarial_SameWidthSchemaReplay_RejectedByConfigBinding` demonstrates that protection 2 is not merely a consequence of byte-length validation: two adapters with identical SP1 verifier, VKey, ELF, and statement schema but different `publicValuesSchema` strings (`evm-bytes32-v1` vs `evm-bytes32-v2`), both accepting 32-byte public values, produce different `verifierIdentityHash()` values and different canonical registry roots.

**Versioning rule:** Any intentional semantic change to this boundary requires a new version/domain rather than silently altering V1. Defect corrections remain possible. What is frozen is the *meaning*, not necessarily every line of Solidity. A `publicValuesSchema` identifier must change whenever the interpretation, ordering, domain, number, or semantic meaning of the committed public values changes — even if the ABI encoding and total byte length remain unchanged.

## Build profiles

`foundry.toml` defines two profiles:

| Profile   | Optimizer | `via-ir` | Use                     |
|-----------|-----------|----------|-------------------------|
| `default` | enabled   | yes      | production bytecode     |
| `test`    | disabled  | yes      | test compilation only   |

The `test` profile exists because the IR optimizer's 16-slot stack-depth limit is exceeded by the conformance test's `setUp` after the `publicValuesSchema` field was added to the canonical registry-root computation. The registry source itself compiles cleanly under the `default` profile; the profile split is a test-compilation workaround only.

```bash
# Production build (optimizer on)
forge build --skip test

# Tests (optimizer off, test profile)
FOUNDRY_PROFILE=test forge test
```

## Conformance and tests

```bash
# All tests
FOUNDRY_PROFILE=test forge test

# By suite
FOUNDRY_PROFILE=test forge test --match-contract PrfGenesisTest
FOUNDRY_PROFILE=test forge test --match-contract PrfConfigurationAuthorizationConformanceTest
FOUNDRY_PROFILE=test forge test --match-contract PrfStatementAdmissionTest
FOUNDRY_PROFILE=test forge test --match-contract PrfStatementAdmissionRealProofTest
FOUNDRY_PROFILE=test forge test --match-contract PrfAssuredOperationConsumerTest
```

The 64-test suite (all passing) covers genesis sealing, configuration-authorisation, verifier-registry canonical-root sealing and immutability, and the statement-admission rejection matrix. Verified rejection categories include: wrong configuration root, wrong epoch, stale parent, consumed decision, unsealed/forged registry root, wrong verifier identity, correct-proof-with-wrong-schema identity, tampered/malformed public values, statement-root mismatch, tampered proof bytes, inactive verifier, and mock-vs-real proof incompatibility. See `fixtures/realized-statement-proof-fixture.json` for the real-prover proof fixture.

## Deployable artifact export

`prf-evm` stays authoritative for PRF source/compile/tests/bytecode. A
deterministic deployable-artifact bundle (for the shared deployment repo to
consume **without recompiling** PRF source) is produced by:

```bash
forge build               # native compile
npm run deployables:export
npm run deployables:validate
npm run deployables:test
npm run deployables:pack
```

See [docs/deployables-export.md](docs/deployables-export.md) (design, manifest
schema, local consumption) and [docs/canonical-identity-boundary.md](docs/canonical-identity-boundary.md)
(which canonical verifier/program/profile identities remain externally
authoritative).

## What this package does not provide

### Provided by other PRF components

These canonical primitives intentionally live in the broader PRF ecosystem, not in this Solidity package:

- canonical Clojure schemas and SHA-256 root computation (this package only re-checks externally computed roots for equality);
- clean-room / cross-language conformance vectors;
- the SP1 guest/prover implementation (`realized-statement-sp1-program.v1`).

### Future Solidity / package work

Not yet implemented and layered on the boundary above rather than folded into genesis:

- ERC-7930 encoding helpers;
- ERC-7786 / cross-chain transport adapter;
- production asset-holding escrow.

## Release and publication lifecycle

Publishing the repository is a separate decision from publishing a consumable package, and the maturity gates should reflect that.

| Stage                            | Recommendation                                  |
|----------------------------------|-------------------------------------------------|
| Public repository                | Soon / now, after the README consistency pass   |
| v0.x GitHub prerelease            | Now or very soon                                |
| Package for dependency consumption | After the contract/deployment surface stabilises |
| Testnet release                   | After full deployed end-to-end conformance        |
| Stable production release         | After testnet experience + security review/audit  |

**Public repository: now.** Do not wait for testnet to make the repository public if the purpose is review, research, interoperability, or attracting scrutiny. The architecture is already coherent enough to be useful publicly. Before doing so, run a small publication gate:

- Fix README implementation-status contradictions. (Done.)
- Add `LICENSE`. (Done — Apache-2.0, matching the SPDX header on every source file.)
- Add `SECURITY.md`. (Done.)
- Pin Solidity/Foundry/OpenZeppelin/SP1 dependency versions. (Done — see `foundry.toml`/`foundry.lock`.)
- Ensure documented build/test commands run from a fresh clone. (Verified: `forge build --skip test` and `FOUNDRY_PROFILE=test forge test`.)
- Clearly mark the package experimental / pre-production. (Done.)
- Have CI run the documented commands.

A credible public alpha can be tagged `v0.1.0-alpha.1` rather than waiting for an artificially vague notion of "stability".

**Package registry: slightly later.** Once in a package ecosystem, paths, contract names, constructor signatures, events, and interfaces become compatibility commitments. Hold off until contract names are unlikely to move, constructor shapes are settled, interfaces/events/errors are versioned or stable, the deployment architecture is settled (verifier-registry/admission/configuration binding complete), and dependency versions are pinned and downstream consumption has a reason to exist. It can still be `0.x` — there is no need to pretend production maturity.

**The testnet milestone** should be the release-candidate milestone, not the first publication milestone. "Ready for testnet" means the full chain has happened on an actual network:

```
canonical protocol genesis
        ↓  Governor + Timelock
        ↓  authority adapter
        ↓  canonical chain-instance genesis
        ↓  seal
        ↓  C0
        ↓  real governance proposal
        ↓  authorised C0 → C1
        ↓  configured verifier identity
        ↓  real proof
        ↓  real verifier
        ↓  PrfStatementAdmission
        ↓  on-chain admission event/result
```

…with replay/rejection demonstrations for: wrong chain instance; wrong configuration; stale parent; wrong epoch; unauthorised transition; consumed decision; wrong verifier identity; correct proof with wrong schema identity; malformed public values; statement-root mismatch.

At that point, make a named testnet release (`v0.2.0-rc.1` or `v0.2.0-testnet.1` is reasonable) carrying: network + chain ID; verified contract addresses; deployment transaction hash(es); `protocolGenesisRoot`; `chainInstanceGenesisRoot`; initial and current configuration roots; verifier-registry root; compiler settings; deployment manifest; the Git commit/release tag used; and the exact reproduction procedure.

**Stable / production** should not be tied to a calendar date. The empirical gates are: public alpha → external review → interfaces settle → testnet → real governance/config/proof lifecycle → adversarial testing → security audit/review → fixes + re-audit where necessary → production candidate. `1.0.0` should mean the V1 public interfaces and semantic commitments are safe to treat without breaking changes **and** the code has received the level of security review appropriate to its intended use. For something involving Governor/Timelock authority and potentially asset-bearing protocols, the stability of the semantic architecture is a separate claim from the stability of the Solidity package.
