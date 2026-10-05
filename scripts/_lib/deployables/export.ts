import * as fs from 'fs';
import * as path from 'path';
import { ConfigError } from './errors';
import { sha256Hex, sha256HexOfBuffer, bytecodeHash } from '../hash';
import { stableStringify, canonicalJson } from '../canonical-json';
import { resolveSourceCommit } from '../source-commit';
import type { Allowlist } from './types';
import type {
  Manifest,
  ManifestArtifactRecord,
  ExportedArtifactFile,
  LinkReferencesMap,
} from './types';
import { readForgeArtifact } from './forge-artifact';
import { loadAllowlist } from './allowlist';

export const SOURCE_REPOSITORY = 'protocol-robustness/prf-evm';
export const DEFAULT_OUT_DIR = path.resolve(process.cwd(), 'out');
export const DEFAULT_EXPORT_DIR = path.resolve(process.cwd(), 'deployables');

export interface ExportOptions {
  allowlist?: Allowlist;
  allowlistPath?: string;
  outDir?: string;
  exportDir?: string;
  sourceCommit?: ReturnType<typeof resolveSourceCommit>;
}

export interface ExportResult {
  manifest: Manifest;
  exportDir: string;
}

export function exportDeployables(opts: ExportOptions = {}): ExportResult {
  const allowlist = opts.allowlist ?? loadAllowlist(opts.allowlistPath);
  const outDir = opts.outDir ?? DEFAULT_OUT_DIR;
  const exportDir = opts.exportDir ?? DEFAULT_EXPORT_DIR;
  const sourceCommit = opts.sourceCommit ?? resolveSourceCommit();

  if (allowlist.buildArtifactSource !== 'forge') {
    throw new ConfigError(
      'UNSUPPORTED_ARTIFACT_SOURCE',
      `Only 'forge' artifact source is implemented; allow-list declares '${allowlist.buildArtifactSource}'`,
    );
  }

  const artifactsDir = path.join(exportDir, 'artifacts');
  const buildInfoDir = path.join(exportDir, 'build-info');
  fs.mkdirSync(artifactsDir, { recursive: true });
  fs.mkdirSync(buildInfoDir, { recursive: true });

  const manifestArtifacts: Record<string, ManifestArtifactRecord> = {};
  const buildSettings: { evmVersion: string; optimizerRuns: number; viaIR: boolean } = {
    evmVersion: 'unknown',
    optimizerRuns: -1,
    viaIR: false,
  };
  let compilerVersion = 'unknown';

  for (const entry of allowlist.entries) {
    const fa = readForgeArtifact(outDir, entry.sourcePath, entry.contractName);

    if (fa.sourcePath !== 'unknown' && entry.sourcePath !== 'unknown' && fa.sourcePath !== entry.sourcePath) {
      throw new ConfigError(
        'SOURCE_PATH_MISMATCH',
        `Allow-list sourcePath '${entry.sourcePath}' for '${entry.contractName}' does not match build artifact '${fa.sourcePath}'`,
      );
    }
    if (fa.compilerVersion !== 'unknown') compilerVersion = fa.compilerVersion;

    const exported: ExportedArtifactFile = {
      name: entry.artifactName,
      contractName: entry.contractName,
      sourcePath: entry.sourcePath,
      origin: entry.origin,
      scopeHint: entry.scopeHint,
      category: entry.category,
      verifier: entry.verifier,
      abi: fa.abi,
      bytecode: fa.bytecodeObject,
      deployedBytecode: fa.deployedBytecodeObject,
      linkReferences: fa.bytecodeLinkReferences,
      deployedLinkReferences: fa.deployedLinkReferences,
      immutableReferences: fa.immutableReferences,
      metadata: fa.metadataBase64,
    };

    const fileName = `${entry.artifactName}.json`;
    const filePath = path.join(artifactsDir, fileName);
    const fileBuf = Buffer.from(stableStringify(exported) + '\n', 'utf8');
    fs.writeFileSync(filePath, fileBuf);

    const abiSha = sha256Hex(canonicalJson(fa.abi));
    const creationSha = bytecodeHash(fa.bytecodeObject);
    const runtimeSha = bytecodeHash(fa.deployedBytecodeObject);
    const ctor = fa.abi.find((x) => (x as { type?: string }).type === 'constructor');
    const ctorSha = ctor ? sha256Hex(canonicalJson(ctor)) : undefined;

    manifestArtifacts[entry.artifactName] = {
      contractName: entry.contractName,
      sourcePath: entry.sourcePath,
      origin: entry.origin,
      scopeHint: entry.scopeHint,
      category: entry.category,
      verifier: entry.verifier,
      artifactFile: `artifacts/${fileName}`,
      abiSha256: abiSha,
      creationBytecodeSha256: creationSha,
      runtimeBytecodeSha256: runtimeSha,
      fileSha256: sha256HexOfBuffer(fileBuf),
      hasLinkReferences: hasLinks(fa.bytecodeLinkReferences),
      hasDeployedLinkReferences: hasLinks(fa.deployedLinkReferences),
      constructorAbiSha256: ctorSha,
    };

    if (fa.optimizerRuns >= 0) buildSettings.optimizerRuns = fa.optimizerRuns;
    if (fa.evmVersion !== 'unknown') buildSettings.evmVersion = fa.evmVersion;
    buildSettings.viaIR = buildSettings.viaIR || fa.viaIR;
  }

  const manifestBase: Omit<Manifest, 'bundleRoot'> = {
    schemaVersion: 1,
    packageName: allowlist.packageName,
    bundleVersion: allowlist.bundleVersion,
    source: {
      repository: SOURCE_REPOSITORY,
      commit: sourceCommit.commit,
      commitSource: sourceCommit.source,
      commitOverride: sourceCommit.override,
      dirty: sourceCommit.dirty,
    },
    build: {
      artifactSource: allowlist.buildArtifactSource,
      profile: allowlist.buildProfile,
      compiler: { name: 'solc', version: compilerVersion },
      settings: buildSettings,
    },
    artifacts: manifestArtifacts,
  };

  const bundleRoot = sha256Hex(canonicalJson(manifestBase));
  const manifest: Manifest = { ...manifestBase, bundleRoot };

  fs.writeFileSync(path.join(exportDir, 'manifest.json'), stableStringify(manifest) + '\n');

  const buildInfo = {
    schemaVersion: 1,
    source: manifestBase.source,
    build: manifestBase.build,
    generated: { exporter: 'prf-evm/deployables-export', manifestSchemaVersion: 1 },
  };
  fs.writeFileSync(path.join(buildInfoDir, 'provenance.json'), stableStringify(buildInfo) + '\n');

  return { manifest, exportDir };
}

function hasLinks(lr: LinkReferencesMap): boolean {
  return Object.keys(lr).length > 0;
}
