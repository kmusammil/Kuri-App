#!/usr/bin/env node
/*
 * Validate a locally generated Kuri-App load-test fixture.
 *
 * SAFETY: local-only. This script reads JSON and never connects to Supabase.
 */

import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
function valueAfter(flag, fallback) {
  const i = args.indexOf(flag);
  return i === -1 || i + 1 >= args.length ? fallback : args[i + 1];
}

const input = path.resolve(valueAfter('--input', '.tmp/kuri-load-fixture.json'));
const fail = (message) => {
  throw new Error(message);
};

if (!fs.existsSync(input)) fail('Fixture not found: ' + input);

const fixture = JSON.parse(fs.readFileSync(input, 'utf8'));
const errors = [];
const check = (condition, message) => {
  if (!condition) errors.push(message);
};
const array = (name) => {
  const value = fixture[name];
  check(Array.isArray(value), name + ' must be an array');
  return Array.isArray(value) ? value : [];
};
const uniqueIds = (name, rows) => {
  const seen = new Set();
  for (const row of rows) {
    const id = row?.synthetic_id;
    check(typeof id === 'string' && id.length > 0, name + ': missing synthetic_id');
    if (id) check(!seen.has(id), name + ': duplicate synthetic_id ' + id);
    if (id) seen.add(id);
  }
};

const people = array('people');
const kuris = array('kuris');
const memberships = array('memberships');
const cycles = array('cycles');
const installments = array('installments');
const payments = array('payments');
const allocations = array('paymentAllocations');
const nominees = array('nominees');
const muppu = array('muppuRecords');
const draws = array('drawSessions');
const pool = array('drawPoolEntries');
const selections = array('drawSelections');
const winners = array('monthlyWinners');
const winnerMemberships = array('monthlyWinnerMemberships');
const payouts = array('payouts');
const exits = array('membershipExits');
const refunds = array('membershipExitRefundTransactions');

const byId = (rows) => new Map(rows.map((row) => [row.synthetic_id, row]));
const peopleById = byId(people);
const kurisById = byId(kuris);
const membershipsById = byId(memberships);
const cyclesById = byId(cycles);
const installmentsById = byId(installments);
const paymentsById = byId(payments);
const drawsById = byId(draws);
const poolById = byId(pool);
const winnersById = byId(winners);
const exitsById = byId(exits);

for (const [name, rows] of [
  ['people', people], ['kuris', kuris], ['memberships', memberships], ['cycles', cycles],
  ['installments', installments], ['payments', payments], ['paymentAllocations', allocations],
  ['nominees', nominees], ['muppuRecords', muppu], ['drawSessions', draws],
  ['drawPoolEntries', pool], ['drawSelections', selections], ['monthlyWinners', winners],
  ['monthlyWinnerMemberships', winnerMemberships], ['payouts', payouts],
  ['membershipExits', exits], ['membershipExitRefundTransactions', refunds]
]) uniqueIds(name, rows);

check(fixture?.safety?.local_only === true, 'fixture safety.local_only must be true');
check(fixture?.safety?.hosted_supabase_mutation === false, 'fixture safety.hosted_supabase_mutation must be false');
check(fixture?.safety?.contains_real_person_data === false, 'fixture must declare no real person data');

for (const person of people) {
  check(person.email?.endsWith('@example.invalid'), 'person has non-synthetic email: ' + person.synthetic_id);
}

for (const kuri of kuris) {
  check(Number.isInteger(kuri.membership_limit) && kuri.membership_limit > 0, 'invalid membership_limit: ' + kuri.synthetic_id);
}

for (const membership of memberships) {
  check(peopleById.has(membership.person_synthetic_id), 'membership references missing person: ' + membership.synthetic_id);
  check(kurisById.has(membership.kuri_synthetic_id), 'membership references missing Kuri: ' + membership.synthetic_id);
}

