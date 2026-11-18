import { readdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const migrationsDir = resolve(repoRoot, 'supabase/migrations');
const migrationFiles = (await readdir(migrationsDir))
  .filter((name) => /^\d+_.+\.sql$/.test(name))
  .sort((left, right) => left.localeCompare(right, 'en', { numeric: true }));

if (!migrationFiles.length) throw new Error('No numbered SQL migrations found.');

const sections = await Promise.all(migrationFiles.map(async (name) => {
  const contents = (await readFile(resolve(migrationsDir, name), 'utf8')).trimEnd();
  return `\n\n-- >>> BEGIN ${name}\n${contents}\n-- <<< END ${name}`;
}));

const header = [
  '-- GENERATED FILE. Do not edit this snapshot directly.',
  '-- Source of truth: supabase/migrations/*.sql in numeric order.',
  '-- Regenerate with: node scripts/generate-schema-unified.mjs',
  `-- Included migrations: ${migrationFiles.length}`,
].join('\n');

await writeFile(resolve(repoRoot, 'supabase/schema_unified.sql'), `${header}${sections.join('')}\n`);
console.log(`Generated supabase/schema_unified.sql from ${migrationFiles.length} migrations.`);
