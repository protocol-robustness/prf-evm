#!/usr/bin/env ts-node
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

type Json = Record<string, unknown>;
const HEX32 = /^0x[0-9a-fA-F]{64}$/;
const read = (file: string): Json => JSON.parse(fs.readFileSync(file, 'utf8')) as Json;
const fail = (message: string): never => { throw new Error(message); };
const value = (object: Json, keys: string[], name: string): string | undefined => {
  for (const key of keys) if (typeof object[key] === 'string') return object[key] as string;
  return undefined;
};
const requireRoot = (sources: Array<{ object: Json; keys: string[]; name: string }>): string => {
  const found = sources.find(source => value(source.object, source.keys, source.name) !== undefined);
  if (!found) fail(`missing ${sources[0].name}`);
  const root = value(found!.object, found!.keys, found!.name)!;
  if (!HEX32.test(root)) fail(`${found!.name}: expected bytes32`);
  return root;
};
const same = (name: string, entries: Array<{ object: Json; keys: string[] }>) => {
  const values = entries.flatMap(entry => entry.keys.flatMap(key => typeof entry.object[key] === 'string' ? [entry.object[key] as string] : []));
  if (values.length === 0) return;
  if (!values.every(v => v === values[0])) fail(`${name}: inconsistent values`);
};
const digest = (hex: string): string => `0x${crypto.createHash('sha256').update(Buffer.from(hex.slice(2), 'hex')).digest('hex')}`;
const writeNew = (file: string, document: Json) => {
  if (fs.existsSync(file)) fail(`refusing to overwrite existing output: ${file}`);
  fs.writeFileSync(file, `${JSON.stringify(document, null, 2)}\n`, { flag: 'wx' });
};

