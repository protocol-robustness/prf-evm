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

The focused controller test verifies exact funding and rollback when the reserve changes after proof preparation. The historical deployment orchestrator and `GateEDeploymentDerivedRealProofTest` still exercise the 192-byte V2 profile. The separate successor deployment producer/materializer has completed the deployment-bound proof → admission → assurance → ratification → funding path. The successor Gate E test now checks fixture-derived representation activation and cancel-and-refund against the same deterministic Anvil deployment identity used to materialize and prove the witness. The deployment-bound witness SHA-256 is `d1423f38382fd0c6c7d072b9a79f1b39256f9e24793f793b0ed5a2d16eca1182`; its manifest digest is `sha256:7ee98ade8ab9138d325240826cab2fa3831a80749bbc67c572d5377a9b94e666`. All four tests in `GateEEntitlementDeploymentDerivedRealProofTest` passed against the refreshed current-code local deployment, covering logical-table reconstruction, activation, exact cancel-and-refund accounting, and Requested/Required withdrawal.

## Stage C reference representation and activation

`IEntitlementRepresentationV1` defines the physical-storage-independent read surface: `logicalRoot()`, `entitlementCount()`, and `entitlementTotal()`. `PublicPackedEntitlementRepresentationV1` is the deliberately simple storage-backed reference implementation. `CommittedImmutableEntitlementRepresentationV1` is the production candidate: it deploys STOP-prefixed immutable bytecode shards containing the ordered EVM entitlement commitments and reads them with `EXTCODECOPY`. Both compute the exact B2 table-node tree (positional pairs, duplicate the final odd node) and table summary over root, count, and total. The physical shard size is configurable within the EVM code-size limit and does not enter the logical root or representation descriptor. The local EVM benchmark below compares their construction and representative withdrawal costs; production deployment qualification remains separate follow-up work.

### Local EVM gas benchmark

Measured with Foundry/solc 0.8.33, optimizer enabled (200 runs), `via_ir = true`, on the repository's local test EVM. `deployment gas` is `gasleft()` around each constructor, including runtime code deposit and child-shard creation, but excluding transaction intrinsic gas and external deployment tooling. Storage words and runtime-code bytes are structural footprint estimates read from the implementation: the packed implementation stores one dynamic-array length plus one slot per commitment; the immutable wrapper stores one dynamic-array length plus one pointer per shard, and each shard runtime is one STOP byte plus its commitment payload. Withdrawal values are complete Requested-mode, entitlement-only `withdraw` calls including table proof verification, token transfer, and allocator accounting. The second call consumes another bit in the same bitmap word. These are raw local EVM measurements, not Base/L2 cost estimates.

| Entitlements | Packed constructor gas | Immutable constructor gas | Packed storage words | Immutable pointer words | Packed runtime bytes | Immutable wrapper bytes | Immutable shard runtime bytes | Shards | Table proof depth | First bitmap-word withdrawal gas | Additional same-word bit withdrawal gas |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 372,537 | 339,959 | 11 | 2 | 400 | 746 | 321 | 1 | 4 | 158,680 | 90,939 |
| 100 | 2,485,230 | 1,024,712 | 101 | 2 | 400 | 746 | 3,201 | 1 | 7 | 160,945 | 93,204 |
| 1,000 | 23,746,423 | 8,138,100 | 1,001 | 5 | 400 | 746 | 32,004 | 4 | 10 | 163,211 | 95,470 |
| 10,000 | 251,676,724 | 90,756,004 | 10,001 | 41 | 400 | 746 | 320,040 | 40 | 14 | 166,233 | 98,492 |

At 10,000 entries, the current all-at-once immutable constructor is a 90.8 million local-gas deployment transaction; this is a scale warning for deployment design, not a semantic or logical-root limitation. A later deployment qualification should measure the target chain and may need staged physical shard deployment while preserving the same logical table root. The benchmark harness is `test/EntitlementRepresentationGasBench.t.sol` (`test_Benchmark_10`, `_100`, `_1000`, `_10000`).

After successor funding, the execution caller may request activation. The allocator checks that the deployed representation's root/count/total equal the admitted successor record and that funded `amount == entitlementTotal`, then stores the representation address and changes `Funded → Activated`. A mismatch reverts and leaves the operation `Funded`, allowing retry with the correct representation. The admitted `allocationClaimRoot` remains the sole stored claim root. Focused mock-admission tests cover activation and cancellation/refund; the deployment-derived real-proof test now reconstructs the logical table from claim-keyed openings and has separate activation and refund branches. The real-proof branches have now passed against a fresh current-code local deployment with the same manifest digest and witness identity as the proof fixture. Funded-but-not-activated operations return capital to the recorded reserve source through cancel-and-refund. The legacy V2 funded route has the same terminal cancellation/refund path. Cancellation and successor activation contend on the same `Funded` state, and successful activation is irreversible through this ordinary lifecycle.

