#!/usr/bin/env bash
set -Eeuo pipefail

# Gate E remains externally orchestrated. This slice captures one deployment
# manifest, binds it to live Anvil observations and the checked-in canonical
# SP1 identity, then preflights it before invoking the prover. It does not
# claim Gate E closure and never overwrites or deletes artifacts.

: "${GATE_E_DEPLOY_CMD:?Set GATE_E_DEPLOY_CMD to the real deployment command}"
: "${GATE_E_PROVER_CMD:?Set GATE_E_PROVER_CMD to the real Rust prover command}"
MANIFEST="${GATE_E_MANIFEST:-fixtures/gate-e-deployment-manifest.live.json}"
IDENTITY="${GATE_E_IDENTITY:-fixtures/source-bound-v2-identity.json}"
FIXTURE="${GATE_E_FIXTURE:-fixtures/gate-e-proof-fixture.json}"
INPUT="${GATE_E_INPUT:-fixtures/gate-e-source-bound-v2-input.live.json}"
VECTOR_DIR="${GATE_E_VECTOR_DIR:-}"
RPC_URL="${GATE_E_RPC_URL:-http://127.0.0.1:8545}"
ANVIL_PID=""

cleanup() {
  if [[ -n "$ANVIL_PID" ]]; then kill "$ANVIL_PID" 2>/dev/null || true; wait "$ANVIL_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

command -v anvil >/dev/null || { echo "Gate E blocked: anvil is not installed" >&2; exit 2; }
command -v forge >/dev/null || { echo "Gate E blocked: forge is not installed" >&2; exit 2; }
command -v jq >/dev/null || { echo "Gate E blocked: jq is required for manifest preflight" >&2; exit 2; }
command -v curl >/dev/null || { echo "Gate E blocked: curl is required for live preflight" >&2; exit 2; }
[[ ! -e "$MANIFEST" ]] || { echo "Gate E blocked: refusing to overwrite existing manifest: $MANIFEST" >&2; exit 2; }
[[ ! -e "$FIXTURE" ]] || { echo "Gate E blocked: refusing to overwrite existing proof fixture: $FIXTURE" >&2; exit 2; }
[[ ! -e "$INPUT" ]] || { echo "Gate E blocked: refusing to overwrite existing prover input: $INPUT" >&2; exit 2; }
[[ -s "$IDENTITY" ]] || { echo "Gate E blocked: missing identity fixture: $IDENTITY" >&2; exit 2; }
command -v cast >/dev/null || { echo "Gate E blocked: cast is required to derive the pinned schema words" >&2; exit 2; }

PORT="${RPC_URL##*:}"
anvil --silent --chain-id 31337 --port "$PORT" >"${TMPDIR:-/tmp}/gate-e-anvil.log" 2>&1 &
ANVIL_PID=$!
for _ in {1..50}; do
  curl -sf -X POST "$RPC_URL" -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >/dev/null && break
  sleep 0.1
done

# Capture the deployment producer's single canonical JSON line. The producer
# remains the authority for deployment-derived fields; the shell only binds
# observations and provenance around that payload.
DEPLOY_LOG="$(mktemp "${TMPDIR:-/tmp}/gate-e-deploy.XXXXXX.log")"
trap 'rm -f "$DEPLOY_LOG"; cleanup' EXIT
eval "$GATE_E_DEPLOY_CMD" >"$DEPLOY_LOG"
mapfile -t MANIFEST_LINES < <(sed -n 's/.*GATE_E_MANIFEST_JSON[[:space:]]*//p' "$DEPLOY_LOG")
[[ "${#MANIFEST_LINES[@]}" -eq 1 ]] || { echo "Gate E blocked: deployment must emit exactly one GATE_E_MANIFEST_JSON payload" >&2; exit 3; }
BASE_JSON="${MANIFEST_LINES[0]}"
printf '%s\n' "$BASE_JSON" | jq -e . >/dev/null || { echo "Gate E blocked: emitted manifest is not JSON" >&2; exit 3; }

CHAIN_ID="$(curl -sf -X POST "$RPC_URL" -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' | jq -r '.result')"
BLOCK_HEX="$(curl -sf -X POST "$RPC_URL" -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' | jq -r '.result')"
BLOCK_NUMBER=$((16#${BLOCK_HEX#0x}))
[[ "$CHAIN_ID" == "0x7a69" ]] || { echo "Gate E blocked: live chain id is $CHAIN_ID, expected 0x7a69" >&2; exit 3; }

# Query code at every emitted contract address. Empty code is a deployment
# failure; bindings/configuration roots remain explicit fields for later typed
# calls and are not guessed by this orchestration layer.
CONTRACTS_WITH_CODE='{}'
while IFS=$'\t' read -r name address; do
  code="$(curl -sf -X POST "$RPC_URL" -H 'content-type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$address\",\"latest\"]}" | jq -r '.result')"
  [[ "$code" != "0x" && "$code" != "0x0" ]] || { echo "Gate E blocked: no live code for $name at $address" >&2; exit 3; }
  CONTRACTS_WITH_CODE="$(jq -c --arg n "$name" --arg c "$code" '. + {($n):$c}' <<<"$CONTRACTS_WITH_CODE")"
done < <(jq -r '.contracts | to_entries[] | [.key,.value] | @tsv' <<<"$BASE_JSON")

OBSERVED="$(jq -n --arg chain "$CHAIN_ID" --arg block "$BLOCK_HEX" --argjson number "$BLOCK_NUMBER" --argjson code "$CONTRACTS_WITH_CODE" '{chainIdHex:$chain,blockNumberHex:$block,blockNumber:$number,contractCode:$code}')"
IDENTITY_JSON="$(cat "$IDENTITY")"
jq -e '(.schema_version == "source-bound-v2-identity.v1") and (.sp1_version == "6.3.1") and (.sp1_circuit_version == "v6.1.0") and (.verifier_contract_family == "sp1-contracts/v6.1.0") and (.vkey | type == "string" and test("^0x[0-9a-fA-F]{64}$")) and (.elf_sha256 | type == "string" and test("^0x[0-9a-fA-F]{64}$"))' "$IDENTITY" >/dev/null || { echo "Gate E blocked: canonical source-bound-v2 identity fixture is not the pinned SP1 6.3.1 / v6.1.0 identity" >&2; exit 3; }
ENRICHED="$(jq -c --argjson obs "$OBSERVED" --argjson identity "$IDENTITY_JSON" '. + {provenance:{"live-derived":{chainId:.chainId,blockNumber:$obs.blockNumber,contractCode:$obs.contractCode},"canonical-external":{identityFixture:"'"$IDENTITY"'",sp1Version:$identity.sp1_version,sp1CircuitVersion:$identity.sp1_circuit_version,verifierContractFamily:$identity.verifier_contract_family,vkey:$identity.vkey,elfSha256:$identity.elf_sha256,statementSchema:$identity.statement_schema,publicValuesSchema:$identity.public_values_schema},"derived-manifest":{}} ,liveObservation:$obs}' <<<"$BASE_JSON")"
DIGEST="$(jq -S -c 'del(.manifestDigest)' <<<"$ENRICHED" | sha256sum | awk '{print $1}')"
FINAL="$(jq -c --arg d "sha256:$DIGEST" '. + {manifestDigest:$d}' <<<"$ENRICHED")"
printf '%s\n' "$FINAL" > "$MANIFEST"

jq -e --arg d "sha256:$DIGEST" '.schema == "prf-evm.gate-e-deployment.v1" and .chainId == 31337 and (.contracts|type=="object") and (.deploymentTxs|type=="array") and .manifestDigest == $d and (.provenance|has("live-derived") and has("canonical-external") and has("derived-manifest"))' "$MANIFEST" >/dev/null || { echo "Gate E blocked: canonical manifest preflight failed" >&2; exit 3; }

# Materialize the exact V2 raw witness from the deployment facts and explicit
# local-only policy values. The Rust core remains the authority for deriving
# prepared/reserve roots and the prover rejects any mismatch with the manifest.
SOURCE_STATEMENT_SCHEMA="$(cast keccak "$(jq -r '.statement_schema' "$IDENTITY")")"
SOURCE_PUBLIC_VALUES_SCHEMA="$(cast keccak "$(jq -r '.public_values_schema' "$IDENTITY")")"
mkdir -p "$(dirname "$INPUT")"
jq -n --slurpfile manifest "$MANIFEST" --slurpfile identity "$IDENTITY" \
  --arg sourceStatementSchema "$SOURCE_STATEMENT_SCHEMA" \
  --arg sourcePublicValuesSchema "$SOURCE_PUBLIC_VALUES_SCHEMA" \
  -f scripts/gate-e-source-bound-v2-input.jq > "$INPUT"
jq -e '."prepared-operation" and ."economic-reserve-state" and ."allocation-binding-root" and ."realized-statement-root"' "$INPUT" >/dev/null || { echo "Gate E blocked: failed to materialize deployment-bound V2 witness" >&2; exit 4; }

# The prover is invoked only after deployment capture, live code checks,
# identity-fixture checks, and deterministic manifest digest calculation.
export GATE_E_MANIFEST="$MANIFEST"
export GATE_E_FIXTURE="$FIXTURE"
export GATE_E_INPUT="$INPUT"
eval "$GATE_E_PROVER_CMD"
[[ -s "$FIXTURE" ]] || { echo "Gate E blocked: prover did not write $FIXTURE" >&2; exit 4; }
jq -e --arg vkey "$(jq -r '.vkey' "$IDENTITY")" --arg elf "$(jq -r '.elf_sha256' "$IDENTITY")" \
  '.proof_system == "groth16" and (.proof|type=="string" and test("^0x[0-9a-fA-F]+$")) and (.public_values|type=="string" and test("^0x[0-9a-fA-F]{384}$")) and .vkey == $vkey and .elf_sha256 == $elf and .public_values_schema == "prf/onchain-shortfall-allocation-binding-public-values.v2"' \
  "$FIXTURE" >/dev/null || { echo "Gate E blocked: proof fixture must be matching source-bound V2 Groth16 output with exactly 192 public-value bytes" >&2; exit 4; }
EXPECTED_PUBLIC_VALUES="$(cast abi-encode 'f(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)' \
  "$(cast keccak 'prf/onchain-shortfall-allocation-binding-public-values.v2')" \
  "$(jq -r '.preparedOperationRoot' "$MANIFEST")" \
  "$(jq -r '.reserveStateCommitment' "$MANIFEST")" \
  "$(jq -r '.allocationBindingRoot' "$MANIFEST")" \
  "$(jq -r '.realizedStatementRoot' "$MANIFEST")" \
  "$(jq -r '.operationId' "$MANIFEST")")"
ACTUAL_PUBLIC_VALUES="$(jq -r '.public_values' "$FIXTURE" | tr '[:upper:]' '[:lower:]')"
[[ "${ACTUAL_PUBLIC_VALUES,,}" == "${EXPECTED_PUBLIC_VALUES,,}" ]] || {
  echo "Gate E blocked: prover public values do not match deployment manifest roots" >&2
  exit 4
}

# When requested, generate and validate the linked semantic/deployment/proof
# vector bundle before Foundry. The generator is fail-closed and refuses an
# existing output directory, so this never overwrites evidence.
if [[ -n "$VECTOR_DIR" ]]; then
  [[ ! -e "$VECTOR_DIR" ]] || { echo "Gate E blocked: refusing to overwrite vector output directory: $VECTOR_DIR" >&2; exit 4; }
  npm run --silent source-bound-v2:generate -- "$MANIFEST" "$FIXTURE" "$VECTOR_DIR"
  npm run --silent source-bound-v2:validate -- "$VECTOR_DIR/semantic.json" "$VECTOR_DIR/deployment.json" "$VECTOR_DIR/proof.json"
fi

GATE_E_MANIFEST="$MANIFEST" GATE_E_FIXTURE="$FIXTURE" forge test --fork-url "$RPC_URL" --match-contract GateEDeploymentDerivedRealProofTest
printf 'Gate E orchestration completed: captured manifest and proof were exercised; this does not claim Gate E closure.\n'
