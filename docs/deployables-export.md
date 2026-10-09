# Deployable Artifact Export (prf-evm)

`prf-evm` remains authoritative for PRF Solidity source, compilation, tests,
verifier tests, and production deployable bytecode. This export produces a
**deterministic, versionable deployable-artifact bundle** that the shared
deployment repository can consume **without recompiling** PRF source.

```
prf-evm source
    ↓
native prf-evm compilation (forge build)
    ↓
existing tests (forge)
    ↓
deployable artifact export   (this subsystem)
    ↓
immutable/versioned bundle   (deployables/)
    ↓
shared deployment repository
```

This is a **consumer boundary**, not an SDK and not deployment orchestration.
It states what each contract **is** (ABI + bytecode + provenance), not how a
deployment maps it to a logical role or governs it.

## Artifact source

The exporter consumes the repository's native, tested build output: Foundry
`out/` artifacts from `forge build`. It does **not** recompile Solidity with
separate compiler settings. The same artifacts validated by the forge test
suite are what get exported.

## Deployable-contract inventory and allow-list

The explicit, reviewable allow-list lives at `config/deployable-allowlist.json`.
It is the single source of truth for what is exported. Classification is
architectural metadata only.

| Artifact | Category | Notes |
|---|---|---|
| PrfChainInstanceGenesis | core | immutable chain-instance genesis root |
| PrfConfigurationSnapshot | core | configuration snapshot |
| PrfEvidenceAnchor | core | evidence anchor |
| PrfStatementAdmission | core | generic admission gateway |
| PrfVerifierRegistry | core | verifier-registry snapshots |
| GovGovernor | governance | PRF governor |
| ProductionProRataAllocatorV1 | application | pro-rata allocator |
| ProductionProRataAllocatorV2 | application | source-bound custody and successor entitlement lifecycle |
| OnchainShortfallReserveV1 | application | shortfall reserve |
| OnchainShortfallReserveV2 | application | source-bound Shortfall reserve ratification and custody |
| SourceBoundProRataControllerV1 | application | source-bound pro-rata controller |
| SourceBoundProRataEntitlementAssuranceV1 | application | successor entitlement assurance and ratification handoff |
| SourceBoundProRataEntitlementRatificationControllerV1 | application | successor atomic ratification and funding |
| PublicPackedEntitlementRepresentationV1 | application | reference logical entitlement table |
| PrfAssuredOperationConsumer | consumer | assured-operation consumer |
| PrfRealizedAllocationVerifierAdapter | verifier | SP1 adapter (realized-allocation) |
| PrfRealizedExecutionVerifierAdapter | verifier | SP1 adapter (realized-execution) |
| PrfSourceBoundStatementVerifierAdapter | verifier | SP1 adapter (source-bound) |
| PrfSourceBoundStatementVerifierAdapterV2 | verifier | frozen 192-byte source-bound V2 profile |
| PrfSourceBoundEntitlementVerifierAdapterV1 | verifier | additive 288-byte source-bound entitlement profile |
| SewConfigurationExecutor | integration | PRF-side config executor (SEW integration) |
| SewGovernanceAuthorityAdapter | integration | PRF-side authority adapter (SEW integration) |

**Excluded (non-deployable):** all `src/interfaces/*`, `src/verification/interfaces/*`
(including `ISP1Verifier`), `src/LocalShortfallSnapshot.s.sol` (forge script),
test mocks (`test/mocks/MockSP1Verifier.sol`), and any dependency-only artifacts
from `lib/`. No PRF libraries require external linking in the current source
(all bytecode is self-contained; `linkReferences` are recorded if ever present).

## Manifest schema

`deployables/manifest.json` (deterministic, sorted keys):