The successor deployment and fixture path is now additive:

```bash
GATE_E_ENTITLEMENT_MANIFEST=/opt/prf-b3-target/gate-e-entitlement-manifest.json \
  pnpm gate-e-entitlement:deploy

pnpm gate-e-entitlement:witness \
  /opt/prf-b3-target/gate-e-entitlement-manifest.json \
  /path/to/source-bound-entitlement-v1.json \
  /opt/prf-b3-target/gate-e-entitlement-input.json
```

The deployment command expects the `GATE_E_*` identity/configuration values consumed by `DeployGateEEntitlementOptionA.s.sol`, and uses the already-running Anvil instance at `GATE_E_RPC_URL` (default `http://127.0.0.1:8545`). It deploys 80 units with 10 protected, matching the B2 vector A available total of 70. The witness builder copies the B2 base input and replaces only prepared-operation, live reserve, and reserve-binding facts from the manifest. It rejects existing output paths and writes a separate forensic provenance sidecar.

After proving the materialized input with `source-bound-entitlement-prove --prove --input ... --fixture ...`, convert the raw B3 fixture before Solidity tests:

```bash
pnpm gate-e-entitlement:fixture \
  /opt/prf-b3-target/gate-e-entitlement-manifest.json \
  /path/to/source-bound-entitlement-v1.json \
  /opt/prf-b3-target/gate-e-entitlement-input.json \
  /opt/prf-b3-target/source-bound-entitlement-proof.json \
  /opt/prf-b3-target/gate-e-entitlement-proof-fixture.json
```

The adapter refuses inconsistent program/VKey/ELF, witness hash, schema, roots, count, total, or proof type. The resulting fixture retains the B3 proof and public values and adds deployment/vector provenance. Run `GateEEntitlementDeploymentDerivedRealProofTest` against the same Anvil chain with `GATE_E_ENTITLEMENT_MANIFEST`, `GATE_E_ENTITLEMENT_INPUT`, and `GATE_E_ENTITLEMENT_FIXTURE` set. This deployment-bound successor path passes the real Groth16 fixture through the current-code deployment: the manifest digest and deterministic witness hash match the proof fixture, and all four Foundry tests pass. Coverage includes logical-table reconstruction, proof admission through assurance and ratification, activation, cancel-and-refund, and Requested/Required withdrawal. The refreshed deployment used the same manifest digest and prepared/reserve roots as the proof-producing run. Its broadcast record is retained in the repository; the proof, manifest, witness, and provenance remain under `/opt/prf-b3-target/gate-e-20261009` and `/opt/prf-b3-target/gate-e-20261009-current`.


## Successor entitlement withdrawal

The source-bound-entitlement successor uses one atomic withdrawal call on
`ProductionProRataAllocatorV2`; there is no pending request or fulfillment
transaction. The call carries the operation, entitlement opening (canonical
index, UTF-8 claim identity, stable beneficiary address, amount, and 32-byte
salt), ordered table siblings, an explicit allocation-proof-present flag and
claim siblings, and a caller minimum mode. It has no payout override. The
allocator verifies the opening against the activated logical table root and
pays the committed beneficiary with exact ERC-20 balance deltas.

`SewConfigurationExecutor.currentEntitlementProofMode` is the live policy source
(`0 = Requested`, `1 = Required`). A normal governed configuration decision may
carry an authorized mode through
`GovGovernor.authorisePrfDecisionWithEntitlementProofMode` and is consumed by
`applyConfigurationWithEntitlementProofMode`; a mode-bearing decision cannot be
consumed by the legacy configuration apply function. The initial mode is
Requested. Required means a valid allocation-claim Merkle path in addition to
the table opening. Requested permits no claim proof and does not fail solely for
an invalid supplied path. `minimumMode = Required` remains effective if the live
mode is later lowered to Requested.

After activation, a successful withdrawal consumes both an ordinal bitmap bit
and claim identity before transfer. Amount/count/liability counters are checked
against the admitted totals, and the operation closes only when both the total
and count are fully discharged. There is no expiry, sweep, or post-activation
cancellation.


### Persistent local successor funding

`script/RunGateEEntitlementLocal.s.sol:RunGateEEntitlementLocal` submits the
real deployment-derived proof on chain 31337. Set `PRIVATE_KEY`,
`GATE_E_ENTITLEMENT_MANIFEST`, `GATE_E_ENTITLEMENT_INPUT`, and
`GATE_E_ENTITLEMENT_FIXTURE`. Grant Foundry read access to those files in a
local `foundry.toml` configuration. Simulate first with:

