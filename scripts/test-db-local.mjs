#!/usr/bin/env node
/*
 * Run the canonical Kuri-App pgTAP suites against the isolated supabase-local stack.
 * The repository keeps the canonical tests under ./supabase/tests while the local
 * Supabase workspace is ./supabase-local. Tests are staged temporarily into the
 * workspace expected by the CLI and removed afterwards.
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const root = process.cwd();
const localDir = path.join(root, 'supabase-local');
const canonicalDir = path.join(root, 'supabase', 'tests');
const stagedDir = path.join(localDir, 'supabase', 'tests');

if (!fs.existsSync(localDir)) {
  throw new Error('Local Supabase workspace not found: ./supabase-local');
}
if (!fs.existsSync(canonicalDir)) {
  throw new Error('Canonical pgTAP test directory not found: ./supabase/tests');
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
    const child = spawn(command, args, {
      cwd: root,
      shell: process.platform === 'win32',
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
