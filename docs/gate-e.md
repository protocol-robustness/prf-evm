# Gate E: deployment-derived real-proof capital E2E

Gate E is still an externally orchestrated assurance gate; this slice does **not** claim Gate E closure or change production semantics. `scripts/gate-e-e2e.sh` starts a persistent local Anvil, captures exactly one `GATE_E_MANIFEST_JSON` emitted by `DeployGateE`, enriches it, and preflights it before invoking the caller-supplied prover.

```bash
GATE_E_DEPLOY_CMD='…real deployment command…' \
GATE_E_PROVER_CMD='…real Rust prover command…' \
./scripts/gate-e-e2e.sh
```

The canonical new output defaults to `fixtures/gate-e-deployment-manifest.live.json` and may be selected with `GATE_E_MANIFEST`. The path must be absent: the runner refuses to overwrite or delete any artifact. The output is one compact canonical JSON object and carries `manifestDigest`, computed as SHA-256 over sorted compact JSON with `manifestDigest` removed.

The manifest schema distinguishes provenance rather than conflating claims:

- `provenance.live-derived`: observations queried from the running Anvil instance, including chain ID, block number, and non-empty runtime code for every emitted contract. The emitted prepared-operation root and reserve-state commitment are retained as deployment payload values; this slice does not guess ABI calls for their independent recomputation.
- `provenance.canonical-external`: identity copied from the existing `fixtures/source-bound-v2-identity.json` fixture. Preflight requires the fixture and records SP1 6.3.1, circuit/verifier family v6.1.0, VKey, ELF SHA-256, and statement/public-values schemas.
- `provenance.derived-manifest`: reserved for fields derived by this capture step; it is intentionally empty in this slice rather than asserting unsupported semantics.

The deployment producer remains responsible for deployment-derived values. The orchestrator does not invent configuration, genesis, verifier, prepared-root, reserve, or proof identities. It queries live chain/code state where feasible; typed binding/configuration calls remain explicit inputs for a later slice and are not guessed from storage. The prover is invoked only after capture, live-code checks, identity checks, and deterministic digest/preflight.

The runner materializes a deployment-bound raw witness at `GATE_E_INPUT` (default `fixtures/gate-e-source-bound-v2-input.live.json`) from the manifest, pinned source identity, and the reserve state observed by the deployment producer. Monetary values remain decimal strings in the manifest/witness boundary to avoid JSON number precision loss. The prover receives `GATE_E_MANIFEST`, `GATE_E_INPUT`, and `GATE_E_FIXTURE` in its environment; its command must prove that input and write the fixture at that path.

The fixture uses the source-bound V2 Rust CLI field names (`proof_system`, `public_values`, `elf_sha256`, and `public_values_schema`), reports `proof_system: "groth16"`, and contains exactly 192 public-value bytes. The runner checks the VKey and ELF against the pinned identity fixture and refuses to overwrite existing manifest, input, or proof artifacts. The Foundry test checks those fixture fields again and compares proof public values byte-for-byte with the deployment manifest roots before admission. A generic checked-in proof fixture is not a substitute: its deployment-specific roots must match the live manifest.

`script/DeployGateE.s.sol` remains unchanged: its Solidity VM cannot write files, so its single stdout payload is captured by the shell orchestrator. Deployment transaction hashes still require recovery from Foundry broadcast JSON.

The final Foundry test still runs against the same Anvil instance and supplied proof fixture. A successful run means only that this orchestration path completed; it is not a Gate E closure claim.

## Successor entitlement funding seam

The nine-word entitlement profile intentionally omits `realizedStatementRoot`. It therefore cannot use the frozen V2 `IOnchainShortfallReserveV2.RatificationRequest` / `IShortfallAllocatorV2.Operation` handoff by aliasing another root. The additive `SourceBoundProRataEntitlementRatificationControllerV1` route consumes the successor assurance tuple and calls the entitlement reserve/allocator interfaces. These store the allocation-binding root, descriptor root, logical EVM table root, count, total, and claim root as separate fields, and fund only when the live available amount equals the proved entitlement total. The old V2 ratification ABI remains unchanged.

The focused controller test verifies exact funding and rollback when the reserve changes after proof preparation. Gate E is not yet closed for the successor profile: its current deployment orchestrator and `GateEDeploymentDerivedRealProofTest` still exercise the historical 192-byte V2 profile. A separate successor deployment manifest and a deployment-bound proof generated from that manifest are still required before claiming the real proof → admission → assurance → ratification → funding path.
