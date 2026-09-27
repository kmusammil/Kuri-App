import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { beforeAll, afterAll, describe, expect, it } from 'vitest'

const env = (name: string) => {
  const value = process.env[name]
  if (!value) throw new Error(`Missing integration-test environment variable: ${name}`)
  return value
}

const client = (serviceRole = false) =>
  createClient(
    env('SUPABASE_URL'),
    serviceRole ? env('SUPABASE_SERVICE_ROLE_KEY') : env('SUPABASE_PUBLISHABLE_KEY'),
    { auth: { persistSession: false, autoRefreshToken: false } },
  )

const signIn = async (email: string, password: string) => {
  const c = client()
  const { error } = await c.auth.signInWithPassword({ email, password })
  if (error) throw new Error(`Auth failed for ${email}: ${error.message}`)
  return c
}

const sha256Hex = async (value: string) => {
  const bytes = new TextEncoder().encode(value)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

describe('Person claim workflow', () => {
  let adminA: SupabaseClient
  let adminB: SupabaseClient
  let claimant: SupabaseClient
  let service: SupabaseClient
  let claimantUserId: string
  let targetPersonId: string
  let validToken: string
  let claimantInitialPersonId: string | null
  let claimantInitialRoles: string[]

  beforeAll(async () => {
    adminA = await signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD'))
    adminB = await signIn(env('TEST_ADMIN_B_EMAIL'), env('TEST_ADMIN_B_PASSWORD'))
    claimant = await signIn(env('TEST_MEMBER_A_EMAIL'), env('TEST_MEMBER_A_PASSWORD'))
    service = client(true)

    const { data: session } = await claimant.auth.getSession()
    claimantUserId = session.session?.user.id ?? ''
    expect(claimantUserId).toBeTruthy()

    const { data: claimantRow, error: claimantError } = await service
      .from('users')
      .select('person_id')
      .eq('id', claimantUserId)
      .single()
    expect(claimantError).toBeNull()
    claimantInitialPersonId = claimantRow?.person_id ?? null
    expect(claimantInitialPersonId).toBeNull()

    const { data: roles, error: rolesError } = await service
      .from('organization_users')
      .select('role')
      .eq('user_id', claimantUserId)
    expect(rolesError).toBeNull()
    claimantInitialRoles = (roles ?? []).map((row: { role: string }) => row.role).sort()

    const { data: orgId, error: orgError } = await adminA.rpc('get_my_workspace_id')
    expect(orgError).toBeNull()
    expect(orgId).toBeTruthy()

    const { data: personId, error: personError } = await adminA.rpc('create_person_for_org_admin', {
      target_org_id: orgId,
      registered_name: `Integration Claim Person ${Date.now()}`,
      display_name: 'Integration Claim Person',
      address: null,
      notes: 'Disposable person-claim integration fixture',
      phone: null,
      email: null,
    })
    expect(personError).toBeNull()
    expect(personId).toBeTruthy()
    targetPersonId = personId as string
  })

  afterAll(async () => {
    // Restore the dedicated claimant fixture to its pre-test state and remove
    // the disposable Person/tokens. Audit records remain intentionally.
    await service.from('users').update({ person_id: claimantInitialPersonId }).eq('id', claimantUserId)
    await service.from('person_claim_tokens').delete().eq('person_id', targetPersonId)
    await service.from('people').delete().eq('id', targetPersonId)
  })

  it('issues a one-time claim token only to an authorized organization admin', async () => {
    const { data, error } = await adminA.rpc('create_person_claim_token_for_admin', {
      target_person_id: targetPersonId,
      expires_in_hours: 24,
    })
    expect(error).toBeNull()
    expect(typeof data).toBe('string')
    expect(data).toMatch(/^[0-9a-f]{48}$/)
    validToken = data as string

    const { data: crossTenantToken, error: crossTenantError } = await adminB.rpc(
      'create_person_claim_token_for_admin',
      { target_person_id: targetPersonId, expires_in_hours: 24 },
    )
    expect(crossTenantToken).toBeNull()
    expect(crossTenantError).not.toBeNull()
  })

  it('rejects malformed and expired claim tokens', async () => {
    const malformed = await claimant.rpc('claim_existing_person', {
      claim_token: 'not-a-valid-token',
    })
    expect(malformed.data).toBeNull()
    expect(malformed.error).not.toBeNull()

    const { data: expiredToken, error: issueError } = await adminA.rpc(
      'create_person_claim_token_for_admin',
      { target_person_id: targetPersonId, expires_in_hours: 1 },
    )
    expect(issueError).toBeNull()
    expect(expiredToken).toMatch(/^[0-9a-f]{48}$/)

    const expiredHash = await sha256Hex(expiredToken as string)
    const { error: expireError } = await service
      .from('person_claim_tokens')
      .update({ expires_at: new Date(Date.now() - 60_000).toISOString() })
      .eq('token_hash', expiredHash)
    expect(expireError).toBeNull()

    const expired = await claimant.rpc('claim_existing_person', {
      claim_token: expiredToken,
    })
    expect(expired.data).toBeNull()
    expect(expired.error).not.toBeNull()
  })

  it('claims the existing Person without creating a duplicate Person or Membership', async () => {
    const { count: peopleBefore, error: peopleBeforeError } = await service
      .from('people')
      .select('id', { count: 'exact', head: true })
      .eq('id', targetPersonId)
    expect(peopleBeforeError).toBeNull()
    expect(peopleBefore).toBe(1)

    const { count: membershipsBefore, error: membershipsBeforeError } = await service
      .from('memberships')
      .select('id', { count: 'exact', head: true })
      .eq('person_id', targetPersonId)
    expect(membershipsBeforeError).toBeNull()
    expect(membershipsBefore).toBe(0)

    const { data: claim, error } = await claimant.rpc('claim_existing_person', {
      claim_token: validToken,
    })
    expect(error).toBeNull()
    expect(claim).toBe(targetPersonId)

    const { data: linkedUser, error: linkedUserError } = await service
      .from('users')
      .select('person_id')
      .eq('id', claimantUserId)
      .single()
    expect(linkedUserError).toBeNull()
    expect(linkedUser?.person_id).toBe(targetPersonId)

    const { count: peopleAfter, error: peopleAfterError } = await service
      .from('people')
      .select('id', { count: 'exact', head: true })
      .eq('id', targetPersonId)
    expect(peopleAfterError).toBeNull()
    expect(peopleAfter).toBe(1)

    const { count: membershipsAfter, error: membershipsAfterError } = await service
      .from('memberships')
      .select('id', { count: 'exact', head: true })
      .eq('person_id', targetPersonId)
    expect(membershipsAfterError).toBeNull()
    expect(membershipsAfter).toBe(0)
  })

  it('rejects a second claim by the already-linked User and preserves administrative roles', async () => {
    const { data, error } = await claimant.rpc('claim_existing_person', {
      claim_token: validToken,
    })
    expect(data).toBeNull()
    expect(error).not.toBeNull()

    const { data: roles, error: rolesError } = await service
      .from('organization_users')
      .select('role')
      .eq('user_id', claimantUserId)
    expect(rolesError).toBeNull()
    expect((roles ?? []).map((row: { role: string }) => row.role).sort()).toEqual(claimantInitialRoles)
  })
})
