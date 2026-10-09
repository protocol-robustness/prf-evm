# Pro-Rata V1 / Shortfall Reservation V2 Boundary

Status: architecture record for Deployment Ledger integration.

This document defines the canonical separation between the completed V1
production allocator path and the separate V2 optimistic Shortfall reserve
ratification path. V2 does not replace, upgrade, or wrap V1.

## Normative assurance layers

The following boundaries are independently testable and must not be collapsed
into an undifferentiated "pro-rata Shortfall" mechanism:

```text
pro-rata allocation
  = determines who gets what

Shortfall V2
  = establishes authoritative available capacity and moves that exact capacity

proof/admission
  = binds allocation and source-state statements to their configured program

allocator/claims
  = makes the resulting allocation executable
```

The canonical pro-rata primitive is independent of Shortfall. A Shortfall
application consumes an allocation binding; it does not define the allocation
algorithm. Likewise, a funded V2 allocator is an allocation-bound custody
endpoint, not an implementation of pro-rata arithmetic or claims.

## Executive distinction

### V1: production allocation custody and claims

V1 is the complete production pro-rata allocation lifecycle:

```text
create
  -> fund
  -> activate from a realized-execution proof
  -> claim
  -> close
```

`ProductionProRataAllocatorV1` owns allocator custody, activation, Merkle claim
authentication, claim accounting, and cancellation/refund. Its proof boundary is
the realized-execution statement and its fixed 384-byte execution public-values
format. Its operation is executable allocation custody, not Shortfall reserve
ratification.

The V1 path is independently deployable and usable without any V2 component.

### V2: optimistic Shortfall reserve ratification

V2 is a separate source-bound reserve path:

```text
PreparedOperationV2
  -> Prepared source assurance (P, C)
  -> ControllerV2 consumes exact assurance
  -> ReserveV2 recomputes C'
  -> require C' == C
  -> authoritative observation
  -> ephemeral reservation
  -> allocator create/fund
  -> Funded
```

V2 moves expensive source assurance before capital exclusivity. It owns the
Shortfall reserve's live economic-state commitment, availability revision,
ratification-time observation, and atomic reserve-to-allocator funding boundary.
The legacy V2 custody route still stops at exact funded custody and does not
inherit V1's activation, claims, or Merkle lifecycle. The additive
source-bound-entitlement successor route has its own explicit transition:

```text
Funded -> Activated -> Claims -> Closed
       -> CancelledRefunded (pre-activation only)
```

Activation binds the admitted logical entitlement table root, count, total, and
claim root. Withdrawal is one atomic allocator operation: the table opening is
authoritative in Requested and Required; Required additionally checks the
allocation-claim Merkle path. The live Requested/Required mode is read from the
Sew configuration executor, and a caller may require a stricter minimum. V1
claim ABI, leaf domain, and payout semantics remain unchanged.

## Pro-rata primitive versus Shortfall demonstration

The canonical `pro-rata-allocation` primitive is the domain-neutral allocation
engine and its canonical request/result/evidence artifacts. In the framework,
the liquidity-shortfall demonstration explicitly calls
`resolver-sim.pro-rata.allocation/allocate` over a fixed request and tests the
result (for example, available `70` against requests `50/30/20`, producing
`35/21/14`). That demonstration is evidence that the primitive is used by a
Shortfall scenario; it is not a new Shortfall-specific allocation algorithm.

The EVM Shortfall contracts have a different responsibility. `OnchainShortfallReserveV2`,
`SourceBoundProRataRatificationControllerV2`, and `ProductionProRataAllocatorV2`
do not calculate proportional shares. They authenticate/bind allocation and
realized-statement roots, compare the live reserve commitment, and move exact
funded custody. The allocation result must already have been computed by the
canonical allocation layer and represented by the proof-bound roots.

Accordingly, the precise claim is:

```text
canonical pro-rata-allocation primitive
  -> computes and commits the allocation result
Shortfall V2 demonstration
  -> authenticates that result's roots and funds its exact capacity
```

The Shortfall demo demonstrates **application of a canonical pro-rata
allocation under liquidity shortfall**, not standalone proof that the EVM
reserve or allocator implements the allocation arithmetic. A primitive-only
conformance claim requires the framework allocation tests, canonical result and
evidence artifacts, integer/conservation/cap/rounding checks, and deterministic
replay. A Shortfall EVM conformance claim requires root binding, admission,
reserve ratification, custody, and lifecycle checks.

### Required join contract (not yet frozen)

`allocationBindingRoot` must not remain opaque glue between repositories. The
next primitive-level design artifact must define an `AllocationBindingV1`-style
canonical object with, at minimum:

```text
mechanism ID and version
request root
policy root
allocation-result root
application-context root
```

