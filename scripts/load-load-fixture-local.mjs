#!/usr/bin/env node
/*
 * Load the synthetic Kuri-App fixture into the isolated local Supabase database.
 *
 * SAFETY:
 * - Refuses non-local Docker/Supabase targets.
 * - Never reads Supabase hosted credentials.
 * - Never uses the Supabase network API.
 * - Intended only for the local stack started with:
 *     npx supabase start --workdir supabase-local
 *
 * Usage:
 *   node scripts/load-load-fixture-local.mjs
 *   node scripts/load-load-fixture-local.mjs --fixture .tmp/kuri-load-fixture.json
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const args = process.argv.slice(2);
const valueAfter = (flag, fallback) => {
  const i = args.indexOf(flag);
  return i === -1 || i + 1 >= args.length ? fallback : args[i + 1];
};

const fixturePath = path.resolve(valueAfter('--fixture', '.tmp/kuri-load-fixture.json'));
if (!fs.existsSync(fixturePath)) throw new Error(`Fixture not found: ${fixturePath}`);

const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
if (fixture?.safety?.local_only !== true || fixture?.safety?.hosted_supabase_mutation !== false) {
  throw new Error('Refusing fixture without the expected local-only safety markers.');
}

const people = fixture.people ?? [];
const kuris = fixture.kuris ?? [];
const memberships = fixture.memberships ?? [];
const cycles = fixture.cycles ?? [];
const installments = fixture.installments ?? [];
const payments = fixture.payments ?? [];
const allocations = fixture.paymentAllocations ?? [];
const nominees = fixture.nominees ?? [];
const muppu = fixture.muppuRecords ?? [];
const draws = fixture.drawSessions ?? [];
const pools = fixture.drawPoolEntries ?? [];
const selections = fixture.drawSelections ?? [];
const winners = fixture.monthlyWinners ?? [];
const winnerMemberships = fixture.monthlyWinnerMemberships ?? [];
const payouts = fixture.payouts ?? [];
const exits = fixture.membershipExits ?? [];
const refunds = fixture.membershipExitRefundTransactions ?? [];

const syntheticOrg = fixture.organization?.synthetic_id ?? 'organization-load-test';
const actorId = '(SELECT id FROM public.users ORDER BY id LIMIT 1)';

function sh(value) {
  return "'" + String(value ?? '').replaceAll("'", "''") + "'";
}
function nullable(value) {
  return value == null ? 'NULL' : sh(value);
}
function bool(value) {
  function uuid(seed) {
  // Deterministic UUID using SHA-256 so distinct seeds do not collapse at 32 hex characters.
  // PostgreSQL only requires a valid UUID here; determinism is required for reproducible fixture references.
  const value = crypto.createHash('sha256').update(String(seed), 'utf8').digest('hex').slice(0, 32);
  return "'" + value.slice(0,8) + "-" + value.slice(8,12) + "-" + value.slice(12,16) + "-" + value.slice(16,20) + "-" + value.slice(20,32) + "'";
}(16,20)}-${hex.slice(20,32)}'`;
}

const orgId = uuid(syntheticOrg);
const maps = {
  people: new Map(people.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  kuris: new Map(kuris.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  memberships: new Map(memberships.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  cycles: new Map(cycles.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  installments: new Map(installments.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  payments: new Map(payments.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  allocations: new Map(allocations.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  nominees: new Map(nominees.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  muppu: new Map(muppu.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  draws: new Map(draws.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  pools: new Map(pools.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  selections: new Map(selections.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  winners: new Map(winners.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  winnerMemberships: new Map(winnerMemberships.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  payouts: new Map(payouts.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  exits: new Map(exits.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
  refunds: new Map(refunds.map(x => [x.synthetic_id, uuid(x.synthetic_id)])),
};

const idOf = (kind, syntheticId) => {
  const value = maps[kind]?.get(syntheticId);
  if (!value) throw new Error(`Missing ${kind} mapping for ${syntheticId}`);
  return value;
};

const exitedMemberships = new Set(exits.map(x => x.membership_synthetic_id));

function insertBatches(table, columns, rows, batchSize = 250) {
  const statements = [];
  for (let i = 0; i < rows.length; i += batchSize) {
    const batch = rows.slice(i, i + batchSize);
    if (!batch.length) continue;
    statements.push(
      `INSERT INTO public.${table} (${columns.join(',')}) VALUES\n` +
      batch.map(row => '  (' + row.join(',') + ')').join(',\n') + ';'
    );
  }
  return statements;
}

const sql = [];
sql.push('BEGIN;');
sql.push(`INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)\nVALUES ('00000000-0000-0000-0000-000000000099', 'authenticated', 'authenticated', 'kuri-load-fixture@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb, now(), now())\nON CONFLICT (id) DO NOTHING;`);
sql.push(`DO $fixture$ BEGIN IF NOT EXISTS (SELECT 1 FROM public.users) THEN RAISE EXCEPTION 'No local public.users row exists after deterministic Auth bootstrap.'; END IF; END $fixture$;`);
sql.push("SET LOCAL synchronous_commit = off;");
sql.push("SET LOCAL statement_timeout = 0;");
sql.push(`TRUNCATE TABLE public.audit_logs, public.membership_exit_refund_transactions, public.payouts, public.monthly_winner_memberships, public.monthly_winners, public.draw_selections, public.draw_pool_entries, public.draw_sessions, public.muppu_records, public.membership_exits, public.payment_allocations, public.payments, public.nominees, public.installments, public.memberships, public.cycles, public.kuris, public.person_emails, public.person_phones, public.people, public.organization_users, public.organizations CASCADE;`);

sql.push(...insertBatches('organizations',
  ['id','name','description','email','created_at','updated_at'],
  [[orgId, sh(fixture.organization?.name ?? 'Kuri-App LOCAL LOAD TEST'), sh('Synthetic local-only load-test organization'), sh('loadtest@example.invalid'), 'now()','now()']]
));

sql.push(...insertBatches('people',
  ['id','registered_name','display_name','address','notes','organization_id'],
  people.map(p => [
    maps.people.get(p.synthetic_id), sh(p.registered_name), nullable(p.display_name),
    nullable(p.address), sh('Synthetic local load-test record'), orgId
  ])
));

sql.push(...insertBatches('person_emails',
  ['id','person_id','email','label','is_primary'],
  people.map(p => [uuid('email:' + p.synthetic_id), maps.people.get(p.synthetic_id), sh(p.email), sh('primary'), 'true'])
));

sql.push(...insertBatches('person_phones',
  ['id','person_id','phone_number','label','is_primary'],
  people.map(p => [uuid('phone:' + p.synthetic_id), maps.people.get(p.synthetic_id), sh(p.phone), sh('primary'), 'true'])
));

sql.push(...insertBatches('kuris',
  ['id','organization_id','name','description','start_date','number_of_cycles','membership_limit','installment_amount','frequency','due_day','draw_day','gross_prize_amount','muppu_amount','draw_eligibility_rule','winner_rule','exit_refund_rule','status'],
  kuris.map(k => [
    maps.kuris.get(k.synthetic_id), orgId, sh(k.name), nullable(k.description), sh('2026-01-01'),
    k.number_of_cycles, k.membership_limit, k.installment_amount, sh('MONTHLY'), 10, 20,
    k.gross_prize_amount, k.muppu_amount ?? 0, sh('PAID_INSTALLMENT'), sh('ALL_PERSON_MEMBERSHIPS'),
    sh('AT_MATURITY'), sh('ACTIVE')
  ])
));

sql.push(...insertBatches('cycles',
  ['id','kuri_id','cycle_number','period_start','period_end','due_date','draw_date','status'],
  cycles.map(c => [
    maps.cycles.get(c.synthetic_id), idOf('kuris', c.kuri_synthetic_id), c.cycle_number,
    sh(c.period_start), sh(c.period_end), sh(c.period_end), sh(c.period_end), sh(c.status)
  ])
));

sql.push(...insertBatches('memberships',
  ['id','kuri_id','person_id','membership_number','status','joined_at','exited_at'],
  memberships.map(m => [
    maps.memberships.get(m.synthetic_id), idOf('kuris', m.kuri_synthetic_id),
    idOf('people', m.person_synthetic_id), sh(String(m.membership_number)),
    sh(exitedMemberships.has(m.synthetic_id) ? 'EXITED' : 'ACTIVE'),
    sh('2026-01-01T00:00:00Z'),
    exitedMemberships.has(m.synthetic_id) ? sh('2026-08-01T00:00:00Z') : 'NULL'
  ])
));

sql.push(...insertBatches('installments',
  ['id','membership_id','cycle_id','amount_due','amount_paid','status','due_date'],
  installments.map(i => {
    const cycle = cycles.find(c => c.synthetic_id === i.cycle_synthetic_id);
    return [
      maps.installments.get(i.synthetic_id), idOf('memberships', i.membership_synthetic_id),
      idOf('cycles', i.cycle_synthetic_id), i.amount_due, i.amount_paid,
      sh(i.status), sh(cycle.period_end)
    ];
  })
));

sql.push(...insertBatches('payments',
  ['id','person_id','amount','payment_date','method','reference_number','status','submitted_at','verified_at','notes','organization_id'],
  payments.map(p => [
    maps.payments.get(p.synthetic_id), idOf('people', p.person_synthetic_id), p.amount,
    sh('2026-08-15T10:00:00Z'), sh(p.method), sh('LOAD-' + p.synthetic_id),
    sh('APPROVED'), sh('2026-08-15T10:00:00Z'), sh('2026-08-15T10:00:00Z'),
    sh('Synthetic local load-test payment'), orgId
  ])
));

sql.push(...insertBatches('payment_allocations',
  ['id','payment_id','installment_id','amount'],
  allocations.map(a => [
    maps.allocations.get(a.synthetic_id), idOf('payments', a.payment_synthetic_id),
    idOf('installments', a.installment_synthetic_id), a.amount
  ])
));

sql.push(...insertBatches('nominees',
  ['id','person_id','name','relationship','phone'],
  nominees.map(n => [
    maps.nominees.get(n.synthetic_id), idOf('people', n.person_synthetic_id),
    sh(n.name), nullable(n.relationship), nullable(n.phone)
  ])
));

sql.push(...insertBatches('muppu_records',
  ['id','kuri_id','cycle_id','person_id','amount','status','settlement_method','paid_at','payment_reference'],
  muppu.map(m => [
    maps.muppu.get(m.synthetic_id), idOf('kuris', m.kuri_synthetic_id),
    idOf('cycles', m.cycle_synthetic_id), idOf('people', m.person_synthetic_id), m.amount,
    sh(m.status), m.status === 'PAID' ? sh('DIRECT_PAYMENT') : 'NULL',
    m.status === 'PAID' ? sh('2026-08-20T10:00:00Z') : 'NULL',
    m.status === 'PAID' ? sh('LOAD-' + m.synthetic_id) : 'NULL'
  ])
));

sql.push(...insertBatches('draw_sessions',
  ['id','kuri_id','cycle_id','conducted_by','status','started_at','completed_at'],
  draws.map(d => [
    maps.draws.get(d.synthetic_id), idOf('kuris', d.kuri_synthetic_id),
    idOf('cycles', d.cycle_synthetic_id), actorId, sh('FINALIZED'),
    sh('2026-08-20T10:00:00Z'), sh('2026-08-20T10:01:00Z')
  ])
));

sql.push(...insertBatches('draw_pool_entries',
  ['id','draw_session_id','membership_id','system_eligible','admin_included','override','override_reason','modified_by'],
  pools.map(p => [
    maps.pools.get(p.synthetic_id), idOf('draws', p.draw_synthetic_id),
    idOf('memberships', p.membership_synthetic_id), bool(p.system_eligible), bool(p.admin_included),
    bool(p.override ?? false), nullable(p.override_reason), actorId
  ])
));

sql.push(...insertBatches('draw_selections',
  ['id','draw_session_id','membership_id','selection_order','randomization_id'],
  selections.map(s => [
    maps.selections.get(s.synthetic_id), idOf('draws', s.draw_synthetic_id),
    idOf('memberships', s.membership_synthetic_id), s.selection_order, sh('load-' + s.synthetic_id)
  ])
));

sql.push(...insertBatches('monthly_winners',
  ['id','cycle_id','person_id','selection_source','finalized_by','finalized_at','status','notes'],
  winners.map(w => [
    maps.winners.get(w.synthetic_id), idOf('cycles', w.cycle_synthetic_id),
    idOf('people', w.person_synthetic_id), sh('RANDOM_DRAW'), actorId,
    sh('2026-08-20T10:02:00Z'), sh('FINALIZED'), sh('Synthetic local load-test winner')
  ])
));

sql.push(...insertBatches('monthly_winner_memberships',
  ['id','monthly_winner_id','membership_id','award_amount'],
  winnerMemberships.map(w => [
    maps.winnerMemberships.get(w.synthetic_id), idOf('winners', w.monthly_winner_synthetic_id),
    idOf('memberships', w.membership_synthetic_id), w.award_amount
  ])
));

sql.push(...insertBatches('payouts',
  ['id','monthly_winner_id','gross_amount','muppu_amount','other_deductions','net_amount','payment_date','method','reference_number','status','processed_by'],
  payouts.map(p => [
    maps.payouts.get(p.synthetic_id), idOf('winners', p.monthly_winner_synthetic_id),
    p.gross_amount, p.muppu_amount ?? 0, p.other_deductions ?? 0, p.net_amount,
    sh('2026-08-21T10:00:00Z'), sh('BANK_TRANSFER'), sh('LOAD-' + p.synthetic_id),
    sh('PAID'), actorId
  ])
));

sql.push(...insertBatches('membership_exits',
  ['id','membership_id','reason','exit_date','refund_policy','amount_contributed','refund_amount','status','approved_by','settled_at','notes','settlement_notes'],
  exits.map(e => [
    maps.exits.get(e.synthetic_id), idOf('memberships', e.membership_synthetic_id),
    sh(e.reason), sh('2026-08-01'), sh(e.refund_policy), e.amount_contributed, e.refund_amount,
    sh('SETTLED'), actorId, sh('2026-08-02T10:00:00Z'),
    sh('Synthetic local load-test exit'), sh('Synthetic local load-test settlement')
  ])
));

sql.push(...insertBatches('membership_exit_refund_transactions',
  ['id','membership_exit_id','amount','payment_method'],
  refunds.map(r => [
    maps.refunds.get(r.synthetic_id), idOf('exits', r.membership_exit_synthetic_id),
    r.amount, sh(r.payment_method)
  ])
));

sql.push(`-- Load-fixture marker. This is intentionally a normal table record rather than hosted metadata.
INSERT INTO public.organizations (id,name,description,email)
SELECT ${orgId}, ${sh(fixture.organization?.name ?? 'Kuri-App LOCAL LOAD TEST')}, ${sh('Synthetic local-only load-test organization')}, ${sh('loadtest@example.invalid')}
WHERE NOT EXISTS (SELECT 1 FROM public.organizations WHERE id=${orgId});
`);

sql.push('COMMIT;');

const marker = 'supabase-local';
const docker = process.platform === 'win32' ? 'docker.exe' : 'docker';
const dockerArgs = ['ps', '--format', '{{.Names}}'];

function runCapture(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let stdout = '', stderr = '';
    child.stdout.on('data', d => stdout += d);
    child.stderr.on('data', d => stderr += d);
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve(stdout.trim()) : reject(new Error(stderr || `Command failed: ${code}`)));
  });
}

const containerNames = (await runCapture(docker, dockerArgs)).split(/\r?\n/).filter(Boolean);
const dbContainer = containerNames.find(name => name.startsWith('supabase_db_') && name.includes(marker));
if (!dbContainer) {
  throw new Error('Local Supabase DB container not found. Start it with: npx supabase start --workdir supabase-local');
}

const totalSqlChars = sql.reduce((sum, statement) => sum + statement.length + 1, 0);
console.log(`Preparing ${fixture.target?.people ?? people.length} people / ${totalSqlChars.toLocaleString()} SQL characters for local Supabase...`);
const started = Date.now();

const localProjectDir = path.join(process.cwd(), 'supabase-local');
const localSupabaseDir = path.join(localProjectDir, 'supabase');
const canonicalMigrationsDir = path.join(process.cwd(), 'supabase', 'migrations');

if (!fs.existsSync(localProjectDir) || !fs.statSync(localProjectDir).isDirectory()) {
  throw new Error('Local Supabase workspace not found. Expected ./supabase-local.');
}
if (!fs.existsSync(localSupabaseDir) || !fs.statSync(localSupabaseDir).isDirectory()) {
  throw new Error('Local Supabase metadata directory not found. Expected ./supabase-local/supabase.');
}
if (!fs.existsSync(canonicalMigrationsDir) || !fs.statSync(canonicalMigrationsDir).isDirectory()) {
  throw new Error('Canonical migrations directory not found. Expected ./supabase/migrations.');
}

const localMigrationsDir = path.join(localSupabaseDir, 'migrations');
fs.rmSync(localMigrationsDir, { recursive: true, force: true });
fs.mkdirSync(localMigrationsDir, { recursive: true });
for (const name of fs.readdirSync(canonicalMigrationsDir)) {
  const source = path.join(canonicalMigrationsDir, name);
  if (fs.statSync(source).isFile() && name.endsWith('.sql')) {
    fs.copyFileSync(source, path.join(localMigrationsDir, name));
  }
}

const seedDir = path.join(process.cwd(), '.tmp', 'kuri-load-fixture-local');
const seedPath = path.join(seedDir, 'seed.sql');
fs.mkdirSync(seedDir, { recursive: true });

fs.writeFileSync(seedPath, sql.join('\n') + '\n', 'utf8');

console.log(`Prepared ${path.basename(seedPath)}. Mirrored ${fs.readdirSync(localMigrationsDir).length} canonical migrations. Loading via file-based psql in the local Supabase container...`);

const supabaseDbContainer = 'supabase_db_supabase-local';

function runProcess(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: process.cwd(),
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', d => stdout += d);
    child.stderr.on('data', d => stderr += d);
    child.once('error', reject);
    child.once('close', code => {
      if (code === 0) resolve(stdout.trim());
      else reject(new Error(stderr.trim() || stdout.trim() || `Command failed with exit code ${code}`));
    });
  });
}

await runProcess('docker', [
  'cp',
  seedPath,
  `${supabaseDbContainer}:/tmp/kuri-load-fixture-seed.sql`,
]);

await runProcess('docker', [
  'exec',
  '-i',
  supabaseDbContainer,
  'psql',
  '-U', 'postgres',
  '-d', 'postgres',
  '-v', 'ON_ERROR_STOP=1',
  '-f', '/tmp/kuri-load-fixture-seed.sql',
]);

console.log(JSON.stringify({
  loaded: fixture.counts,
  organization_id: orgId.replaceAll("'", ''),
  elapsed_seconds: Number(((Date.now() - started) / 1000).toFixed(3)),
  target: 'local Supabase Docker only',
  transport: 'file-based psql via docker exec'
}, null, 2));
