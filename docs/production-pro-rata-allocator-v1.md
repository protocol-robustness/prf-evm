# Production Pro-Rata Allocator V1

`ProductionProRataAllocatorV1` is a deliberately narrow ERC-20 custody application for the frozen `realized-allocation-execution.v1` SP1 projection. It does not change generic admission or receipt formats, independently reimplement pro-rata arithmetic, or treat admission as application authority.

## Assurance and execution boundary

- `PrfRealizedExecutionVerifierAdapter` accepts only the exact 384-byte, twelve-word static ABI projection and verifies its SP1 proof.
- An operation immutably precommits its statement root, required configuration root/epoch, token, raw base-unit amount, and residual-recipient policy. The execution projection independently binds the target allocator, chain ID, operation ID, token, and available amount.
- Activation accepts an existing receipt only when its statement/configuration snapshot and internally derived `sha256(publicValues)` match the operation. It then checks the decoded projection and the Keccak operation binding (including available amount). Admission facts are frozen at admission time; the operation independently decides which configuration snapshot it accepts.
- Activation is the one-shot allocator reliance/consumption point. It does not assert that SP1 proved the allocator’s runtime custody state; funding and claim status remain local Solidity facts.

## Custody and claims

- An operation moves `Created → Funded → Activated → Claims → Closed`; the authority can cancel only before activation.
- Claims authenticate an application-specific ordered, duplicate-last Merkle tree. Each leaf commits operation binding, UTF-8 claim ID, recipient, and amount. Claims are permissionless to submit, but tokens always go to the proof-committed recipient.
- Funding, claims, and pre-activation refunds require exact ERC-20 sender and receiver balance deltas. Fee-on-transfer and other balance-changing transfer behavior are rejected. Claim state is committed before transfer and a reentrancy guard covers token interactions.
- V1 requires proof-bound `totalAllocated == availableAmount` and `residualAmount == 0`. `residualRecipient` remains immutable operation policy only; there is no residual payout path.

## Conformance status

The Foundry suite decodes the exact pinned Rust-generated 384-byte public-value vector and separately derives adversarial local vectors. It covers projection digest and binding checks, configuration-snapshot mismatch, Merkle identity/proof rejection, duplicate claims, lifecycle/cancellation, fee-token rejection, and generic-admission integration.

The test suite includes the generated `fixtures/realized-execution-proof-fixture.json` real Groth16 fixture. `RealizedExecutionProofEtchedIntegration` reads that fixture, deploys the SP1 v6.1 Groth16 verifier, registers `PrfRealizedExecutionVerifierAdapter` through the generic registry/admission machinery, admits the proof, rejects altered public values, activates the allocator at the proof-committed address, and completes an authenticated ERC-20 claim.

The allocator remains experimental: this conformance path is not a deployment, external security audit, operational procedure, or generic-token compatibility guarantee.