function main() {
  const [manifestPath, proofPath, outputDir, semanticPath] = process.argv.slice(2);
  if (!manifestPath || !proofPath || !outputDir) fail('usage: generate-source-bound-v2-vectors <gate-e-manifest> <proof-fixture> <output-dir> [semantic-roots]');
  const manifest = read(manifestPath);
  const proof = read(proofPath);
  const semantic = semanticPath ? read(semanticPath) : {};
  if (manifest.schema !== 'prf-evm.gate-e-deployment.v1') fail('manifest: wrong Gate E schema');
  if (typeof manifest.manifestDigest !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(manifest.manifestDigest)) fail('manifest: missing or invalid manifestDigest');
  if (typeof proof.proof === 'string' ? !proof.proof.startsWith('0x') : typeof proof.proofBytes === 'string' ? !proof.proofBytes.startsWith('0x') : true) fail('proof: missing proof bytes');
  const proofPublicValues = (proof.publicValues ?? proof.public_values) as string;
  if (typeof proofPublicValues !== 'string' || !/^0x[0-9a-fA-F]+$/.test(proofPublicValues)) fail('proof: missing public values');
  const publicValueBytes = Buffer.from(proofPublicValues.slice(2), 'hex');
  if (publicValueBytes.length !== 192) fail('proof: public values must be exactly 192 bytes');
  const proofFields: Json = {
    preparedOperationRoot: `0x${publicValueBytes.subarray(32, 64).toString('hex')}`,
    reserveStateCommitment: `0x${publicValueBytes.subarray(64, 96).toString('hex')}`,
    allocationBindingRoot: `0x${publicValueBytes.subarray(96, 128).toString('hex')}`,
    realizedStatementRoot: `0x${publicValueBytes.subarray(128, 160).toString('hex')}`,
    operationId: `0x${publicValueBytes.subarray(160, 192).toString('hex')}`,
  };
  const fields = {
    prepared_operation_root: requireRoot([{ object: manifest, keys: ['preparedOperationRoot', 'prepared_operation_root'], name: 'preparedOperationRoot' }, { object: proof, keys: ['preparedOperationRoot', 'prepared_operation_root'], name: 'preparedOperationRoot' }, { object: proofFields, keys: ['preparedOperationRoot'], name: 'preparedOperationRoot' }, { object: semantic, keys: ['prepared_operation_root'], name: 'preparedOperationRoot' }]),
    reserve_state_root: requireRoot([{ object: manifest, keys: ['reserveStateCommitment', 'reserve_state_root'], name: 'reserveStateCommitment' }, { object: proof, keys: ['reserveStateCommitment', 'reserve_state_root'], name: 'reserveStateCommitment' }, { object: proofFields, keys: ['reserveStateCommitment'], name: 'reserveStateCommitment' }, { object: semantic, keys: ['reserve_state_root'], name: 'reserveStateCommitment' }]),
    allocation_binding_root: requireRoot([{ object: manifest, keys: ['allocationBindingRoot', 'allocation_binding_root'], name: 'allocationBindingRoot' }, { object: proof, keys: ['allocationBindingRoot', 'allocation_binding_root'], name: 'allocationBindingRoot' }, { object: proofFields, keys: ['allocationBindingRoot'], name: 'allocationBindingRoot' }]),
    realized_statement_root: requireRoot([{ object: manifest, keys: ['realizedStatementRoot', 'realized_statement_root'], name: 'realizedStatementRoot' }, { object: proof, keys: ['realizedStatementRoot', 'realized_statement_root'], name: 'realizedStatementRoot' }, { object: proofFields, keys: ['realizedStatementRoot'], name: 'realizedStatementRoot' }]),
    operation_id: requireRoot([{ object: manifest, keys: ['operationId', 'operation_id'], name: 'operationId' }, { object: proof, keys: ['operationId', 'operation_id'], name: 'operationId' }, { object: proofFields, keys: ['operationId'], name: 'operationId' }]),
  };
  for (const [name, keys] of Object.entries({ prepared_operation_root: ['preparedOperationRoot', 'prepared_operation_root'], reserve_state_root: ['reserveStateCommitment', 'reserve_state_root'], allocation_binding_root: ['allocationBindingRoot', 'allocation_binding_root'], realized_statement_root: ['realizedStatementRoot', 'realized_statement_root'], operation_id: ['operationId', 'operation_id'] })) {
    same(name, [{ object: manifest, keys }, { object: proof, keys }, { object: semantic, keys }]);
  }
  if (semanticPath && semantic.schema !== 'source-bound-v2-semantic-vector.v1') fail('semantic: wrong schema');
  const base = path.resolve(outputDir);
  fs.mkdirSync(base, { recursive: false });
  const manifestRef = path.relative(base, path.resolve(manifestPath));
  const proofRef = path.relative(base, path.resolve(proofPath));
  const proofBytes = (proof.proof ?? proof.proofBytes) as string;
  const id = `source-bound-v2-${(manifest.manifestDigest as string).slice(7, 23)}-${digest(proofBytes).slice(2, 18)}`;
  writeNew(path.join(base, 'semantic.json'), { schema: 'source-bound-v2-semantic-vector.v1', vector_id: `${id}-semantic`, deployment_vector_id: `${id}-deployment`, proof_vector_id: `${id}-proof`, ...fields });
  writeNew(path.join(base, 'deployment.json'), { schema: 'source-bound-v2-deployment-state-vector.v1', vector_id: `${id}-deployment`, manifest_path: manifestRef, manifest_digest: (manifest.manifestDigest as string).slice(7), ...fields });
    const publicValues = (proof.publicValues ?? proof.public_values) as string;
    if (typeof publicValues !== 'string' || !/^0x[0-9a-fA-F]*$/.test(publicValues)) fail('proof: missing public values');
    const metadata = {
      proof_digest: digest(proofBytes), public_values_digest: digest(publicValues), public_values_length_bytes: (publicValues.length - 2) / 2,
      proof_system: proof.proofSystem ?? proof.proof_system, vkey: proof.vkey, elf_sha256: proof.elfSha256 ?? proof.elf_sha256,
      program_id: proof.programId ?? proof.program_id, public_values_schema: proof.publicValuesSchema ?? proof.public_values_schema,
    };
    if (metadata.proof_system !== 'groth16' || metadata.public_values_length_bytes !== 192 || Object.values(metadata).some(v => v === undefined)) fail('proof: missing canonical metadata');
    writeNew(path.join(base, 'proof.json'), { schema: 'source-bound-v2-proof-vector.v1', vector_id: `${id}-proof`, fixture_path: proofRef, identity_path: 'source-bound-v2-identity.json', ...metadata, ...fields });
  console.log(`generated source-bound-v2 vectors in ${base}`);
}
try { main(); } catch (error) { console.error(`❌ ${error instanceof Error ? error.message : error}`); process.exit(1); }
