# Changelog

## Unreleased

- Added the neutral `IPrfAuthority` compatibility surface for PRF core contracts while preserving the existing SEW-compatible ABI.
- Added the local-only `PrfLocalAuthorityAdapter` deployable for synthetic PRF deployments.
- Regenerated the deployable artifact bundle with the local authority adapter and preserved immutable-reference metadata for runtime verification.
- Added the V2 source-assurance lifecycle: one-time governance binding of the ratification controller, receipt-validated `Prepared` assurance records, and controller-only one-shot `Consumed` handoff for atomic reserve ratification.
- Added one-time V2 reserve ratification-authority binding, allowing successor controller deployment without changing V1 reserve authority semantics.
- Added the native `ProductionProRataAllocatorV2` custody successor for exact atomic V2 create/fund postconditions; V1 allocator custody and lifecycle remain unchanged.
- Added one-time V2 allocator funding-authority binding to support safe reserve/allocator deployment sequencing.
- Exported the separately deployable V2 Shortfall family and the upstream `SP1MockVerifier` required by the explicitly local-only V2 deployment profile; this does not change V1 or establish a production verifier selection.
- Fixed the deployable export reader so a source file whose basename differs from its declared contract name (e.g. `LocalShortfallSnapshot.s.sol` → `LocalSnapshotToken`, or `SP1VerifierGroth16.sol` → `SP1Verifier`) resolves the correct Foundry out directory from the allow-listed source path. This makes the generated bundle reproducible.
- Root-anchored the `.gitignore` `deployables/`/`dist-deployables/` patterns so the deployable-export source under `scripts/_lib/deployables/` is no longer shadowed and is now committable, while the generated bundle output remains ignored.
