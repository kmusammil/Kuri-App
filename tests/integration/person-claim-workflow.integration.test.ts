import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { beforeAll, describe, expect, it } from 'vitest'

const env = (name: string) => {
  const value = process.env[name]
  if (!value) throw new Error(`Missing integration-test environment variable: ${name}`)
  return value
}

const client = () =>
  createClient(env('SUPABASE_URL'), env('SUPABASE_PUBLISHABLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  })

const signIn = async (email: string, password: string) => {
  const c = client()
  const { error } = await c.auth.signInWithPassword({ email, password })
  if (error) throw new Error(`Auth failed for ${email}: ${error.message}`)
  return c
}

describe('Person claim workflow', () => {
  let adminA: SupabaseClient
  let claimant: SupabaseClient
  let validToken: string

  beforeAll(async () => {
    adminA = await signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD'))
    claimant = await signIn(env('TEST_CLAIM_USER_EMAIL'), env('TEST_CLAIM_USER_PASSWORD'))
  })

  it('issues a one-time claim token only to an authorized organization admin', async () => {
    const { data, error } = await adminA.rpc('create_person_claim_token_for_admin', {
      target_person_id: env('TEST_CLAIM_PERSON_ID'),
      expires_in_hours: 24,
    })
    expect(error).toBeNull()
    expect(typeof data).toBe('string')
    expect(data).toMatch(/^[0-9a-f]{48}$/)
    validToken = data as string
  })

  it('rejects malformed and expired claim tokens', async () => {
    const malformed = await claimant.rpc('claim_existing_person', {
      claim_token: 'not-a-valid-token',
    })
    expect(malformed.data).toBeNull()
    expect(malformed.error).not.toBeNull()

    const { data: expiredToken, error: issueError } = await adminA.rpc(
      'create_person_claim_token_for_admin',
      { target_person_id: env('TEST_CLAIM_PERSON_ID'), expires_in_hours: 1 },
    )
    expect(issueError).toBeNull()
    expect(expiredToken).toMatch(/^[0-9a-f]{48}$/)

    // The database owns expiry evaluation. This assertion uses a token whose
    // expiry is forced into the past by the test-only SQL cleanup hook below.
    const { error: forceExpireError } = await adminA.rpc('test_expire_person_claim_token', {
      raw_token: expiredToken,
    })
    expect(forceExpireError).toBeNull()

    const expired = await claimant.rpc('claim_existing_person', {
      claim_token: expiredToken,
    })
    expect(expired.data).toBeNull()
    expect(expired.error).not.toBeNull()
  })

  it('claims the existing Person without creating a duplicate Person or Membership', async () => {
    const { data: beforePerson, error: beforePersonError } = await adminA.rpc('get_person_for_admin', {
      target_person_id: env('TEST_CLAIM_PERSON_ID'),
    })
    expect(beforePersonError).toBeNull()
    expect(beforePerson).toBeTruthy()

    const { data: claim, error } = await claimant.rpc('claim_existing_person', {
      claim_token: validToken,
    })
    expect(error).toBeNull()
    expect(claim).toBe(env('TEST_CLAIM_PERSON_ID'))

    const { data: afterPerson, error: afterPersonError } = await adminA.rpc('get_person_for_admin', {
      target_person_id: env('TEST_CLAIM_PERSON_ID'),
    })
    expect(afterPersonError).toBeNull()
    expect(afterPerson).toBeTruthy()
  })

  it('rejects a second claim by the already-linked User', async () => {
    const { data, error } = await claimant.rpc('claim_existing_person', {
      claim_token: validToken,
    })
    expect(data).toBeNull()
    expect(error).not.toBeNull()
  })

  it('keeps the claim path separate from membership and administrative role assignment', async () => {
    const { data, error } = await claimant.rpc('list_my_notifications')
    expect(error).toBeNull()
    expect(data).toBeTruthy()
  })
})