The first four fields establish reusable primitive semantics. The
`application-context root` is supplied by the consumer (for example, Shortfall,
slashing, insurance, redemption, or withdrawal). A proof implementation then
binds that allocation object to its realized statement and source-state
assurance. This join contract is intentionally not defined by the V1 or V2
reserve contracts in this repository.

## Relationship model

The supported model is **parallel protocol/application families** with a
shared PRF admission vocabulary and shared token/allocator concepts where
useful. They are not:

- two mutable versions selected by a `latest` flag;
- a V2 wrapper around V1;
- a V1 migration or replacement;
- a single profile with interchangeable proof schemas;
- a generic allocator version hierarchy in which V2 inherits V1 lifecycle
  semantics.

A deployment may contain V1, V2, or both. Co-deployment alone is a bundle,
not a new canonical protocol identity. A semantic composition must explicitly
describe the primitive-to-proof-to-application join. Neither form may collapse
the child identities or imply that activating V2 changes V1 behavior.

## Canonical identity boundaries

### V1 identity

The V1 logical identity is the production realized-allocation execution
application/profile. Its identity is determined by the complete binding of:

- V1 allocator contract family: `ProductionProRataAllocatorV1`;
- V1 operation identity;
- token, allocator address, chain ID, and available amount operation binding;
- realized-execution statement root;
- expected configuration root and epoch;
- execution verifier adapter, verifier ID, VKey, ELF/provenance hash;
- V1 execution statement schema and exact 384-byte public-values schema;
- admission receipt and public-values digest;
- claim root/allocation projection when activation occurs.

V1 custody authority is the allocator's operation authority. V1 reserve
integration, where present, is the V1 `OnchainShortfallReserveV1` lifecycle and
its lock-first snapshot/deadline semantics. V1 does not use
`reserveStateCommitment` or V2 `availabilityRevision` as its proof identity.

### V2 identity

The V2 logical identity is the optimistic Shortfall source-bound ratification
application/profile. Its identity is determined by the complete binding of:

- V2 prepared-operation identity `PreparedOperationV2` and
  `preparedOperationRoot`;
- V2 source verifier/program identity, including VKey, ELF/provenance hash,
  statement schema, and 192-byte public-values schema;
- `EconomicReserveStateV2` and `reserveStateCommitment`, including
  `availabilityRevision`;
- operation ID;
- allocation binding root and realized statement root;
- reserve, token, allocator, chain, configuration, epoch, policy, and residual
  recipient fields committed by the prepared operation;
- authenticated admission receipt and public-values digest;
- authoritative observation root produced only at ratification time;
- V2 assurance, ratification controller, Shortfall reserve, and V2 allocator
  contract identities.

The V2 proof commits to `preparedOperationRoot` and `reserveStateCommitment`.
It does not commit to ratification-time snapshot metadata. The authoritative
observation binds the proved predecessor commitment to its observation ID and
block. `availabilityRevision` provides ABA resistance for reserve-controlled
mutations.

V2 custody authority is split deliberately:

- Assurance admits and consumes proof application state, but never moves funds.
- The ratification controller orchestrates one atomic transition.
- The V2 reserve owns reserve accounting and calls the allocator.
- The V2 allocator owns funded custody after the reserve transfer.

## Proof and public-values separation

| Property | V1 | V2 |
| --- | --- | --- |
| Proof role | realized execution/allocation activation | legacy source-bound assurance, plus additive beneficiary-entitlement successor |
| Public-values format | V1 exact 384-byte execution format | legacy V2 exact 192-byte six-word format; entitlement successor exact 288-byte nine-word format |
| Schema family | realized-execution V1 | source-bound allocation-binding V2; source-bound entitlement profile V1 successor |
| Core committed state | operation binding, execution projection, claims | legacy `P`, reserve `C`, allocation/realized roots; successor also table/count/total/claim roots |
| Historical observation | execution/activation receipt semantics | separate ratification-time authoritative observation `S` |
| Capital timing | V1 allocator funds before activation/claims | proof work before atomic reserve exclusivity; successor activation establishes liabilities |
| Admission boundary | V1 execution verifier/receipt | V2 source verifier/receipt |
| Cross-acceptance | V1 infrastructure accepts V1 only | V2 infrastructure accepts V2 only |

A V1 160-byte/source-bound proof, V1 execution proof, or V1 receipt must never
be accepted as V2 assurance. A V2 192-byte source-bound statement must never be
accepted by V1 execution infrastructure.

## Deployment profiles

The following profiles are canonical:

1. **V1 production profile**
   - V1 allocator and its required admission/execution verifier artifacts;
   - optional V1 reserve integration;
   - no V2 components required.

