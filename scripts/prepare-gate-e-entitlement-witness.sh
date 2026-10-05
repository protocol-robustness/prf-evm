#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <successor-manifest.json> <source-bound-entitlement-vectors.json> <new-output-input.json>" >&2
  exit 2
fi

MANIFEST="$1"
BUNDLE="$2"
OUTPUT="$3"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
[[ -s "$MANIFEST" ]] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }
[[ -s "$BUNDLE" ]] || { echo "missing conformance bundle: $BUNDLE" >&2; exit 2; }
[[ ! -e "$OUTPUT" ]] || { echo "refusing to overwrite witness: $OUTPUT" >&2; exit 2; }
jq -e '
  .schema == "prf-evm.gate-e-entitlement-deployment.v1" and
  .programId == "source-bound-entitlement-sp1-program.v1" and
  .beneficiaryProfile == "smart-account-v1" and
  (.chainId | type == "number") and
  (.contracts.reserve and .contracts.token and .contracts.allocator) and
  (.economicReserveState.availableAmount | tostring) == "70" and
  (.reserveBindingRoot | test("^0x[0-9a-fA-F]{64}$"))
' "$MANIFEST" >/dev/null || { echo "successor manifest is incomplete or does not match the 70-unit vector profile" >&2; exit 3; }
jq -e '
  .schema == "source-bound-entitlement-conformance.v1" and
  (."base-input" | type == "object") and
  (."base-input"["realized-statement-input"].available | tostring) == "70"
' "$BUNDLE" >/dev/null || { echo "conformance bundle is not the expected source-bound entitlement bundle" >&2; exit 3; }

mkdir -p "$(dirname "$OUTPUT")"
jq -n -S -c --slurpfile manifest "$MANIFEST" --slurpfile bundle "$BUNDLE" \
  -f scripts/gate-e-entitlement-input.jq > "$OUTPUT"
jq -e '
  (keys | sort) == ["beneficiary-mapping","economic-reserve-state","openings","prepared-operation","realized-statement-input","reserve-binding-root"] and
  ."prepared-operation"["beneficiary-profile"] == "smart-account-v1" and
  ."economic-reserve-state"["available-amount"] == "70" and
  (.openings | length) == (."beneficiary-mapping" | length)
' "$OUTPUT" >/dev/null || { rm -f "$OUTPUT"; echo "materialized witness failed strict schema checks" >&2; exit 4; }

WITNESS_SHA256="sha256:$(sha256sum "$OUTPUT" | awk '{print $1}')"
BUNDLE_SHA256="sha256:$(sha256sum "$BUNDLE" | awk '{print $1}')"
PROVENANCE="${OUTPUT%.json}.provenance.json"
[[ ! -e "$PROVENANCE" ]] || { rm -f "$OUTPUT"; echo "refusing to overwrite provenance: $PROVENANCE" >&2; exit 2; }
jq -n -S --arg witness "$WITNESS_SHA256" --arg bundle "$BUNDLE_SHA256" \
  --arg manifest "$(jq -r '.manifestDigest // ""' "$MANIFEST")" \
  '{schema:"prf-evm.gate-e-entitlement-witness-provenance.v1", vector_id:"A-minimum-realistic", witness_sha256:$witness, bundle_sha256:$bundle, manifest_digest:$manifest}' \
  > "$PROVENANCE"
printf 'witness: %s\n' "$OUTPUT"
printf 'witness_sha256: %s\n' "$WITNESS_SHA256"
printf 'provenance: %s\n' "$PROVENANCE"
