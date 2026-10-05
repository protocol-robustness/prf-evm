#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const [manifestPath, bundlePath, witnessPath, proofPath, outputPath] = process.argv.slice(2);
if (!outputPath) {
  console.error('usage: adapt-gate-e-entitlement-fixture.mjs <manifest> <vectors> <witness> <b3-proof-fixture> <new-output>');
  process.exit(2);
}
if (existsSync(outputPath)) throw new Error(`refusing to overwrite fixture: ${outputPath}`);

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'));
const sha256 = (value) => `0x${createHash('sha256').update(value).digest('hex')}`;
const sortKeys = (value) => Array.isArray(value)
  ? value.map(sortKeys)
  : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys(value[key])]))
    : value;
const manifest = readJson(manifestPath);
const bundleBytes = readFileSync(bundlePath);
const bundle = JSON.parse(bundleBytes.toString('utf8'));
const witnessBytes = readFileSync(witnessPath);
const proof = readJson(proofPath);

const requireThat = (condition, message) => {
  if (!condition) throw new Error(message);
};
requireThat(manifest.schema === 'prf-evm.gate-e-entitlement-deployment.v1', 'manifest schema mismatch');
requireThat(manifest.programId === 'source-bound-entitlement-sp1-program.v1', 'manifest program mismatch');
requireThat(bundle.schema === 'source-bound-entitlement-conformance.v1', 'B2 vector bundle schema mismatch');
requireThat(bundle.vectors.some(({ id }) => id === 'A-minimum-realistic'), 'B2 vector A missing');
requireThat(proof.program_id === manifest.programId, 'proof program identity mismatch');
requireThat(proof.proof_system === 'groth16', 'EVM fixture must use Groth16');
requireThat(proof.vkey.toLowerCase() === manifest.programVKey.toLowerCase(), 'proof VKey differs from deployed adapter');
requireThat(proof.elf_sha256.toLowerCase() === manifest.programElfSha256.toLowerCase(), 'proof ELF differs from deployed adapter');
requireThat(proof.public_values_schema === 'prf/source-bound-entitlement-public-values.v1', 'public-values schema mismatch');
requireThat(proof.public_values_length === 288, 'public-values length metadata mismatch');
requireThat(proof.source?.kind === 'raw-witness', 'proof must identify raw witness input');
requireThat(proof.source.witness_sha256.toLowerCase() === sha256(witnessBytes), 'proof witness hash mismatch');

const expectedInput = structuredClone(bundle['base-input']);
expectedInput['prepared-operation'] = {
  ...expectedInput['prepared-operation'],
  'operation-id': manifest.operationId,
  initiator: manifest.deployer,
  'chain-id': String(manifest.chainId),
  reserve: manifest.contracts.reserve,
  token: manifest.contracts.token,
  allocator: manifest.contracts.allocator,
  'configuration-root': manifest.configurationRoot,
  'configuration-epoch': String(manifest.configurationEpoch),
  'source-verifier-id': manifest.localOnly.sourceVerifierId,
  'source-program-vkey': manifest.programVKey,
  'source-program-elf-sha256': manifest.programElfSha256,
  'source-statement-schema': manifest.sourceStatementSchema,
  'source-public-values-schema': manifest.publicValuesSchema,
  'execution-verifier-id': manifest.localOnly.executionVerifierId,
  'execution-statement-schema': manifest.localOnly.executionStatementSchema,
  'execution-public-values-schema': manifest.localOnly.executionPublicValuesSchema,
  'policy-root': manifest.policyRoot,
  'beneficiary-profile': manifest.beneficiaryProfile,
  'residual-recipient': manifest.localOnly.residualRecipient,
};
expectedInput['economic-reserve-state'] = {
  'gross-balance': String(manifest.economicReserveState.grossBalance),
  'reserved-before': String(manifest.economicReserveState.reservedBefore),
  'protected-capital': String(manifest.economicReserveState.protectedCapital),
  'available-amount': String(manifest.economicReserveState.availableAmount),
  'availability-revision': String(manifest.economicReserveState.availabilityRevision),
};
expectedInput['reserve-binding-root'] = `sha256:${manifest.reserveBindingRoot.slice(2).toLowerCase()}`;
const expectedWitness = Buffer.from(`${JSON.stringify(sortKeys(expectedInput))}\n`);
requireThat(witnessBytes.equals(expectedWitness), 'witness is not the deterministic B2 vector/manifest materialization');

const publicValues = proof.public_values;
requireThat(typeof publicValues === 'string' && /^0x[0-9a-fA-F]{576}$/.test(publicValues), 'public values must be exactly 288 bytes');
const words = Array.from({ length: 9 }, (_, index) => `0x${publicValues.slice(2 + index * 64, 2 + (index + 1) * 64).toLowerCase()}`);
requireThat(words[0] === '0x876f2aea9124d79f41dbdd389d498430987fa33bbb34408989849c478a7c2bde', 'schema word mismatch');
requireThat(words[1] === manifest.preparedOperationRoot.toLowerCase(), 'prepared operation root mismatch');
requireThat(words[2] === manifest.reserveStateCommitment.toLowerCase(), 'reserve commitment mismatch');
requireThat(words[4] === '0x0e8b6d0eb8a46279fee6697366b2bdfa0b4aa514dacf17e9e264744d90d91c1f', 'descriptor root mismatch');
requireThat(BigInt(words[6]) === 3n, 'vector A entitlement count mismatch');
requireThat(BigInt(words[7]) === 70n, 'vector A entitlement total mismatch');
requireThat(words[3] !== `0x${'0'.repeat(64)}` && words[5] !== `0x${'0'.repeat(64)}` && words[8] !== `0x${'0'.repeat(64)}`, 'required root is zero');

const fixture = {
  ...proof,
  gate_e: {
    schema: 'prf-evm.gate-e-entitlement-proof-fixture.v1',
    manifest_digest: manifest.manifestDigest,
    source_bundle_sha256: sha256(bundleBytes),
    vector_id: 'A-minimum-realistic',
    witness_sha256: sha256(witnessBytes),
    proof_sha256: sha256(Buffer.from(proof.proof.slice(2), 'hex')),
    operation_id: manifest.operationId,
    prepared_operation_root: manifest.preparedOperationRoot,
    reserve_state_commitment: manifest.reserveStateCommitment,
  },
};
writeFileSync(outputPath, `${JSON.stringify(fixture, null, 2)}\n`, { flag: 'wx' });
console.log(`Gate E fixture: ${outputPath}`);
console.log(`proof_sha256: ${fixture.gate_e.proof_sha256}`);