const membershipsByKuri = new Map();
const membershipsByPerson = new Map();
for (const membership of memberships) {
  if (!membershipsByKuri.has(membership.kuri_synthetic_id)) membershipsByKuri.set(membership.kuri_synthetic_id, []);
  membershipsByKuri.get(membership.kuri_synthetic_id).push(membership);
  if (!membershipsByPerson.has(membership.person_synthetic_id)) membershipsByPerson.set(membership.person_synthetic_id, []);
  membershipsByPerson.get(membership.person_synthetic_id).push(membership);
}
for (const kuri of kuris) {
  check((membershipsByKuri.get(kuri.synthetic_id) ?? []).length <= kuri.membership_limit,
    'Kuri membership limit exceeded: ' + kuri.synthetic_id);
}

const cyclesByKuri = new Map();
for (const cycle of cycles) {
  check(kurisById.has(cycle.kuri_synthetic_id), 'cycle references missing Kuri: ' + cycle.synthetic_id);
  if (!cyclesByKuri.has(cycle.kuri_synthetic_id)) cyclesByKuri.set(cycle.kuri_synthetic_id, []);
  cyclesByKuri.get(cycle.kuri_synthetic_id).push(cycle);
}
for (const kuri of kuris) {
  const rows = cyclesByKuri.get(kuri.synthetic_id) ?? [];
  check(rows.length === kuri.number_of_cycles, 'wrong cycle count for Kuri: ' + kuri.synthetic_id);
  check(new Set(rows.map((c) => c.cycle_number)).size === rows.length, 'duplicate cycle_number for Kuri: ' + kuri.synthetic_id);
}

const installmentKeySet = new Set();
for (const installment of installments) {
  const membership = membershipsById.get(installment.membership_synthetic_id);
  const cycle = cyclesById.get(installment.cycle_synthetic_id);
  check(Boolean(membership), 'installment references missing membership: ' + installment.synthetic_id);
  check(Boolean(cycle), 'installment references missing cycle: ' + installment.synthetic_id);
  if (membership && cycle) {
    check(membership.kuri_synthetic_id === cycle.kuri_synthetic_id,
      'installment crosses Kuri boundary: ' + installment.synthetic_id);
    const key = membership.synthetic_id + '|' + cycle.synthetic_id;
    check(!installmentKeySet.has(key), 'duplicate membership/cycle installment: ' + key);
    installmentKeySet.add(key);
    check(installment.amount_paid >= 0 && installment.amount_paid <= installment.amount_due,
      'invalid installment paid amount: ' + installment.synthetic_id);
    check((installment.status === 'PAID') === (installment.amount_paid === installment.amount_due),
      'installment status/amount mismatch: ' + installment.synthetic_id);
  }
}
const installmentsByMembership = new Map();
for (const installment of installments) {
  const key = installment.membership_synthetic_id;
  installmentsByMembership.set(key, (installmentsByMembership.get(key) ?? 0) + 1);
}
for (const membership of memberships) {
  const expected = (cyclesByKuri.get(membership.kuri_synthetic_id) ?? []).length;
  const actual = installmentsByMembership.get(membership.synthetic_id) ?? 0;
  check(actual === expected, 'wrong installment count for membership: ' + membership.synthetic_id);
}

