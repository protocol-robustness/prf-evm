#!/usr/bin/env ts-node
/**
 * Validate an exported deployables bundle.
 *
 * Usage:
 *   pnpm deployables:validate
 *   pnpm deployables:validate -- <export-dir>
 */
import { validateDeployables } from './_lib/deployables/validate';
import { DEFAULT_EXPORT_DIR } from './_lib/deployables/export';

function main(): void {
  const explicit = process.argv[2];
  const exportDir = explicit && !explicit.startsWith('-') ? explicit : DEFAULT_EXPORT_DIR;
  const issues = validateDeployables({ exportDir });
  console.log(`✅ Deployables validated (${issues.length} artifact(s) OK): ${exportDir}`);
}

main();