2. **V2 optimistic Shortfall profile**
   - V2 prepared-operation controller;
   - V2 assurance and source verifier/admission configuration;
   - V2 ratification controller;
   - V2 reserve;
   - V2 allocator;
   - no V1 activation/claim semantics implied.

3. **Explicit semantic composition**
   - logical identity: `pro-rata-shortfall-composition.v1`;
   - describes the exact join: canonical allocation result/binding -> proof and
     admission -> named Shortfall application funding boundary;
   - references separately identified primitive, proof implementation, and
     application candidates;
   - has no combined mutable lifecycle state and no `latest`/replacement meaning.

4. **Co-deployment bundle**
   - logical identity: `pro-rata-shortfall-bundle.v1`;
   - packages separately identified V1 and/or V2 candidates for operations;
   - does not assert a semantic join beyond the bindings explicitly present in
     the included child candidates.

A bundle is a packaging convenience, while a composition is an auditable
semantic claim. Both must expose all child candidates independently.

## Registry semantics

Generic PRF registry admission and observation remain generic. No V1/V2-specific
lifecycle state, `active`/`latest` replacement semantics, or pro-rata concepts
should be added to generic registry contracts.

The Deployment Ledger should bind explicit application roles to separately
identified contract candidates, for example:

- `pro-rata-allocator-v1` — custody, activation, and claims;
- `shortfall-reserve-v1` — lock-first reserve accounting, if deployed;
- `source-bound-assurance-v2` — V2 source proof admission/consumption;
- `shortfall-ratification-controller-v2` — V2 orchestration;
- `shortfall-reserve-v2` — V2 economic-state ratification and custody boundary;
- `pro-rata-allocator-v2` — V2 exact create/fund custody successor.

These are binding roles, not mutable lifecycle states. Each binding must point to
a concrete candidate/artifact and its immutable metadata. A candidate's
verifier registry root, configuration root/epoch, program VKey, ELF/provenance
hash, statement schema, and public-values schema remain part of that candidate's
identity where applicable.

## Registry Admission / Observation boundary

The existing generic PRF admission model is sufficient:

- `PrfVerifierRegistry` binds verifier ID, adapter, VKey, ELF/provenance hash,
  program ID, statement schema, and public-values schema;
- `PrfStatementAdmission` binds the active registry snapshot, configuration root
  and epoch, proof verification, statement root, and public-values digest;
- the application-specific V1 or V2 consumer interprets the authenticated
  receipt according to its own schema.

No generic admission change is required to represent both paths. V1 and V2 are
distinguished by their registered verifier/program/schema identities and by the
application binding that consumes the receipt.

V2's `AuthoritativeReserveObservationV2` is application evidence, not a generic
registry-observation lifecycle replacement. It records ratification-time
provenance for `P` and `C`; it does not alter the generic admission receipt.

## Deployment Ledger handoff

| Logical/deployment identity | Contracts included | PRF identity/root(s) | Deployment profile | Registry role(s) | Relationship |
| --- | --- | --- | --- | --- | --- |
| `pro-rata-v1` | `ProductionProRataAllocatorV1`, optional `OnchainShortfallReserveV1` | realized-execution V1 verifier/program/schema; V1 operation/configuration roots; claim/allocation roots | V1 production | V1 allocator custody/claims; optional V1 reserve | independent completed V1 family |
| `shortfall-v2` | `SourceBoundProRataControllerV2`, `SourceBoundProRataAssuranceV2`, `SourceBoundProRataRatificationControllerV2`, `OnchainShortfallReserveV2`, `ProductionProRataAllocatorV2` | `preparedOperationRoot`; `reserveStateCommitment`; V2 source verifier/VKey/ELF/schema; configuration/epoch; observation root after ratification | V2 optimistic Shortfall | V2 source assurance; V2 ratification controller; V2 reserve; V2 allocator custody | independent parallel V2 family |
| `pro-rata-shortfall-composition.v1` | named primitive descriptor, proof implementation descriptor, and one named Shortfall application candidate | explicit allocation binding/result root -> proof/admission identity -> application roots | semantic composition | explicit primitive/proof/application join roles | composition, not inheritance or supersession |
| `pro-rata-shortfall-bundle.v1` | separately identified V1 and/or V2 candidates | child identity sets only; no synthetic replacement root | co-deployment bundle | union of separately named child roles | packaging only, not semantic composition |

## Non-supersession rule

V2 does not supersede V1. V1 remains a deployable fallback and an independent
production path. V2 activation must not mutate V1 operation state, verifier
identity, reserve snapshots, allocator claims, or configuration semantics.

The Deployment Ledger should therefore expose V1 and V2 as separate candidates.
If it records a semantic composition, it must expose the exact
primitive -> proof -> application join; if it records a bundle, it must say only
that the child candidates are co-deployed. No Deployment Ledger changes should
be made from an assumption that one version replaces the other.
