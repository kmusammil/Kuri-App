#!/usr/bin/env node
/*
 * Generate deterministic synthetic Kuri-App load-test data.
 *
 * SAFETY: local-only. This script does not import Supabase clients,
 * does not read Supabase credentials, and writes a JSON fixture only.
 */

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
function valueAfter(flag, fallback) {
  const i = args.indexOf(flag);
  return i === -1 || i + 1 >= args.length ? fallback : args[i + 1];
}

const peopleCount = Number(valueAfter('--people', '10000'));
const output = valueAfter('--output', '.tmp/kuri-load-fixture.json');
const seed = Number(valueAfter('--seed', '20260921'));

if (!Number.isInteger(peopleCount) || peopleCount < 1 || peopleCount > 20000) {
  throw new Error('--people must be an integer between 1 and 20000.');
}
if (!Number.isInteger(seed)) throw new Error('--seed must be an integer.');

function mulberry32(initial) {
  let state = initial >>> 0;
  return () => {
    state |= 0;
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const random = mulberry32(seed);
const id = (prefix, n) => prefix + '-' + String(n).padStart(6, '0');
const pick = (items) => items[Math.floor(random() * items.length)];

const firstNames = ['Test', 'Sample', 'Demo', 'Load', 'Synthetic', 'Fixture', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Kuri'];
const lastNames = ['Person', 'Member', 'User', 'Record', 'Account', 'Holder'];

const people = Array.from({ length: peopleCount }, (_, index) => {
  const n = index + 1;
  return {
    synthetic_id: id('person', n),
    registered_name: 'KURI TEST ' + String(n).padStart(5, '0'),
    display_name: pick(firstNames) + ' ' + pick(lastNames) + ' ' + n,
    address: 'Synthetic load-test record',
    phone: '90000' + String(n).padStart(5, '0'),
    email: 'loadtest-' + String(n).padStart(5, '0') + '@example.invalid'
  };
});

const kuriCount = Math.min(10, Math.max(5, Math.ceil(peopleCount / 2000)));
const kuris = Array.from({ length: kuriCount }, (_, index) => {
  const n = index + 1;
  return {
    synthetic_id: id('kuri', n),
    name: 'LOAD TEST KURI ' + String(n).padStart(2, '0'),
    description: 'Synthetic local-only load-test fixture',
    number_of_cycles: 12,
    membership_limit: Math.max(1000, Math.ceil(peopleCount / kuriCount)),
    installment_amount: 1000,
    gross_prize_amount: 100000,
    muppu_amount: 0
  };
});

const memberships = [];
let membershipNumber = 1;
for (let i = 0; i < people.length; i += 1) {
  const count = random() < 0.65 ? 1 : 2;
  for (let copy = 0; copy < count; copy += 1) {
    const kuri = kuris[(i + copy) % kuris.length];
    memberships.push({
      synthetic_id: id('membership', membershipNumber),
      person_synthetic_id: people[i].synthetic_id,
      kuri_synthetic_id: kuri.synthetic_id,
      membership_number: membershipNumber
    });
    membershipNumber += 1;
  }
}

const fixture = {
  schema_version: 1,
  generator: 'kuri-app-local-load-fixture',
  generated_at: new Date().toISOString(),
  seed,
  target: { people: peopleCount, maximum_supported_people: 20000 },
  safety: { local_only: true, hosted_supabase_mutation: false, contains_real_person_data: false },
  organization: { synthetic_id: 'organization-load-test', name: 'Kuri-App LOCAL LOAD TEST' },
  kuris,
  people,
  memberships,
  notes: ['Synthetic fixture only.', 'Do not upload to production.', 'Dependent financial/draw records will be added in later fixture stages.']
};

const outputPath = path.resolve(output);
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, JSON.stringify(fixture, null, 2) + '\n', 'utf8');

console.log(JSON.stringify({ output: outputPath, people: people.length, memberships: memberships.length, kuris: kuris.length, seed, hosted_supabase_mutation: false }, null, 2));
