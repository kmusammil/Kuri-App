#!/usr/bin/env node
/*
 * Run the canonical Kuri-App pgTAP suites against the existing isolated supabase-local database.
 * The local stack may have been loaded separately, so this runner stages only the
 * test files and deliberately does not reset the database.
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const root = process.cwd();
const localDir = path.join(root, 'supabase-local');
const canonicalDir = path.join(root, 'supabase', 'tests');
const stagedDir = path.join(localDir, 'supabase', 'tests');
const canonicalMigrationsDir = path.join(root, 'supabase', 'migrations');
const localSupabaseDir = path.join(localDir, 'supabase');
const localMigrationsDir = path.join(localSupabaseDir, 'migrations');

if (!fs.existsSync(localDir)) {
  throw new Error('Local Supabase workspace not found: ./supabase-local');
}
if (!fs.existsSync(canonicalDir)) {
  throw new Error('Canonical pgTAP test directory not found: ./supabase/tests');
}
if (!fs.existsSync(localSupabaseDir)) {
  throw new Error('Local Supabase metadata directory not found: ./supabase-local/supabase');
}
if (!fs.existsSync(canonicalMigrationsDir)) {
  throw new Error('Canonical migrations directory not found: ./supabase/migrations');
}

// The load command mirrors canonical migrations before rebuilding the database.
// Refuse to test when the local workspace is missing that schema.
if (!fs.existsSync(localMigrationsDir) || fs.readdirSync(localMigrationsDir).filter(x => x.endsWith('.sql')).length === 0) {
  throw new Error('Local Kuri-App migrations are missing. Run npm run test:load-fixture:local first.');
}

const files = fs.readdirSync(canonicalDir).filter(name => name.endsWith('.test.sql'));
if (files.length === 0) throw new Error('No canonical pgTAP .test.sql files found.');

fs.mkdirSync(stagedDir, { recursive: true });
const created = [];

for (const name of files) {
  const src = path.join(canonicalDir, name);
  const dst = path.join(stagedDir, name);
  if (fs.existsSync(dst)) throw new Error(`Refusing to overwrite existing local test: ${dst}`);
  fs.copyFileSync(src, dst);
  created.push(dst);
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const isWindows = process.platform === 'win32';
    const executable = isWindows ? (process.env.ComSpec || 'cmd.exe') : command;
    const executableArgs = isWindows
      ? ['/d', '/s', '/c', [command, ...args].map(String).join(' ')]
      : args;
    const child = spawn(executable, executableArgs, {
      cwd: root,
      shell: false,
      windowsHide: true,
      stdio: 'inherit',
    });
    child.once('error', reject);
    child.once('close', code => {
      if (code === 0) resolve();
      else reject(new Error(`Supabase DB tests failed with exit code ${code}`));
    });
  });
}

try {
  await run('npx', [
    'supabase', 'test', 'db', '--workdir', 'supabase-local'
  ]);
} finally {
  for (const file of created) {
    fs.rmSync(file, { force: true });
  }
  try {
    if (fs.existsSync(stagedDir) && fs.readdirSync(stagedDir).length === 0) {
      fs.rmdirSync(stagedDir);
    }
  } catch {}
}
