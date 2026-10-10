# Protected-capital successor: local qualification review

Reviewed 2026-10-10. The deployment-derived vector-A local scenarios are
qualified through both economic branches below. The whole NOW tranche is not
production-complete: remaining acceptance gaps are listed explicitly.

## Recorded economic outcomes

| Branch | Persistent transition | Exact custody/accounting | Retained evidence |
| --- | --- | --- | --- |
| Settlement | Proof → admission → assurance → funding (block 40) → activation (42) → withdrawals/closure (43–46) | Reserve 80 → 10; allocator 0 → 70 → 0; activated liability 0 → 70 → 0; claimed amount/count 70/3 | `evidence/gate-e-20261010-current-00d90/` |
| Refund | Separate proof → admission → assurance → funding (53) → cancel-and-refund (55) | Reserve 80 → 10 → 80; allocator 0 → 70 → 0; liability remains 0; controller CancelledRefunded, allocator Cancelled | `evidence/gate-e-20261010-refund-00d90/` |

Protected capital remains 10 throughout. The settlement operation is Closed;
the separate refund operation is terminally cancelled. Historical prepared and
allocation roots are retained. Refund does not revoke activated entitlements.

Settlement receipts record 35 under Requested without a claim proof, 21 under
Required with a valid proof and caller minimum Required, and 14 under Requested
with an invalid optional proof. The latter proof observation is forensic;
entitlement authorization and the canonical economic identity remain unchanged.
Mode changes used the deployed configuration authority/executor. The local
example authority is controlled by the funded Anvil test signer; it does not
qualify a production governor deployment or governance configuration.

The proof programs use VKey
`0x00d90efa52d17e54670a4248f001e4da443a938f12c55d0d414c125ba68087b9`
and ELF SHA-256
`0x636330de8e7af3485aba50bd3ca4b5e024cc4f977a2bf0f2c005f711e5ffacf8`.
Public values have the successor schema and exactly nine words / 288 bytes.
Each deployment has its own operation, witness and proof. The converter enforces
this relationship; the vector-A regression proof cannot substitute for either
operation's deployment-derived proof.

## Evidence and validation

Cross-record checks in this review verified the funding → activation → withdrawal
and funding → refund file-hash links, distinct operation IDs, exact conservation,
proof identity and byte length, and retained DAG edge/hash references.
Execution DAGs were built and validated with the existing core
`resolver-sim.forensic.execution-dag` machinery. File hashes and DAG hashes are
forensic identities, not PRF economic roots.

Actual RPC calldata, destinations and receipt order establish transaction
classification. Four Forge funding broadcast labels disagreed with the live
transactions in the settlement run; both labels and actual classifications are
retained. Do not infer funding identity from a broadcast label alone.

Three original withdrawals rejected on read-only replay after closure. Duplicate
refund and activation after refund rejected at the controller's terminal-state
check. These are failed eth_call observations, not mined failed transactions.
RPC captures are unsigned and are not cryptographic state proofs. Accounting
observations are pinned to blocks and should not be described as independent
transaction-level state proofs. Public broadcast records are retained; private
Foundry cache material is not included.

Relevant successful validations already run for this slice:

- New refund fixture on the original pre-funding fork block 50:
  `GateEEntitlementDeploymentDerivedRealProofTest`, 4/4 passed.
- Withdrawal/governance suites: 7/7 passed.
- Representation/lifecycle/operator suites: 21/21 passed; refund preparation
  reran the overlapping lifecycle/operator subset, 17/17 passed.
- Script compilation, simulations, format/whitespace checks, and persistent
  on-chain readback succeeded.
- Broader core `bb backstop` completed with one fmt-check finding. Its exit code
  was zero despite the finding; it is not a clean pass. No Clojure source was
  changed by these local operator/evidence changes. Existing lint warnings and
  formatting findings are outside this slice; no repository-wide green claim.

These suites overlap; their counts must not be added as a distinct-test total.

## Remaining NOW acceptance gaps

1. **Deployment identity alignment.**
   `protocol-deployments/config/pro-rata-v2-entitlement/architecture.edn:56–57`
   still selects VKey `003cb0…` / ELF `7e9cf1…`. The qualified successor uses
   `00d90…` / `636330…`. Align the deployment profile and pinned artifact bundle,
   then validate provenance and deployment outputs. The successful direct
   prf-evm script does not qualify this different deployment configuration.

2. **General application witness materialization.**
   The activation/settlement scripts deliberately use vector-A claims and
   amounts 35/21/14. They validate the full witness and admitted roots but are
   not a general source-authenticated Shortfall demand/beneficiary/opening
   workflow. Define and implement that operator path before general real use.
   Keep pro-rata arithmetic in its existing deterministic primitive.

3. **Properties and hostile token execution.**
   Focused successor withdrawal tests cover replay, substitution, fee-on-transfer
   rollback, mode switching and exact example accounting. No testFuzz_ or
   invariant_ functions were found in the audited successor entitlement,
   withdrawal or reserve suites. Reserve funding reentrancy coverage exists in
   `OnchainShortfallReserveV2.t.sol`; it does not establish withdrawal callback
   reentrancy coverage. Add successor consumption/conservation/lifecycle property
   tests and a withdrawal reentrancy regression, and review rebasing/token
   postcondition coverage. A nonReentrant modifier alone is not an adversarial
   execution test.

4. **Representation differential/scale qualification.**
   `EntitlementRepresentationGasBench` and docs/gate-e.md record 10, 100, 1,000
   and 10,000-entry constructor footprints and representative Requested
   withdrawals. Physical sharding/root equivalence is tested. This is not the
   full identical-withdrawal/rejection/conservation vector suite across both
   reference and immutable representations. Complete that differential coverage.
   The recorded immutable 10,000-entry all-at-once constructor costs 90,756,004
   local gas and cannot fit the current 30-million-gas Anvil block. Bound a
   supported size or qualify a staged physical deployment strategy. Raw EVM gas
   is not measured Base execution/DA cost.

5. **Operator resumption and beneficiary qualification.**
   First-run scripts are documented as separate transactions and deliberately
   reject partial or terminal operations. They do not yet provide a tested
   automatic resumption command. Preserve broadcast/state evidence when resuming.
   The semantic smart-account profile binds stable addresses; these ERC-20 local
   runs do not exercise actual wallet signer/validator rotation or recovery.
   Do not claim wallet integration from address/profile binding alone.

6. **Final documentation/release review.**
   Reconcile acceptance claims with these limitations, identify the unrelated
   formatting finding, and pin deployable artifacts and intended governance
   authority configuration. Base Sepolia remains a later deployment step.

The local lifecycle integration gate is closed for the demonstrated scenarios.
Bounded production use and the master NOW completion gate remain open until
these acceptance gaps are resolved or explicitly bounded with supporting tests.
