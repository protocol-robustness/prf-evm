# Changelog

## Unreleased

- Added one-step successor entitlement withdrawal with live governed Requested/Required enforcement, caller minimum assurance, table-opening verification, optional non-blocking Requested claim proofs, single-use consumption, exact settlement, and liability-based closure. The existing V1 claim path remains unchanged.

- Qualified the deployment-bound successor Gate E Groth16 path on Anvil through logical-table reconstruction, proof admission, assurance, ratification, exact funding, and both activation and cancel-and-refund outcomes using a witness-matched proof fixture.

- Legacy V2 and successor entitlement funded operations can be cancelled before downstream reliance and refunded to their recorded reserve with exact token-delta checks; focused tests cover exact accounting and activation/refund races.

- Both funding controllers reject prepared chain, reserve, token, allocator, and bound controller-instance mismatches before assurance consumption or funding. Legacy roots and proof public values remain unchanged.
- V2 ordinary reservation creation requires an immutable future deadline. Permissionless expiry at `timestamp >= expiresAt` releases reserved availability and increments revision without moving tokens. Reservation state getter and creation event include the deadline; existing enum values remain stable.


- Gate E successor witness materialization normalizes deployment hex values to the reviewed canonical lowercase encoding; fixture reconstruction enforces the same bytes.

- Added the logical entitlement representation interface and a storage-backed reference implementation for the successor table-root profile. Successor activation now checks the admitted table root, count, total, and funded amount against the representation before recording `Activated`; this is unit-tested with mock admission and is now deployment-qualified by the deployment-derived Gate E proof path, including activation and cancel-and-refund branches.

- Added a separate deployment-bound Gate E producer, B2-vector witness materializer, and proof-fixture adapter for the 288-byte entitlement profile. The new Foundry path checks deployment/VKey/ELF/witness provenance, admits the real Groth16 proof, and funds the exact entitlement total through the successor ratification route; the historical 192-byte runner remains separate.

- Added the successor entitlement ratification/funding route. It atomically forwards the admitted allocation binding, descriptor, EVM table root, count, total, and claim root into a separate allocator record, without fabricating the `realizedStatementRoot` required by the frozen V2 route. The existing V2 interfaces and operation path remain available unchanged.

- Successor entitlement assurance now rejects admission receipts whose configuration root or epoch differs from the prepared operation commitment.

- Fixed the Gate E real-proof handoff to materialize a deployment-bound source witness, pass its manifest/input/fixture paths to the prover, and validate the Rust CLI's snake_case Groth16 fixture format and pinned V2 identity before Foundry admission.

- Added an additive assurance lifecycle for the source-bound entitlement V1 proof profile. It validates generic admission receipts against the prepared operation and freezes the entitlement table, count, total, and claim root for one-shot ratification handoff; the existing 192-byte V2 assurance remains unchanged.

- Added a successor prepared-operation commitment and preparation entry point that bind the beneficiary profile while preserving the frozen V2 commitment. Ratification also checks configuration root/epoch and residual recipient against prepared context, and atomically marks operations Ratified before funding so abandon/fund ordering has one successful terminal outcome.

- Added the additive `PrfSourceBoundEntitlementVerifierAdapterV1` profile for the fixed nine-word, 288-byte `prf/source-bound-entitlement-public-values.v1` projection. It enforces the frozen schema and representation descriptor roots while preserving the existing 192-byte source-bound V2 adapter. A focused Foundry test also verifies the actual B3 Groth16 proof fixture with the real SP1 verifier.

- Added the read-only minimal source-bound V2 vector layer: schemas and a deterministic preflight for semantic, deployment-state, and proof vectors. It cross-checks Gate E manifest/proof linkage, canonical VKey/ELF/schema identity, 192-byte public values and digests, proof digest, prepared/reserve roots, and manifest digest without changing contracts or proof semantics. See `docs/source-bound-v2-vectors.md`.

- Added `test/GateEV2GovernedVerifierActivation.t.sol`, which exercises the governed verifier activation for the source-bound V2 shortfall program using the canonical VKey/ELF pinned in the deployed local topology (`fixtures/source-bound-v2-identity.json`): register + seal the real adapter under a canonical registry root, drive the governed `SewConfigurationExecutor` transition (epoch 0 → 1), and instantiate a fresh `PrfStatementAdmission` bound to the post-transition configuration. It also asserts that an admission still bound to the pre-transition epoch is rejected. The final real-proof admission step is documented as gated on a matching SP1 proof for the canonical program, which no committed fixture currently satisfies.

- Added the neutral `IPrfAuthority` compatibility surface for PRF core contracts while preserving the existing SEW-compatible ABI.
- Added the local-only `PrfLocalAuthorityAdapter` deployable for synthetic PRF deployments.
- Regenerated the deployable artifact bundle with the local authority adapter and preserved immutable-reference metadata for runtime verification.
- Added the V2 source-assurance lifecycle: one-time governance binding of the ratification controller, receipt-validated `Prepared` assurance records, and controller-only one-shot `Consumed` handoff for atomic reserve ratification.
- Added one-time V2 reserve ratification-authority binding, allowing successor controller deployment without changing V1 reserve authority semantics.
- Added the native `ProductionProRataAllocatorV2` custody successor for exact atomic V2 create/fund postconditions; V1 allocator custody and lifecycle remain unchanged.
- Added one-time V2 allocator funding-authority binding to support safe reserve/allocator deployment sequencing.
- Recorded official SP1 v6.3.1 provenance for the v6.1.0 Groth16 circuit family and empirically verified the frozen V2 proof fixture against the official Solidity verifier; governed verifier activation remains downstream.
- Exported the separately deployable V2 Shortfall family and the upstream `SP1MockVerifier` required by the explicitly local-only V2 deployment profile; this does not change V1 or establish a production verifier selection.
- Exported the official `SP1VerifierGroth16` deployable (sp1-contracts v6.1.0, sp1 release 6.3.1) so the V2 local profile can bind the real verifier rather than the mock. The artifact is exposed under the `SP1VerifierGroth16` identity; the v6.1.0 source file declares contract `SP1Verifier`.
- Fixed the deployable export reader so a source file whose basename differs from its declared contract name (e.g. `LocalShortfallSnapshot.s.sol` → `LocalSnapshotToken`, or `SP1VerifierGroth16.sol` → `SP1Verifier`) resolves the correct Foundry out directory from the allow-listed source path. This makes the generated bundle reproducible.
- Root-anchored the `.gitignore` `deployables/`/`dist-deployables/` patterns so the deployable-export source under `scripts/_lib/deployables/` is no longer shadowed and is now committable, while the generated bundle output remains ignored.
- Fixed deprecated contract-typed comparisons in `script/DeployGateE.s.sol` (explicit `address(...)` casts; behavior unchanged).