for (const payment of payments) {
  check(peopleById.has(payment.person_synthetic_id), 'payment references missing person: ' + payment.synthetic_id);
  check(payment.amount > 0, 'payment amount must be positive: ' + payment.synthetic_id);
}
const allocationByPayment = new Map();
const allocationByInstallment = new Map();
for (const allocation of allocations) {
  const payment = paymentsById.get(allocation.payment_synthetic_id);
  const installment = installmentsById.get(allocation.installment_synthetic_id);
  check(Boolean(payment), 'allocation references missing payment: ' + allocation.synthetic_id);
  check(Boolean(installment), 'allocation references missing installment: ' + allocation.synthetic_id);
  if (payment && installment) {
    check(allocation.amount > 0, 'allocation amount must be positive: ' + allocation.synthetic_id);
    const paymentTotal = (allocationByPayment.get(payment.synthetic_id) ?? 0) + allocation.amount;
    const installmentTotal = (allocationByInstallment.get(installment.synthetic_id) ?? 0) + allocation.amount;
    allocationByPayment.set(payment.synthetic_id, paymentTotal);
    allocationByInstallment.set(installment.synthetic_id, installmentTotal);
  }
}
for (const [paymentId, total] of allocationByPayment) {
  check(total <= paymentsById.get(paymentId).amount, 'payment over-allocated: ' + paymentId);
}
for (const [installmentId, total] of allocationByInstallment) {
  check(total <= installmentsById.get(installmentId).amount_due, 'installment over-allocated: ' + installmentId);
}
for (const payment of payments) {
  check(allocationByPayment.has(payment.synthetic_id), 'payment has no allocation: ' + payment.synthetic_id);
}

for (const nominee of nominees) {
  check(peopleById.has(nominee.person_synthetic_id), 'nominee references missing person: ' + nominee.synthetic_id);
}

for (const record of muppu) {
  const cycle = cyclesById.get(record.cycle_synthetic_id);
  check(kurisById.has(record.kuri_synthetic_id), 'Muppu references missing Kuri: ' + record.synthetic_id);
  check(Boolean(cycle), 'Muppu references missing cycle: ' + record.synthetic_id);
  check(peopleById.has(record.person_synthetic_id), 'Muppu references missing person: ' + record.synthetic_id);
  if (cycle) check(cycle.kuri_synthetic_id === record.kuri_synthetic_id, 'Muppu Kuri/cycle mismatch: ' + record.synthetic_id);
  const personMemberships = membershipsByPerson.get(record.person_synthetic_id) ?? [];
  check(personMemberships.some((m) => m.kuri_synthetic_id === record.kuri_synthetic_id),
    'Muppu person has no membership in Kuri: ' + record.synthetic_id);
}

const poolKeys = new Set();
for (const entry of pool) {
  const draw = drawsById.get(entry.draw_synthetic_id);
  const membership = membershipsById.get(entry.membership_synthetic_id);
  check(Boolean(draw), 'pool entry references missing draw: ' + entry.synthetic_id);
  check(Boolean(membership), 'pool entry references missing membership: ' + entry.synthetic_id);
  if (draw && membership) {
    const cycle = cyclesById.get(draw.cycle_synthetic_id);
    check(Boolean(cycle), 'draw references missing cycle: ' + draw.synthetic_id);
    if (cycle) {
      check(cycle.kuri_synthetic_id === membership.kuri_synthetic_id, 'draw pool crosses Kuri boundary: ' + entry.synthetic_id);
    }
    const key = draw.synthetic_id + '|' + membership.synthetic_id;
    check(!poolKeys.has(key), 'duplicate draw pool membership: ' + key);
    poolKeys.add(key);
  }
}
const drawCycleKeys = new Set();
for (const draw of draws) {
  const cycle = cyclesById.get(draw.cycle_synthetic_id);
  check(Boolean(cycle), 'draw references missing cycle: ' + draw.synthetic_id);
  if (cycle) {
    check(cycle.kuri_synthetic_id === draw.kuri_synthetic_id, 'draw Kuri/cycle mismatch: ' + draw.synthetic_id);
    const key = draw.kuri_synthetic_id + '|' + draw.cycle_synthetic_id;
    check(!drawCycleKeys.has(key), 'duplicate draw for cycle: ' + key);
    drawCycleKeys.add(key);
  }
}
const poolKeySet = new Set(pool.map((row) => row.draw_synthetic_id + '|' + row.membership_synthetic_id));
for (const selection of selections) {
  const draw = drawsById.get(selection.draw_synthetic_id);
  const key = selection.draw_synthetic_id + '|' + selection.membership_synthetic_id;
  check(Boolean(draw), 'selection references missing draw: ' + selection.synthetic_id);
  check(poolKeySet.has(key), 'selection references membership outside draw pool: ' + selection.synthetic_id);
}
const winnerMembershipsByWinner = new Map();
for (const row of winnerMemberships) {
  if (!winnerMembershipsByWinner.has(row.monthly_winner_synthetic_id)) {
    winnerMembershipsByWinner.set(row.monthly_winner_synthetic_id, []);
  }
  winnerMembershipsByWinner.get(row.monthly_winner_synthetic_id).push(row);
}
for (const winner of winners) {
  const winnerMembershipRows = winnerMembershipsByWinner.get(winner.synthetic_id) ?? [];
  check(winnerMembershipRows.length === 1, 'winner must have exactly one linked membership: ' + winner.synthetic_id);
  check(peopleById.has(winner.person_synthetic_id), 'winner references missing person: ' + winner.synthetic_id);
  for (const row of winnerMembershipRows) {
    const membership = membershipsById.get(row.membership_synthetic_id);
    check(Boolean(membership), 'winner membership references missing membership: ' + row.synthetic_id);
    if (membership) check(membership.person_synthetic_id === winner.person_synthetic_id, 'winner/person membership mismatch: ' + row.synthetic_id);
  }
}
for (const payout of payouts) {
  const winner = winnersById.get(payout.monthly_winner_synthetic_id);
  check(Boolean(winner), 'payout references missing winner: ' + payout.synthetic_id);
  check(payout.net_amount === Math.max(payout.gross_amount - payout.muppu_amount - payout.other_deductions, 0),
    'payout net invariant failed: ' + payout.synthetic_id);
}

