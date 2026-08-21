# Security Policy

## Supported versions

This package is **experimental / pre-production** (see `README.md`). It is not
yet suitable for production use, in particular not as asset-holding
infrastructure. Supported branches may change as the project matures.

| Version     | Status      |
|-------------|-------------|
| `main`      | Experimental |

## Reporting a vulnerability

Security is taken seriously, but this codebase is explicitly pre-audit. Do
**not** use any public issue tracker to report security-sensitive problems.

If you have found a vulnerability that you believe should not be disclosed
publicly, please report it in confidence by emailing the maintainers. Use the
email address associated with the repository owners; if none is published, open
a private report through the hosting platform if available.

Your report should include:

- a description of the issue and the potential impact;
- steps to reproduce or a proof of concept;
- any suggested remediation.

We will acknowledge receipt and aim to respond within 5 business days, though we
can make no guarantee of timelines given the pre-production status. We will not
publish details of a reported issue until we have assessed it and arranged a fix
or mitigation.

## Scope

In scope: security issues in the contracts under `src/`, the build/deployment
configuration under `foundry.toml` / `foundry.lock`, and the genesis
transitions governed by `GovGovernor` + `TimelockController` +
`SewGovernanceAuthorityAdapter`.

Out of scope: the off-chain PRF/Clojure canonical hashing implementation, the
SP1 guest/prover (managed elsewhere), and any test-only mocks such as
`MockSP1Verifier`, which is explicitly not a real verifier.

## What "not audited" means here

- There has been no formal third-party security audit.
- Conformance/adversarial tests exist (`test/`), including replay/rejection
  demonstrations, but tests are not a substitute for an audit.
- Canonical roots are computed off-chain and re-checked for equality on-chain;
  do not attempt to reproduce PRF canonical hashing inside the EVM.
- Evidence anchoring establishes existence, not correctness.
