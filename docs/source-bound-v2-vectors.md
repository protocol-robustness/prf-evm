# Source-bound V2 vector documents

The generator creates concrete semantic, deployment-state, and proof vector documents from an existing Gate E deployment manifest and proof fixture. It is read-only with respect to its inputs and fail-closed: missing roots, malformed values, inconsistent duplicate values, unsupported proof metadata, and existing output files are errors.

```bash
pnpm source-bound-v2:generate <gate-e-manifest.json> <proof-fixture.json> <new-output-directory> [semantic-roots.json]
```

The optional semantic document may supply only canonical external `prepared_operation_root` and `reserve_state_root` values. Deployment/proof-bound values (`allocation_binding_root`, `realized_statement_root`, and `operation_id`) must come from the manifest or proof fixture; the generator never invents them. Values present in more than one source must be identical.

The command writes `semantic.json`, `deployment.json`, and `proof.json` with `wx`/no-overwrite semantics. The output directory must not already exist, and no existing artifact is modified or deleted. The generated documents can then be checked with:

```bash
pnpm source-bound-v2:validate -- <output>/semantic.json <output>/deployment.json <output>/proof.json
```

This command does not deploy contracts, call an RPC, alter Solidity, or claim proof validity beyond the supplied fixture metadata.
