#!/usr/bin/env bash
set -Eeuo pipefail

: "${PRIVATE_KEY:?Set PRIVATE_KEY to the local Anvil deployer key}"
: "${GATE_E_PROTOCOL_GENESIS_ROOT:?Set protocol genesis root}"
: "${GATE_E_AUTHORITY_STATE_ROOT:?Set authority state root}"
: "${GATE_E_CHAIN_INSTANCE_GENESIS_ROOT:?Set chain-instance genesis root}"
: "${GATE_E_CONFIGURATION_ROOT_0:?Set configuration root}"
: "${GATE_E_OPERATION_ID:?Set unique operation id}"
: "${GATE_E_POLICY_ROOT:?Set policy root}"
: "${GATE_E_RESERVE_BINDING_ROOT:?Set authoritative Shortfall reserve/application binding root}"
: "${GATE_E_SOURCE_PROGRAM_VKEY:?Set final B3 VKey}"
: "${GATE_E_SOURCE_PROGRAM_ELF_SHA256:?Set final B3 ELF SHA-256}"
: "${GATE_E_SOURCE_VERIFIER_ID:?Set verifier id used by PrfStatementAdmission}"
: "${GATE_E_EXECUTION_VERIFIER_ID:?Set execution verifier id}"
: "${GATE_E_EXECUTION_STATEMENT_SCHEMA:?Set execution statement schema}"
: "${GATE_E_EXECUTION_PUBLIC_VALUES_SCHEMA:?Set execution public-values schema}"
: "${GATE_E_RESIDUAL_RECIPIENT:?Set prepared residual recipient}"

RPC_URL="${GATE_E_RPC_URL:-http://127.0.0.1:8545}"
MANIFEST="${GATE_E_ENTITLEMENT_MANIFEST:-/opt/prf-b3-target/gate-e-entitlement-manifest.json}"
[[ ! -e "$MANIFEST" ]] || { echo "refusing to overwrite manifest: $MANIFEST" >&2; exit 2; }
command -v forge >/dev/null || { echo "forge is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
mkdir -p "$(dirname "$MANIFEST")"
LOG="$(mktemp "${TMPDIR:-/tmp}/gate-e-entitlement-deploy.XXXXXX.log")"
trap 'rm -f "$LOG"' EXIT

forge script script/DeployGateEEntitlementOptionA.s.sol:DeployGateEEntitlementOptionA \
  --rpc-url "$RPC_URL" --broadcast > "$LOG"
mapfile -t PAYLOADS < <(sed -n 's/.*GATE_E_ENTITLEMENT_MANIFEST_JSON[[:space:]]*//p' "$LOG")
[[ "${#PAYLOADS[@]}" -eq 1 ]] || { cat "$LOG" >&2; echo "expected exactly one entitlement manifest payload" >&2; exit 3; }
printf '%s\n' "${PAYLOADS[0]}" | jq -e . >/dev/null || { echo "deployment manifest is invalid JSON" >&2; exit 3; }

TMP_MANIFEST="${MANIFEST}.tmp.$$"
printf '%s\n' "${PAYLOADS[0]}" | jq -S -c . > "$TMP_MANIFEST"
DIGEST="$(jq -S -c 'del(.manifestDigest)' "$TMP_MANIFEST" | sha256sum | awk '{print $1}')"
jq -S -c --arg digest "sha256:$DIGEST" '. + {manifestDigest:$digest}' "$TMP_MANIFEST" > "$MANIFEST"
rm -f "$TMP_MANIFEST"

jq -e --arg digest "sha256:$DIGEST" '
  .schema == "prf-evm.gate-e-entitlement-deployment.v1" and
  .manifestDigest == $digest and
  .programId == "source-bound-entitlement-sp1-program.v1" and
  .economicReserveState.availableAmount == "70" and
  (.contracts | has("admission") and has("sourceAdapter") and has("ratificationController"))
' "$MANIFEST" >/dev/null || { echo "deployment manifest postcondition failed" >&2; exit 3; }
printf 'manifest: %s\n' "$MANIFEST"
printf 'manifest_digest: sha256:%s\n' "$DIGEST"
