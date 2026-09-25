import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { beforeAll, describe, expect, it } from 'vitest'

const env = (name: string) => { const value = process.env[name]; if (!value) throw new Error(`Missing integration-test environment variable: ${name}`); return value }
const client = () => createClient(env('SUPABASE_URL'), env('SUPABASE_PUBLISHABLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } })
const signIn = async (email: string, password: string) => { const c = client(); const { error } = await c.auth.signInWithPassword({ email, password }); if (error) throw new Error(`Auth failed for ${email}: ${error.message}`); return c }
const rpc = async (c: SupabaseClient, fn: string, args: Record<string, unknown> = {}) => c.rpc(fn, args)

const required = ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','TEST_ADMIN_A_EMAIL','TEST_ADMIN_A_PASSWORD','TEST_ADMIN_B_EMAIL','TEST_ADMIN_B_PASSWORD','TEST_MEMBER_A_EMAIL','TEST_MEMBER_A_PASSWORD','TEST_PERSON_A_ID','TEST_PERSON_B_ID','TEST_KURI_A_ID','TEST_KURI_B_ID','TEST_CYCLE_A_ID']

describe('Kuri-App authenticated API boundary', () => {
  let adminA: SupabaseClient, adminB: SupabaseClient, memberA: SupabaseClient, anonymous: SupabaseClient

  beforeAll(async () => {
    const missing = required.filter((name) => !process.env[name])
    if (missing.length) throw new Error(`Missing: ${missing.join(', ')}`)
    ;[adminA, adminB, memberA] = await Promise.all([
      signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD')),
      signIn(env('TEST_ADMIN_B_EMAIL'), env('TEST_ADMIN_B_PASSWORD')),
      signIn(env('TEST_MEMBER_A_EMAIL'), env('TEST_MEMBER_A_PASSWORD')),
    ])
    anonymous = client()
  })

  it('authenticates each dedicated test identity with a real Supabase session', async () => {
    for (const c of [adminA, adminB, memberA]) {
      const { data, error } = await c.auth.getSession()
      expect(error).toBeNull(); expect(data.session?.access_token).toBeTruthy(); expect(data.session?.user.id).toBeTruthy()
    }
  })

  it('rejects anonymous access to a session helper', async () => {
    const { data, error } = await rpc(anonymous, 'get_my_workspace_id')
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('allows an Org A admin to resolve an Org A Kuri', async () => {
    const { data, error } = await rpc(adminA, 'get_kuri_for_admin', { target_kuri_id: env('TEST_KURI_A_ID') })
    expect(error).toBeNull(); expect(data).toBeTruthy()
  })

  it('blocks an Org B admin from resolving an Org A Kuri', async () => {
    const { data, error } = await rpc(adminB, 'get_kuri_for_admin', { target_kuri_id: env('TEST_KURI_A_ID') })
    expect(error).toBeNull(); expect(Array.isArray(data)).toBe(true); expect(data).toHaveLength(0)
  })

  it('blocks an Org B admin from resolving an Org A person', async () => {
    const { data, error } = await rpc(adminB, 'get_person_for_admin', { target_person_id: env('TEST_PERSON_A_ID') })
    expect(error).toBeNull(); expect(Array.isArray(data)).toBe(true); expect(data).toHaveLength(0)
  })

  it('allows an Org A admin to resolve an Org A person', async () => {
    const { data, error } = await rpc(adminA, 'get_person_for_admin', { target_person_id: env('TEST_PERSON_A_ID') })
    expect(error).toBeNull(); expect(data).toBeTruthy()
  })

  it('exposes lifecycle transition RPCs to authenticated callers while enforcing authorization', async () => {
    const ownKuri = await rpc(adminA, 'transition_kuri_status_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_status: 'ACTIVE',
    })
    expect(ownKuri.data).toBeNull()
    expect(ownKuri.error).not.toBeNull()

    const crossTenantKuri = await rpc(adminB, 'transition_kuri_status_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_status: 'ACTIVE',
    })
    expect(crossTenantKuri.data).toBeNull()
    expect(crossTenantKuri.error).not.toBeNull()

    const memberKuri = await rpc(memberA, 'transition_kuri_status_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_status: 'ACTIVE',
    })
    expect(memberKuri.data).toBeNull()
    expect(memberKuri.error).not.toBeNull()

    const ownCycle = await rpc(adminA, 'transition_cycle_status_for_admin', {
      target_cycle_id: env('TEST_CYCLE_A_ID'),
      target_status: 'COMPLETED',
    })
    expect(ownCycle.data).toBeNull()
    expect(ownCycle.error).not.toBeNull()
  })

  it('rejects ordinary members from administrative Kuri reads', async () => {
    const { data, error } = await rpc(memberA, 'get_kuri_for_admin', { target_kuri_id: env('TEST_KURI_A_ID') })
    expect(error).toBeNull(); expect(Array.isArray(data)).toBe(true); expect(data).toHaveLength(0)
  })

  it('keeps list APIs tenant-scoped', async () => {
    const { data, error } = await rpc<unknown[]>(adminA, 'list_kuris_for_admin')
    expect(error).toBeNull(); expect(Array.isArray(data)).toBe(true)
    expect(JSON.stringify(data ?? [])).not.toContain(env('TEST_KURI_B_ID'))
  })

  it('rejects a cross-tenant payment mutation before mutation', async () => {
    const { data, error } = await rpc(adminA, 'create_payment_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_person_id: env('TEST_PERSON_B_ID'), payment_amount: 1, payment_date: new Date().toISOString(),
      payment_method: 'OTHER', payment_reference: 'AUTH-INTEGRATION-CROSS-TENANT',
      payment_notes: 'Must be rejected by tenancy boundary.',
      idempotency_key: 'AUTH-CROSS-TENANT-PAYMENT'
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects an unauthenticated admin mutation', async () => {
    const { data, error } = await rpc(anonymous, 'create_payment_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_person_id: env('TEST_PERSON_A_ID'), payment_amount: 1, payment_date: new Date().toISOString(),
      payment_method: 'OTHER', payment_reference: 'AUTH-INTEGRATION-ANON',
      payment_notes: 'Must be rejected without JWT.',
      idempotency_key: 'AUTH-ANON-PAYMENT'
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects ordinary members from creating memberships', async () => {
    const { data, error } = await rpc(memberA, 'create_membership_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_person_id: env('TEST_PERSON_A_ID'),
      target_membership_number: 'AUTH-MEMBER-DENIED',
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects cross-tenant membership assignment', async () => {
    const { data, error } = await rpc(adminB, 'create_membership_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_person_id: env('TEST_PERSON_A_ID'),
      target_membership_number: 'AUTH-CROSS-TENANT-MEMBERSHIP',
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects draw preparation while the cycle is not payment-closed', async () => {
    const { data, error } = await rpc(adminA, 'prepare_draw_for_admin', {
      target_cycle_id: env('TEST_CYCLE_A_ID'),
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects draw preparation across tenants', async () => {
    const { data, error } = await rpc(adminB, 'prepare_draw_for_admin', {
      target_cycle_id: env('TEST_CYCLE_A_ID'),
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects random draw execution before the cycle reaches draw-ready state', async () => {
    const { data, error } = await rpc(adminA, 'run_random_draw_for_admin', {
      target_cycle_id: env('TEST_CYCLE_A_ID'),
      selection_count: 1,
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects draw finalization before a valid draw session exists', async () => {
    const { data, error } = await rpc(adminA, 'finalize_draw_for_admin', {
      target_cycle_id: env('TEST_CYCLE_A_ID'),
      final_membership_ids: [],
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects payout preparation when the referenced winner does not exist', async () => {
    const { data, error } = await rpc(adminA, 'prepare_payout_for_admin', {
      target_winner_id: '00000000-0000-0000-0000-000000000001',
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects payout preparation across tenants', async () => {
    const { data, error } = await rpc(adminB, 'prepare_payout_for_admin', {
      target_winner_id: '00000000-0000-0000-0000-000000000001',
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects payment creation with a non-positive amount', async () => {
    const results = await Promise.all([
      rpc(adminA, 'create_payment_for_admin', {
        target_person_id: env('TEST_PERSON_A_ID'), payment_amount: 0, payment_date: new Date().toISOString(),
        payment_method: 'OTHER', payment_reference: 'AUTH-NONPOSITIVE-0', payment_notes: 'Must be rejected.',
        target_kuri_id: env('TEST_KURI_A_ID'), idempotency_key: 'AUTH-NONPOSITIVE-0-KEY'
      }),
      rpc(adminA, 'create_payment_for_admin', {
        target_person_id: env('TEST_PERSON_A_ID'), payment_amount: -1, payment_date: new Date().toISOString(),
        payment_method: 'OTHER', payment_reference: 'AUTH-NONPOSITIVE-NEG', payment_notes: 'Must be rejected.',
        target_kuri_id: env('TEST_KURI_A_ID'), idempotency_key: 'AUTH-NONPOSITIVE-NEG-KEY'
      }),
    ])
    for (const result of results) { expect(result.data).toBeNull(); expect(result.error).not.toBeNull() }
  })

  it('rejects allocation against a nonexistent payment or installment', async () => {
    const { data, error } = await rpc(adminA, 'allocate_payment_for_admin', {
      target_payment_id: '00000000-0000-0000-0000-000000000001',
      target_installment_id: '00000000-0000-0000-0000-000000000002',
      allocation_amount: 1,
      idempotency_key: 'AUTH-UNKNOWN-ALLOCATION',
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects direct authenticated inserts into the payment ledger', async () => {
    const { data, error } = await adminA.from('payments').insert({
      organization_id: '00000000-0000-0000-0000-000000000001',
      person_id: env('TEST_PERSON_A_ID'),
      amount: 1,
      payment_date: new Date().toISOString(),
      method: 'OTHER',
      reference_number: 'AUTH-DIRECT-PAYMENT',
    }).select()
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects direct authenticated inserts into the draw pool', async () => {
    const { data, error } = await adminA.from('draw_pool_entries').insert({
      draw_session_id: '00000000-0000-0000-0000-000000000001',
      membership_id: '00000000-0000-0000-0000-000000000002',
      system_eligible: false,
      admin_included: false,
      override: false,
    }).select()
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects cross-tenant nominee creation', async () => {
    const { data, error } = await rpc(adminA, 'create_nominee_for_admin', {
      target_person_id: env('TEST_PERSON_B_ID'),
      nominee_name: 'Cross Tenant Test',
      nominee_relationship: 'Test',
      nominee_phone: null,
      nominee_address: null,
      nominee_notes: 'Must be rejected.',
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects cross-tenant Muppu creation', async () => {
    const { data, error } = await rpc(adminA, 'create_muppu_record_for_admin', {
      target_kuri_id: env('TEST_KURI_A_ID'),
      target_cycle_id: env('TEST_CYCLE_A_ID'),
      target_person_id: env('TEST_PERSON_B_ID'),
      muppu_amount: 1,
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects membership exit creation for an unknown membership', async () => {
    const { data, error } = await rpc(adminA, 'create_membership_exit_for_admin', {
      target_membership_id: '00000000-0000-0000-0000-000000000001',
      exit_reason: 'VOLUNTARY_EXIT',
      target_exit_date: new Date().toISOString().slice(0, 10),
      target_refund_policy: 'IMMEDIATE',
      target_refund_amount: 0,
      target_notes: 'Must be rejected.',
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('blocks an Org B admin from inserting an email contact for an Org A person', async () => {
    const { data, error } = await adminB.from('person_emails').insert({
      person_id: env('TEST_PERSON_A_ID'),
      email: 'cross-tenant@example.invalid',
      label: 'TEST',
      is_primary: false,
    }).select()
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('blocks an Org B admin from inserting a phone contact for an Org A person', async () => {
    const { data, error } = await adminB.from('person_phones').insert({
      person_id: env('TEST_PERSON_A_ID'),
      phone_number: '+999000000000',
      label: 'TEST',
      is_primary: false,
    }).select()
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects anonymous draw preparation', async () => {
    const { data, error } = await rpc(anonymous, 'prepare_draw_for_admin', {
      target_cycle_id: env('TEST_CYCLE_A_ID'),
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('blocks direct authenticated reads from application user identity records', async () => {
    const { data, error } = await adminA.from('users').select('id,email,person_id')
    expect(data).toBeNull()
    expect(error).not.toBeNull()
    expect(error?.code).toBe('42501')
  })

  it('scopes organization membership reads to organizations the caller belongs to', async () => {
    const { data, error } = await adminA.from('organization_users').select('organization_id,user_id,role')
    const adminBSession = (await adminB.auth.getSession()).data.session
    expect(error).toBeNull()
    expect(Array.isArray(data)).toBe(true)
    expect(data?.some((row: { user_id: string }) => row.user_id === adminBSession?.user.id)).toBe(false)
  })

  it('rejects direct authenticated writes to organization membership records', async () => {
    const fakeOrganizationId = '00000000-0000-0000-0000-000000000001'
    const fakeUserId = '00000000-0000-0000-0000-000000000002'

    const insertResult = await adminA.from('organization_users').insert({
      organization_id: fakeOrganizationId,
      user_id: fakeUserId,
      role: 'ADMIN',
    }).select()
    expect(insertResult.data).toBeNull()
    expect(insertResult.error).not.toBeNull()

    const updateResult = await adminA.from('organization_users')
      .update({ role: 'MAIN_ADMIN' })
      .eq('user_id', fakeUserId)
      .select()
    expect(updateResult.data).toBeNull()
    expect(updateResult.error).not.toBeNull()
  })

  it('rejects direct authenticated writes to application user identity records', async () => {
    const session = (await adminA.auth.getSession()).data.session

    const insertResult = await adminA.from('users').insert({
      id: '00000000-0000-0000-0000-000000000003',
      email: 'forged@example.invalid',
    }).select()
    expect(insertResult.data).toBeNull()
    expect(insertResult.error).not.toBeNull()

    const updateResult = await adminA.from('users')
      .update({ person_id: env('TEST_PERSON_B_ID') })
      .eq('id', session?.user.id ?? '00000000-0000-0000-0000-000000000004')
      .select()
    expect(updateResult.data).toBeNull()
    expect(updateResult.error).not.toBeNull()
  })

})