```sh
forge script script/RunGateEEntitlementLocal.s.sol:RunGateEEntitlementLocal \
  --config-path /tmp/foundry.toml --root /home/user/Code/prf-evm \
  --rpc-url http://127.0.0.1:8545
```

After successful simulation, use the same command with `--broadcast`.
The signer must be the prepared controller's existing governance identity.
The script deploys an immutable local example operator bound to that signer,
one operation, and its ratification controller. It binds that contract as the
one-time execution caller. It exposes only funding, representation activation,
and refund for the bound operation, with operator authorization on each call.
There is no arbitrary call forwarding or authority replacement. This example
authority is restricted to chain 31337; it is not a production dispatcher.

The funding script is a first-run tool and rejects an already-bound execution
caller. Transactions are separate: operator deployment/binding, admission,
assurance, registration, and funding. A later failed transaction does not undo
earlier successful transactions. Retain the broadcast record and resume via
the recorded operator and existing contracts after inspecting state; do not
redeploy or try to rebind. The controller's funding transaction itself remains
atomic.

On 2026-10-10 the deployment-derived `gate-e-20261010-current-00d90` proof
was submitted persistently to the existing Anvil instance. Execution caller:
`0x18E317A7D70d8fBf8e6E893616b52390EbBdb629`. Readback confirmed prepared
state `Ratified`, allocator state `Funded`, reserve custody 10, allocator
custody 70, total reserved 0, and outstanding liability 0. Activation and
withdrawal have not yet been submitted persistently for this operation.
This is separate from the four successful fork integration tests.


### Funding forensic capture

Run `python3 scripts/capture-gate-e-entitlement-forensics.py` with
`--manifest`, `--witness`, `--fixture`, `--broadcast`, `--output`, and optional
`--rpc-url`. Capture requires the original local chain, successful receipts,
matching deployment/program/witness identities, and historical state access.
Existing output files are never overwritten. It performs read-only RPC calls.

The retained example is in
`evidence/gate-e-20261010-current-00d90/funding-forensic.json`, accompanied by
an `execution-dag.json` constructed and validated using the core repository's
existing `resolver-sim.forensic.execution-dag` functions. The DAG links manifest,
witness, proof fixture, broadcast, actual transaction order, and accounting
observation. Its hashes identify forensic records, not canonical PRF economic
artifacts. Neither transaction/block metadata nor optional proof telemetry
enters entitlement identities.

The capture discovered mismatched function/hash associations in Forge's
broadcast entries for this run. Actual RPC transaction calldata/destinations,
receipt block hashes and transaction indices establish execution order. Both
the original label and the actual classification are retained. Funding was
executed at block 40: reserve balance 80 → 10, allocator balance 0 → 70,
protected capital 10, total reserved 0, outstanding liability 0. These are
block-level observations, not transaction-level state proofs; the record does
not assert cryptographic authenticity of RPC responses or qualify activation,
withdrawal, or closure.


### Persistent local activation

After funding, run
`script/ActivateGateEEntitlementLocal.s.sol:ActivateGateEEntitlementLocal`
with the same manifest/input/fixture/private-key environment and narrow
Foundry read permissions used for persistent funding. Simulate with
`forge script ... --rpc-url http://127.0.0.1:8545` before adding `--broadcast`.
The operation must be `Funded` and its existing immutable operator must
authorize the signer. This tool is explicitly restricted to the reviewed
`A-minimum-realistic` fixture: three canonical claims allocated 35, 21, 14.
It verifies claim-to-beneficiary/salt mappings and the full witness hash,
then requires the resulting logical root/count/total to equal the admitted
funded values. It is not a generic operational pro-rata witness generator.

Representation deployment and activation are separate transactions. If
activation fails, the funded operation remains refundable and the deployed
representation is an unused immutable contract. Successful activation is the
ordinary economic irreversibility cutpoint; refund is subsequently forbidden.

The local operation was activated at block 42 on 2026-10-10 with representation
`0xc96304e3c037f81da488ed9dea1d8f2a48278a75`. Its two physical shards realize
the same admitted logical root, count 3, and total 70. Reserve custody remained
10 and allocator custody 70; outstanding liability changed from 0 to 70.
The stored allocation claim root remained unchanged. Public broadcast receipts,
`activation-forensic.json`, and the companion activation DAG retain this
transition and link it to the funding evidence. Withdrawals and closure remain
subsequent persistent steps.
