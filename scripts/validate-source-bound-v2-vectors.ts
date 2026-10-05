#!/usr/bin/env ts-node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

type Json = Record<string, any>;
const HEX32 = /^0x[0-9a-fA-F]{64}$/;
const SHA = /^0x[0-9a-fA-F]{64}$/;
const read = (p: string): Json => JSON.parse(fs.readFileSync(p, 'utf8'));
const fail = (message: string): never => { throw new Error(message); };
const required = (o: Json, keys: string[], name: string) => keys.forEach(k => o[k] === undefined && fail(`${name}: missing ${k}`));
const bytes = (value: string, name: string): Buffer => {
  if (!/^0x[0-9a-fA-F]*$/.test(value) || (value.length - 2) % 2) fail(`${name}: invalid hex`);
  return Buffer.from(value.slice(2), 'hex');
};
const sha256 = (b: Buffer): string => `0x${crypto.createHash('sha256').update(b).digest('hex')}`;
const stable = (v: any): string => Array.isArray(v) ? `[${v.map(stable).join(',')}]` : v && typeof v === 'object' ? `{${Object.keys(v).sort().map(k => `${JSON.stringify(k)}:${stable(v[k])}`).join(',')}}` : JSON.stringify(v);
const manifestDigest = (manifest: Json): string => sha256(Buffer.from(stable(Object.fromEntries(Object.entries(manifest).filter(([k]) => k !== 'manifestDigest')))));

function main() {
  const [semanticPath, deploymentPath, proofPath] = process.argv.slice(2);
  if (!semanticPath || !deploymentPath || !proofPath) fail('usage: validate-source-bound-v2-vectors <semantic> <deployment> <proof>');
  const semantic = read(semanticPath), deployment = read(deploymentPath), proof = read(proofPath);
  const identityPath = path.resolve(path.dirname(proofPath), proof.identity_path ?? 'source-bound-v2-identity.json');
  const fixturePath = path.resolve(path.dirname(proofPath), proof.proof_fixture_path ?? 'source-bound-v2-proof-fixture.json');
  const identity = read(identityPath), fixture = read(fixturePath);

  required(semantic, ['schema', 'vector_id', 'deployment_vector_id', 'proof_vector_id', 'prepared_operation_root', 'reserve_state_root'], 'semantic');
  if (semantic.schema !== 'source-bound-v2-semantic-vector.v1') fail('semantic: wrong schema');
  if (!HEX32.test(semantic.prepared_operation_root) || !HEX32.test(semantic.reserve_state_root)) fail('semantic: roots must be bytes32');
  if (semantic.deployment_vector_id !== deployment.vector_id || semantic.proof_vector_id !== proof.vector_id) fail('semantic: vector linkage mismatch');

  required(deployment, ['schema', 'vector_id', 'manifest_path', 'manifest_digest', 'prepared_operation_root', 'reserve_state_root'], 'deployment');
  if (deployment.schema !== 'source-bound-v2-deployment-state-vector.v1') fail('deployment: wrong schema');
  if (!HEX32.test(deployment.prepared_operation_root) || !HEX32.test(deployment.reserve_state_root)) fail('deployment: roots must be bytes32');
  if (deployment.prepared_operation_root !== semantic.prepared_operation_root || deployment.reserve_state_root !== semantic.reserve_state_root) fail('deployment: root linkage mismatch');
  const manifestPath = path.resolve(path.dirname(deploymentPath), deployment.manifest_path);
  const manifest = read(manifestPath);
  if (manifest.schema !== 'prf-evm.gate-e-deployment.v1') fail('deployment: manifest schema mismatch');
  if (!SHA.test(deployment.manifest_digest) || deployment.manifest_digest !== manifest.manifestDigest?.replace('sha256:', '0x')) fail('deployment: manifest digest reference mismatch');
  if (deployment.manifest_digest !== manifestDigest(manifest)) fail('deployment: manifest digest recomputation mismatch');
  if (deployment.manifest_digest !== deployment.manifest_digest.toLowerCase()) fail('deployment: digest must be lowercase');

  required(proof, ['schema', 'vector_id', 'fixture_path', 'identity_path', 'proof_digest', 'public_values_digest', 'public_values_length_bytes'], 'proof');
  if (proof.schema !== 'source-bound-v2-proof-vector.v1') fail('proof: wrong schema');
  if (proof.public_values_length_bytes !== 192) fail('proof: public-values length must be 192');
  if (proof.proof_system !== 'groth16') fail('proof: unsupported proof system');
  const publicValues = bytes(fixture.public_values, 'proof fixture public_values');
  const proofBytes = bytes(fixture.proof, 'proof fixture proof');
  if (publicValues.length !== 192) fail('proof fixture: public-values length is not 192');
  if (proof.public_values_digest !== sha256(publicValues) || proof.public_values_digest !== identity.canonical_public_values_sha256) fail('proof: public-values digest mismatch');
  if (proof.proof_digest !== sha256(proofBytes) || proof.proof_digest !== identity.proof_fixture?.proof_sha256) fail('proof: proof digest mismatch');
  for (const key of ['vkey', 'elf_sha256', 'program_id', 'public_values_schema']) {
    if (fixture[key] !== identity[key] || proof[key] !== identity[key]) fail(`proof: identity mismatch for ${key}`);
  }
  if (identity.public_values_length_bytes !== 192 || identity.proof_fixture?.public_values_sha256 !== proof.public_values_digest) fail('proof: identity fixture mismatch');
  console.log(`✅ source-bound-v2 vectors valid: ${semanticPath}, ${deploymentPath}, ${proofPath}`);
}

try { main(); } catch (error) { console.error(`❌ ${error instanceof Error ? error.message : error}`); process.exit(1); }
