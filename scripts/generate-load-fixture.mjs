#!/usr/bin/env node
/*
 * Generate deterministic synthetic Kuri-App load-test data.
 *
 * SAFETY: local-only. This script does not import Supabase clients,
 * does not read Supabase credentials, and writes a JSONL fixture only.
 */

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
function valueAfter(flag, fallback) {
  const i = args.indexOf(flag);
  return i === -1 || i + 1 >= args.length ? fallback : args[i + 1];
}

const peopleCount = Number(valueAfter('--people', '10000'));
const output = valueAfter('--output', '.tmp/kuri-load-fixture.jsonl');
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

const people = [];
for (let index = 0; index < peopleCount; index += 1) {
  const n = index + 1;
  people.push({
    synthetic_id: id('person', n),
    registered_name: 'KURI TEST ' + String(n).padStart(5, '0'),
    display_name: pick(firstNames) + ' ' + pick(lastNames) + ' ' + n,
    address: 'Synthetic load-test record',
    phone: '90000' + String(n).padStart(5, '0'),
    email: 'loadtest-' + String(n).padStart(5, '0') + '@example.invalid'
  });
}

const kuriCount = Math.min(10, Math.max(5, Math.ceil(peopleCount / 2000)));
const kuris = Array.from({ length: kuriCount }, (_, index) => {
  const n = index + 1;
  return {
    synthetic_id: id('kuri', n),
    name: 'LOAD TEST KURI ' + String(n).padStart(2, '0'),
    description: 'Synthetic local-only load-test fixture',
    number_of_cycles: 12,
    membership_limit: Math.max(3000, Math.ceil((peopleCount * 2) / kuriCount)),
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

const cycles = [];
for (const kuri of kuris) {
  for (let n = 1; n <= kuri.number_of_cycles; n += 1) {
    cycles.push({
      synthetic_id: id('cycle', cycles.length + 1),
      kuri_synthetic_id: kuri.synthetic_id,
      cycle_number: n,
      period_start: '2026-' + String(((n - 1) % 12) + 1).padStart(2, '0') + '-01',
      period_end: '2026-' + String(((n - 1) % 12) + 1).padStart(2, '0') + '-28',
      status: n <= 8 ? 'COMPLETED' : 'UPCOMING'
    });
  }
}

const membershipById = new Map(memberships.map(m => [m.synthetic_id, m]));
const cyclesByKuri = new Map();
for (const cycle of cycles) {
  const rows = cyclesByKuri.get(cycle.kuri_synthetic_id) ?? [];
  rows.push(cycle);
  cyclesByKuri.set(cycle.kuri_synthetic_id, rows);
}

const installments = [];
for (const membership of memberships) {
  for (const cycle of cyclesByKuri.get(membership.kuri_synthetic_id) ?? []) {
    const installmentIndex = installments.length + 1;
    const paid = cycle.status === 'COMPLETED' ? 1000 : 0;
    installments.push({
      synthetic_id: id('installment', installmentIndex),
      membership_synthetic_id: membership.synthetic_id,
      cycle_synthetic_id: cycle.synthetic_id,
      amount_due: 1000,
      amount_paid: paid,
      status: paid === 1000 ? 'PAID' : 'UNPAID'
    });
  }
}

const payments = [];
const paymentAllocations = [];
for (let i = 0; i < installments.length; i += 1) {
  const installment = installments[i];
  if (installment.status !== 'PAID' || i % 3 !== 0) continue;
  const paymentIndex = payments.length + 1;
  const payment = {
    synthetic_id: id('payment', paymentIndex),
    person_synthetic_id: membershipById.get(installment.membership_synthetic_id).person_synthetic_id,
    amount: 1000,
    status: 'APPROVED',
    method: ['UPI', 'BANK_TRANSFER', 'CASH'][paymentIndex % 3]
  };
  payments.push(payment);
  paymentAllocations.push({
    synthetic_id: id('allocation', paymentAllocations.length + 1),
    payment_synthetic_id: payment.synthetic_id,
    installment_synthetic_id: installment.synthetic_id,
    amount: 1000
  });
}

const nominees = [];
for (let i = 0; i < people.length; i += 4) {
  nominees.push({
    synthetic_id: id('nominee', nominees.length + 1),
    person_synthetic_id: people[i].synthetic_id,
    name: 'Synthetic Nominee ' + (i + 1),
    relationship: 'Family',
    phone: '91000' + String(i + 1).padStart(5, '0')
  });
}

const muppuRecords = [];
const cycleEightByKuri = new Map(
  cycles
    .filter(c => c.cycle_number === 8)
    .map(c => [c.kuri_synthetic_id, c])
);
for (let i = 0; i < memberships.length; i += 7) {
  const membership = memberships[i];
  const cycle = cycleEightByKuri.get(membership.kuri_synthetic_id);
  if (!cycle) continue;
  muppuRecords.push({
    synthetic_id: id('muppu', muppuRecords.length + 1),
    kuri_synthetic_id: membership.kuri_synthetic_id,
    cycle_synthetic_id: cycle.synthetic_id,
    person_synthetic_id: membership.person_synthetic_id,
    amount: 100,
    status: (i % 2 === 0) ? 'DEDUCTED' : 'PAID'
  });
}

const membershipExits = [];
const membershipExitRefundTransactions = [];
for (let i = 0; i < memberships.length; i += 100) {
  const membership = memberships[i];
  const exit = {
    synthetic_id: id('exit', membershipExits.length + 1),
    membership_synthetic_id: membership.synthetic_id,
    reason: 'VOLUNTARY_EXIT',
    refund_policy: 'AT_MATURITY',
    amount_contributed: 8000,
    refund_amount: 8000,
    status: 'SETTLED'
  };
  membershipExits.push(exit);

  if (i % 200 === 0) {
    membershipExitRefundTransactions.push({
      synthetic_id: id('refund', membershipExitRefundTransactions.length + 1),
      membership_exit_synthetic_id: exit.synthetic_id,
      amount: 8000,
      payment_method: 'BANK_TRANSFER'
    });
  }
}

const exitedMembershipIds = new Set(membershipExits.map(e => e.membership_synthetic_id));
const drawSessions = [];
const drawPoolEntries = [];
const drawSelections = [];
const monthlyWinners = [];
const monthlyWinnerMemberships = [];
const payouts = [];

for (const cycle of cycles.filter(c => c.status === 'COMPLETED')) {
  const kuriMemberships = memberships.filter(m => m.kuri_synthetic_id === cycle.kuri_synthetic_id);
  const drawNumber = drawSessions.length + 1;
  const draw = {
    synthetic_id: id('draw', drawNumber),
    kuri_synthetic_id: cycle.kuri_synthetic_id,
    cycle_synthetic_id: cycle.synthetic_id,
    status: 'FINALIZED'
  };
  drawSessions.push(draw);

  const pool = kuriMemberships.filter(
    (membership, index) =>
      !exitedMembershipIds.has(membership.synthetic_id) &&
      index % 3 === cycle.cycle_number % 3
  );

  for (const membership of pool) {
    drawPoolEntries.push({
      synthetic_id: id('pool', drawPoolEntries.length + 1),
      draw_synthetic_id: draw.synthetic_id,
      membership_synthetic_id: membership.synthetic_id,
      system_eligible: true,
      admin_included: true
    });
  }

  const winnerMembership = pool[0];
  if (!winnerMembership) continue;

  drawSelections.push({
    synthetic_id: id('selection', drawSelections.length + 1),
    draw_synthetic_id: draw.synthetic_id,
    membership_synthetic_id: winnerMembership.synthetic_id,
    selection_order: 1
  });

  const winner = {
    synthetic_id: id('winner', monthlyWinners.length + 1),
    cycle_synthetic_id: cycle.synthetic_id,
    person_synthetic_id: winnerMembership.person_synthetic_id
  };
  monthlyWinners.push(winner);

  monthlyWinnerMemberships.push({
    synthetic_id: id('winner-membership', monthlyWinnerMemberships.length + 1),
    monthly_winner_synthetic_id: winner.synthetic_id,
    membership_synthetic_id: winnerMembership.synthetic_id,
    award_amount: 100000
  });

  payouts.push({
    synthetic_id: id('payout', payouts.length + 1),
    monthly_winner_synthetic_id: winner.synthetic_id,
    gross_amount: 100000,
    muppu_amount: 0,
    other_deductions: 0,
    net_amount: 100000,
    status: 'PAID'
  });
}

const counts = {
  people: people.length,
  kuris: kuris.length,
  cycles: cycles.length,
  memberships: memberships.length,
  installments: installments.length,
  payments: payments.length,
  payment_allocations: paymentAllocations.length,
  nominees: nominees.length,
  muppu_records: muppuRecords.length,
  draw_sessions: drawSessions.length,
  draw_pool_entries: drawPoolEntries.length,
  draw_selections: drawSelections.length,
  monthly_winners: monthlyWinners.length,
  monthly_winner_memberships: monthlyWinnerMemberships.length,
  payouts: payouts.length,
  membership_exits: membershipExits.length,
  membership_exit_refund_transactions: membershipExitRefundTransactions.length
};

const organization = {
  synthetic_id: 'organization-load-test',
  name: 'Kuri-App LOCAL LOAD TEST'
};

const outputPath = path.resolve(output);
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
const out = fs.createWriteStream(outputPath, { encoding: 'utf8' });

const writeLine = (value) => {
  if (!out.write(JSON.stringify(value) + '\n')) {
    return new Promise(resolve => out.once('drain', resolve));
  }
  return Promise.resolve();
};

await writeLine({
  type: 'meta',
  schema_version: 3,
  generator: 'kuri-app-local-load-fixture',
  generated_at: new Date().toISOString(),
  seed,
  target: { people: peopleCount, maximum_supported_people: 20000 },
  safety: { local_only: true, hosted_supabase_mutation: false, contains_real_person_data: false },
  organization,
  counts,
  notes: ['Synthetic fixture only.', 'Do not upload to production.', 'This fixture is generated locally.']
});

for (const [type, rows] of [
  ['organization_records', [organization]],
  ['kuris', kuris],
  ['people', people],
  ['memberships', memberships],
  ['cycles', cycles],
  ['installments', installments],
  ['payments', payments],
  ['paymentAllocations', paymentAllocations],
  ['nominees', nominees],
  ['muppuRecords', muppuRecords],
  ['drawSessions', drawSessions],
  ['drawPoolEntries', drawPoolEntries],
  ['drawSelections', drawSelections],
  ['monthlyWinners', monthlyWinners],
  ['monthlyWinnerMemberships', monthlyWinnerMemberships],
  ['payouts', payouts],
  ['membershipExits', membershipExits],
  ['membershipExitRefundTransactions', membershipExitRefundTransactions]
]) {
  for (const row of rows) {
    await writeLine({ type, row });
  }
}

await new Promise((resolve, reject) => {
  out.once('error', reject);
  out.end(resolve);
});

console.log(JSON.stringify({ output: outputPath, format: 'jsonl', counts, seed, hosted_supabase_mutation: false }, null, 2));
