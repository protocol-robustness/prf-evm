import * as fs from 'fs';
import * as path from 'path';
import { ConfigError } from './errors';
import type { Allowlist, AllowlistEntry, ScopeHint, Category, VerifierMeta } from './types';

const SCOPE_HINTS = new Set<ScopeHint>(['prf', 'shared']);
const CATEGORIES = new Set<Category>([
  'core',
  'governance',
  'application',
  'consumer',
  'verifier',
  'integration',
  'library',
]);
const ORIGINS = new Set(['prf', 'openzeppelin', 'sp1']);

export const DEFAULT_ALLOWLIST_PATH = path.resolve(process.cwd(), 'config', 'deployable-allowlist.json');

export function loadAllowlist(allowlistPath: string = DEFAULT_ALLOWLIST_PATH): Allowlist {
  let raw: unknown;
  try {
    raw = JSON.parse(fs.readFileSync(allowlistPath, 'utf8'));
  } catch (e) {
    throw new ConfigError('ALLOWLIST_UNREADABLE', `Cannot read allow-list at ${allowlistPath}: ${e instanceof Error ? e.message : String(e)}`);
  }

  const obj = raw as Record<string, unknown>;
  if (obj.schemaVersion !== 1) {
    throw new ConfigError('ALLOWLIST_SCHEMA', `Unsupported allow-list schemaVersion: ${String(obj.schemaVersion)}`);
  }
  if (typeof obj.packageName !== 'string' || obj.packageName.length === 0) {
    throw new ConfigError('ALLOWLIST_SCHEMA', 'allow-list requires packageName');
  }
  if (typeof obj.bundleVersion !== 'string' || obj.bundleVersion.length === 0) {
    throw new ConfigError('ALLOWLIST_SCHEMA', 'allow-list requires bundleVersion');
  }
  if (obj.buildArtifactSource !== 'forge' && obj.buildArtifactSource !== 'hardhat') {
    throw new ConfigError('ALLOWLIST_SCHEMA', `Unsupported buildArtifactSource: ${String(obj.buildArtifactSource)}`);
  }
  if (!Array.isArray(obj.entries) || obj.entries.length === 0) {
    throw new ConfigError('ALLOWLIST_EMPTY', 'allow-list must contain at least one entry');
  }

  const entries: AllowlistEntry[] = obj.entries.map((e, i) => {
    const ent = e as Record<string, unknown>;
    for (const f of ['artifactName', 'contractName', 'sourcePath', 'scopeHint', 'category']) {
      if (typeof ent[f] !== 'string' || (ent[f] as string).length === 0) {
        throw new ConfigError('ALLOWLIST_SCHEMA', `entry ${i} missing ${f}`);
      }
    }
    if (!SCOPE_HINTS.has(ent.scopeHint as ScopeHint)) {
      throw new ConfigError('ALLOWLIST_SCHEMA', `entry ${i} invalid scopeHint ${String(ent.scopeHint)}`);
    }
    if (!CATEGORIES.has(ent.category as Category)) {
      throw new ConfigError('ALLOWLIST_SCHEMA', `entry ${i} invalid category ${String(ent.category)}`);
    }
    const origin = ent.origin as string | undefined;
    if (origin !== undefined && !ORIGINS.has(origin)) {
      throw new ConfigError('ALLOWLIST_SCHEMA', `entry ${i} invalid origin ${origin}`);
    }
    const verifier = ent.verifier as VerifierMeta | undefined;
    if (verifier !== undefined) {
      if (typeof verifier.family !== 'string' || typeof verifier.configMechanism !== 'string') {
        throw new ConfigError('ALLOWLIST_SCHEMA', `entry ${i} verifier metadata requires family + configMechanism`);
      }
    }
    return {
      artifactName: ent.artifactName as string,
      contractName: ent.contractName as string,
      sourcePath: ent.sourcePath as string,
      scopeHint: ent.scopeHint as ScopeHint,
      category: ent.category as Category,
      origin: origin as AllowlistEntry['origin'],
      verifier,
      notes: ent.notes as string | undefined,
    };
  });

  const seen = new Set<string>();
  for (const e of entries) {
    if (seen.has(e.artifactName)) {
      throw new ConfigError('ALLOWLIST_DUPLICATE', `Duplicate artifactName ${e.artifactName}`);
    }
    seen.add(e.artifactName);
  }

  return {
    schemaVersion: 1,
    packageName: obj.packageName as string,
    bundleVersion: obj.bundleVersion as string,
    buildArtifactSource: obj.buildArtifactSource as 'forge' | 'hardhat',
    buildProfile: typeof obj.buildProfile === 'string' ? obj.buildProfile : 'default',
    entries,
  };
}
