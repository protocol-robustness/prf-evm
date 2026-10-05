import * as fs from 'fs';
import * as path from 'path';
import { ConfigError } from './errors';
import { isBytecode } from '../hash';
import type { ForgeArtifact, LinkReferencesMap } from './types';

/**
 * Reads a Foundry `out/<SourceFileBasename>/<ContractName>.json` artifact.
 *
 * Foundry names the per-source `out/` subdirectory after the source file's
 * basename (including its full extension, e.g. `LocalShortfallSnapshot.s.sol`
 * or `SP1VerifierGroth16.sol`) while the artifact JSON is named after the
 * CONTRACT it declares. Those two only coincide when the file basename equals
 * the contract name, so the out directory is derived from `sourcePath` (the
 * allow-listed source file) rather than from `contractName`.
 *
 * This is the repository's native, tested build output (validated by forge
 * tests). No separate compiler configuration is invoked.
 */
export function readForgeArtifact(outDir: string, providedSourcePath: string, contractName: string): ForgeArtifact {
  const sourceDir = path.basename(providedSourcePath);
  const file = path.join(outDir, sourceDir, `${contractName}.json`);
  let raw: Record<string, any>;
  try {
    raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    throw new ConfigError(
      'ARTIFACT_NOT_FOUND',
      `Forge artifact not found for '${contractName}' at ${file}`,
      { details: { cause: e instanceof Error ? e.message : String(e) } },
    );
  }

  const abi: unknown[] = Array.isArray(raw.abi) ? raw.abi : [];
  const bytecodeObject: string = raw.bytecode?.object ?? '';
  const deployedBytecodeObject: string = raw.deployedBytecode?.object ?? '';
  if (!isBytecode(bytecodeObject) || !isBytecode(deployedBytecodeObject)) {
    throw new ConfigError('ARTIFACT_BYTECODE_INVALID', `Artifact '${contractName}' has invalid/missing bytecode`);
  }

  let metadataBase64 = '';
  let metadata: unknown = null;
  let compilerVersion = 'unknown';
  let evmVersion = 'unknown';
  let optimizerRuns = -1;
  let viaIR = false;

  const metaObj = raw.metadata as Record<string, any> | undefined;
  const metaStr = typeof raw.metadata === 'string' ? (raw.metadata as string) : undefined;
  const rawMetaStr = typeof raw.rawMetadata === 'string' ? (raw.rawMetadata as string) : undefined;

  if (metaObj && typeof metaObj === 'object') {
    metadata = metaObj;
    compilerVersion = metaObj.compiler?.version ?? 'unknown';
    const settings = metaObj.settings ?? {};
    evmVersion = settings.evmVersion ?? 'unknown';
    optimizerRuns = settings.optimizer?.runs ?? -1;
    viaIR = settings.viaIR === true;
    metadataBase64 = Buffer.from(JSON.stringify(metaObj), 'utf8').toString('base64');
  } else {
    const src = metaStr ?? rawMetaStr;
    if (src) {
      try {
        const parsed = JSON.parse(Buffer.from(src, 'base64').toString('utf8'));
        metadata = parsed;
        metadataBase64 = src;
        compilerVersion = parsed.compiler?.version ?? 'unknown';
        const settings = parsed.settings ?? {};
        evmVersion = settings.evmVersion ?? 'unknown';
        optimizerRuns = settings.optimizer?.runs ?? -1;
        viaIR = settings.viaIR === true;
      } catch {
        // leave defaults
      }
    }
  }

  const sourcePath: string = raw.ast?.absolutePath ?? metadataCompilationTarget(metadata) ?? 'unknown';

  return {
    contractName,
    sourcePath,
    abi,
    bytecodeObject,
    deployedBytecodeObject,
    bytecodeLinkReferences: raw.bytecode?.linkReferences ?? {},
    deployedLinkReferences: raw.deployedBytecode?.linkReferences ?? {},
    immutableReferences: raw.deployedBytecode?.immutableReferences ?? {},
    metadataBase64,
    compilerVersion,
    evmVersion,
    optimizerRuns,
    viaIR,
    methodIdentifiers: raw.methodIdentifiers ?? {},
  };
}

function metadataCompilationTarget(metadata: unknown): string | null {
  try {
    const m = metadata as Record<string, any>;
    const target = m?.settings?.compilationTarget;
    if (target && typeof target === 'object') {
      const keys = Object.keys(target);
      if (keys.length > 0) return keys[0]!;
    }
    return null;
  } catch {
    return null;
  }
}

export function hasLinkReferences(lr: LinkReferencesMap): boolean {
  return Object.keys(lr).length > 0;
}
