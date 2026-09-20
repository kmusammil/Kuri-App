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
    const { data, error } = await rpc(adminA, 'get_kuri_for_admin', { p_kuri_id: env('TEST_KURI_A_ID') })
    expect(error).toBeNull(); expect(data).toBeTruthy()
  })

  it('blocks an Org B admin from resolving an Org A Kuri', async () => {
    const { data, error } = await rpc(adminB, 'get_kuri_for_admin', { p_kuri_id: env('TEST_KURI_A_ID') })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('blocks an Org B admin from resolving an Org A person', async () => {
    const { data, error } = await rpc(adminB, 'get_person_for_admin', { p_person_id: env('TEST_PERSON_A_ID') })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('allows an Org A admin to resolve an Org A person', async () => {
    const { data, error } = await rpc(adminA, 'get_person_for_admin', { p_person_id: env('TEST_PERSON_A_ID') })
    expect(error).toBeNull(); expect(data).toBeTruthy()
  })

  it('does not expose internal lifecycle transition primitives', async () => {
    const results = await Promise.all([
      rpc(adminA, 'transition_kuri_status_for_admin', { target_kuri_id: env('TEST_KURI_A_ID'), target_status: 'ACTIVE' }),
      rpc(adminA, 'transition_cycle_status_for_admin', { target_cycle_id: env('TEST_CYCLE_A_ID'), target_status: 'OPEN' }),
    ])
    for (const result of results) { expect(result.data).toBeNull(); expect(result.error).not.toBeNull() }
  })

  it('rejects ordinary members from administrative Kuri reads', async () => {
    const { data, error } = await rpc(memberA, 'get_kuri_for_admin', { p_kuri_id: env('TEST_KURI_A_ID') })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('keeps list APIs tenant-scoped', async () => {
    const { data, error } = await rpc<unknown[]>(adminA, 'list_kuris_for_admin')
    expect(error).toBeNull(); expect(Array.isArray(data)).toBe(true)
    expect(JSON.stringify(data ?? [])).not.toContain(env('TEST_KURI_B_ID'))
  })

  it('rejects a cross-tenant payment mutation before mutation', async () => {
    const { data, error } = await rpc(adminA, 'create_payment_for_admin', {
      target_person_id: env('TEST_PERSON_B_ID'), payment_amount: 1, payment_date: new Date().toISOString(),
      payment_method: 'OTHER', payment_reference: 'AUTH-INTEGRATION-CROSS-TENANT', payment_notes: 'Must be rejected by tenancy boundary.'
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })

  it('rejects an unauthenticated admin mutation', async () => {
    const { data, error } = await rpc(anonymous, 'create_payment_for_admin', {
      target_person_id: env('TEST_PERSON_A_ID'), payment_amount: 1, payment_date: new Date().toISOString(),
      payment_method: 'OTHER', payment_reference: 'AUTH-INTEGRATION-ANON', payment_notes: 'Must be rejected without JWT.'
    })
    expect(data).toBeNull(); expect(error).not.toBeNull()
  })
})