for (const exit of exits) {
  check(membershipsById.has(exit.membership_synthetic_id), 'exit references missing membership: ' + exit.synthetic_id);
  check(exit.refund_amount <= exit.amount_contributed, 'exit refund exceeds contribution: ' + exit.synthetic_id);
}
for (const refund of refunds) {
  const exit = exitsById.get(refund.membership_exit_synthetic_id);
  check(Boolean(exit), 'refund references missing exit: ' + refund.synthetic_id);
  if (exit) check(refund.amount <= exit.refund_amount, 'refund exceeds exit refund amount: ' + refund.synthetic_id);
}

for (const [name, expected] of Object.entries(fixture.counts ?? {})) {
  const actual = ({
    people: people.length, kuris: kuris.length, cycles: cycles.length, memberships: memberships.length,
    installments: installments.length, payments: payments.length, payment_allocations: allocations.length,
    nominees: nominees.length, muppu_records: muppu.length, draw_sessions: draws.length,
    draw_pool_entries: pool.length, draw_selections: selections.length, monthly_winners: winners.length,
    monthly_winner_memberships: winnerMemberships.length, payouts: payouts.length, membership_exits: exits.length,
    membership_exit_refund_transactions: refunds.length
  })[name];
  check(actual === expected, 'count mismatch for ' + name + ': expected ' + expected + ', got ' + actual);
}

if (errors.length) {
  console.error('LOAD FIXTURE VALIDATION: FAIL');
  for (const error of errors) console.error('- ' + error);
  process.exit(1);
}

console.log(JSON.stringify({
  result: 'PASS',
  input,
  checks: {
    people: people.length,
    kuris: kuris.length,
    cycles: cycles.length,
    memberships: memberships.length,
    installments: installments.length,
    payments: payments.length,
    payment_allocations: allocations.length,
    nominees: nominees.length,
    muppu_records: muppu.length,
    draw_sessions: draws.length,
    draw_pool_entries: pool.length,
    draw_selections: selections.length,
    monthly_winners: winners.length,
    monthly_winner_memberships: winnerMemberships.length,
    payouts: payouts.length,
    membership_exits: exits.length,
    membership_exit_refund_transactions: refunds.length
  },
  hosted_supabase_mutation: false
}, null, 2));
