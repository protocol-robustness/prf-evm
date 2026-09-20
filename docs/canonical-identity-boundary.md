# Canonical Identity Boundary

`prf-evm` exports **implementation-level facts** (contracts, ABIs, bytecode,
verifier adapter configuration). It must NOT be the source of truth for
application/program/profile/verifier-identity semantics that already have
canonical, authoritative definitions elsewhere. This document records that
boundary so the exporter neither duplicates nor invents competing identities.

## What `prf-evm` is authoritative for

- EVM contract implementations and their deployable artifacts (this package).
- Verifier **implementations** (SP1 verifier adapters) with their immutable
  `programVKey` / `programElfSha256` / `statementSchemaVersion` /
  `publicValuesSchema` configuration.
- Registry/admission **interface identities** (`IPrfVerifierRegistry`,
  `IPrfStatementAdmission`).

## Canonical identities that remain externally authoritative

These must continue to live in `protocol-robustness-framework` (and the
Clojure `chain-configuration.v1` canonical encoding), NOT be redefined in this
package:

- **Verifier-registry root**: the `:verifier-registry/root` field of
  `chain-configuration.v1`. `PrfVerifierRegistry` explicitly mirrors this —
  it is "the exact canonical SHA-256 domain-separated commitment" using the
  `PRF_VERIFIER_REGISTRY_V1` domain tag and SHA-256 semantics matching Clojure's
  canonical encoding (see `src/core/PrfVerifierRegistry.sol`). The exporter
  references but does not redefine this identity.
- **Statement types / statement schema versions** (e.g.
  `prf/onchain-shortfall-allocation-binding.v1`,
  `realized-allocation-statement.v1`, `realized-execution-statement.v1`).
  These are committed as `statementSchemaVersion` hashes in the adapters but
  their canonical string definitions live in the framework's descriptor model.
- **Program IDs and verification-key (VK) commitments**: e.g.
  `realized-statement-sp1-program.v1` guest identities and their VK
  commitments. `programId`/`programVKey` values are authoritative in the
  framework's assurance/program descriptors.
- **Admission semantics and `:prf/...` profile identities** (e.g.
  `:prf/dispute-closure-v1`, `:prf/statement-admission`): profile → verifier
  implementation → application binding belongs to the shared deployment
  repository's verification/application model, not to this export.

## Future split (kept open)

```
protocol-robustness-framework
    → assurance / program / profile descriptors (canonical identities)

prf-evm
    → EVM verifier / admission implementations + artifacts (this package)

shared deployment repo
    → binds profile → implementation → application
```

The exporter is deliberately shaped so that a verifier adapter is identified
by its artifact + implementation metadata only, leaving the profile/application
binding to the shared layer.

## Guidance for the exporter

- Export implementation-level facts; never hard-code
  `SEW uses verifier X` or `Shortfall uses verifier Y`.
- Do not assume one verifier implementation equals one PRF verification
  profile; multiple applications/profiles may share one implementation.
- Where canonical identities currently live outside `prf-evm`, reference and
  document them rather than copying their definitions into this package.
