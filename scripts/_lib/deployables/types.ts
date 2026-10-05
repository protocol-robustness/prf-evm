/** Shared types for the PRF deployable-artifact export subsystem. */

export type ScopeHint = 'prf' | 'shared';
export type Category =
  | 'core'
  | 'governance'
  | 'application'
  | 'consumer'
  | 'verifier'
  | 'integration'
  | 'library';

/** Implementation-level verifier metadata (facts only, no application mappings). */
export interface VerifierMeta {
  family: string;
  configMechanism: string;
  registryInterface?: string;
  admissionInterface?: string;
}

export interface AllowlistEntry {
  artifactName: string;
  contractName: string;
  sourcePath: string;
  scopeHint: ScopeHint;
  category: Category;
  origin?: 'prf' | 'openzeppelin' | 'sp1';
  verifier?: VerifierMeta;
  notes?: string;
}

export interface Allowlist {
  schemaVersion: number;
  packageName: string;
  bundleVersion: string;
  buildArtifactSource: 'forge' | 'hardhat';
  buildProfile: string;
  entries: AllowlistEntry[];
}

export type LinkReferencesMap = Record<string, Record<string, Array<{ start: number; length: number }>>>;
export type ImmutableReferencesMap = Record<string, Array<{ start: number; length: number }>>;

export interface ForgeArtifact {
  contractName: string;
  sourcePath: string;
  abi: unknown[];
  bytecodeObject: string;
  deployedBytecodeObject: string;
  bytecodeLinkReferences: LinkReferencesMap;
  deployedLinkReferences: LinkReferencesMap;
  immutableReferences: ImmutableReferencesMap;
  metadataBase64: string;
  compilerVersion: string;
  evmVersion: string;
  optimizerRuns: number;
  viaIR: boolean;
  methodIdentifiers: Record<string, string>;
}

export interface ManifestArtifactRecord {
  contractName: string;
  sourcePath: string;
  origin?: 'prf' | 'openzeppelin' | 'sp1';
  scopeHint: ScopeHint;
  category: Category;
  verifier?: VerifierMeta;
  artifactFile: string;
  abiSha256: string;
  creationBytecodeSha256: string;
  runtimeBytecodeSha256: string;
  fileSha256: string;
  hasLinkReferences: boolean;
  hasDeployedLinkReferences: boolean;
  constructorAbiSha256?: string;
}

export interface Manifest {
  schemaVersion: number;
  packageName: string;
  bundleVersion: string;
  source: {
    repository: string;
    commit: string;
    commitSource: string;
    commitOverride: boolean;
    dirty: boolean;
  };
  build: {
    artifactSource: string;
    profile: string;
    compiler: { name: string; version: string };
    settings: {
      evmVersion: string;
      optimizerRuns: number;
      viaIR: boolean;
    };
  };
  artifacts: Record<string, ManifestArtifactRecord>;
  bundleRoot: string;
}

export interface ExportedArtifactFile {
  name: string;
  contractName: string;
  sourcePath: string;
  origin?: 'prf' | 'openzeppelin' | 'sp1';
  scopeHint: ScopeHint;
  category: Category;
  verifier?: VerifierMeta;
  abi: unknown[];
  bytecode: string;
  deployedBytecode: string;
  linkReferences: LinkReferencesMap;
  deployedLinkReferences: LinkReferencesMap;
  immutableReferences: ImmutableReferencesMap;
  metadata: string;
}