```jsonc
{
  "schemaVersion": 1,
  "packageName": "@protocol-robustness/prf-evm-deployables",  // configurable
"bundleVersion": "0.2.0",                                    // configurable
  "source": {
    "repository": "protocol-robustness/prf-evm",
    "commit": "<git sha | jj change id>",
    "commitSource": "git | jj | env",
    "commitOverride": false,
    "dirty": false
  },
  "build": {
    "artifactSource": "forge",
    "profile": "default",
    "compiler": { "name": "solc", "version": "0.8.33+commit.64118f21" },
    "settings": { "evmVersion": "osaka", "optimizerRuns": 200, "viaIR": true }
  },
  "artifacts": {
    "PrfStatementAdmission": {
      "contractName": "PrfStatementAdmission",
      "sourcePath": "src/core/PrfStatementAdmission.sol",
      "scopeHint": "prf",
      "category": "core",
      "artifactFile": "artifacts/PrfStatementAdmission.json",
      "abiSha256": "...",
      "creationBytecodeSha256": "...",
      "runtimeBytecodeSha256": "...",
      "constructorAbiSha256": "...",      // recoverable from embedded ABI too
      "fileSha256": "...",
      "hasLinkReferences": false,
      "hasDeployedLinkReferences": false
    },
    "PrfRealizedAllocationVerifierAdapter": {
      "contractName": "PrfRealizedAllocationVerifierAdapter",
      "sourcePath": "src/verification/adapters/PrfRealizedAllocationVerifierAdapter.sol",
      "scopeHint": "prf",
      "category": "verifier",
      "verifier": {
        "family": "sp1",
        "configMechanism": "immutable programVKey/programElfSha256/statementSchemaVersion/publicValuesSchema + external ISP1Verifier",
        "registryInterface": "IPrfVerifierRegistry",
        "admissionInterface": "IPrfStatementAdmission"
      },
      "...": "hashes as above"
    }
  },
  "bundleRoot": "<sha256 of canonical manifest without bundleRoot>"
}
```

Per-artifact file `deployables/artifacts/<Name>.json` contains `abi` (full,
from which the constructor ABI is recoverable; a dedicated
`constructorAbiSha256` is also recorded), `bytecode` (creation),
`deployedBytecode` (runtime), `linkReferences`/`deployedLinkReferences`,
`metadata` (solc metadata), scope/category, and optional verifier metadata.

**No deployment addresses are encoded.** Current Base Sepolia deployment state
is never used as artifact identity. Addresses belong to deployment instances in
the shared deployment repository/ledger.

## Verifier handling

The exporter records **implementation-level facts only**:

- artifact identity (name/source path/hashes);
- verifier `family` (e.g. `sp1`) and `configMechanism`
  (immutable `programVKey`/`programElfSha256`/`statementSchemaVersion`/
  `publicValuesSchema` + external `ISP1Verifier`);
- registry/admission interface identities (`IPrfVerifierRegistry`,
  `IPrfStatementAdmission`).

It does **not** hard-code application mappings (e.g. "SEW uses verifier X").
It does **not** assume one verifier implementation == one PRF verification
profile. Multiple applications/profiles may share one verifier implementation;
binding profile → implementation → application belongs to the shared deployment
configuration.

## Hashing

Deterministic sha256 over exact exported bytes/data:

- `abiSha256` = sha256 of canonical JSON of the ABI;
- `creationBytecodeSha256` / `runtimeBytecodeSha256` = sha256 of normalized
  (lowercase, no `0x`) bytecode string;
- `constructorAbiSha256` = sha256 of canonical JSON of the constructor ABI entry;
- `fileSha256` = sha256 of the exported artifact file bytes;
- `bundleRoot` = sha256 of canonical manifest (excluding `bundleRoot`).

No custom cryptographic machinery. The consumer can prove
`manifest artifact identity == artifact bytes supplied for deployment` by
recomputing these hashes. These conventions match the consumer side in the
deployment-composition repository.

## Commands

```bash
forge build              # native compile
forge test               # existing tests
pnpm deployables:export  # write deployables/ bundle
pnpm deployables:validate
pnpm deployables:test    # round-trip / determinism / adversarial tests
pnpm deployables:pack    # tar.gz -> dist-deployables/
```

Optional commit override: `GIT_SHA=<sha> pnpm deployables:export` (used by CI).

## Validation guarantees

Tests fail if: an allow-listed artifact is absent; bytecode is empty; manifest
hashes do not match exported contents; duplicate artifact identities exist;
an exported artifact changes without manifest/hash changes (determinism test);
source/build provenance is absent; or a non-deployable interface/mock is
accidentally exported.

## Local consumption

1. `forge build`, then `pnpm deployables:export` (and optionally
   `pnpm deployables:pack`).
2. Point the shared deployment repository at either the `deployables/`
   directory (development) or the packed tarball
   `dist-deployables/protocol-robustness-prf-evm-deployables-<version>.tgz`.
3. The consumer verifies `bundleRoot` + per-artifact hashes before deploying.

Production deployment must ultimately use an **immutable pinned
package/bundle identity**, not an arbitrary local working tree. Publication is
a separate/manual/release step and is **not** part of this task.

## Non-goals

No PRF Solidity refactor, no verifier-semantics change, no new verifier
registries, no deployment orchestration moved into `prf-evm`, no SEW knowledge
baked in, no separate compile settings for export, no generic package SDK, no
automatic publication, no deployment EDN here.
