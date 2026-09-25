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

describe('Kuri-App payment allocation concurrency', () => {
  let adminA: SupabaseClient
  let adminB: SupabaseClient

  beforeAll(async () => {
    adminA = await signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD'))
    adminB = await signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD'))
  })

  it('serializes concurrent advance allocations and preserves allocation invariants', async () => {
    const suffix = Date.now().toString()
    const startDate = new Date().toISOString().slice(0, 10)

    const { data: kuri, error: kuriError } = await adminA.rpc('create_kuri_for_admin', {
      name: `Allocation Race ${suffix}`,
      description: 'Disposable authenticated allocation concurrency fixture',
      start_date: startDate,
      number_of_cycles: 3,
      membership_limit: 2,
      installment_amount: 100,
      due_day: 28,
      draw_day: 28,
      gross_prize_amount: 100,
      muppu_amount: 0,
      winner_rule: 'ALL_PERSON_MEMBERSHIPS',
      exit_refund_rule: 'AT_MATURITY',
    })
    expect(kuriError).toBeNull()
    expect(kuri).toBeTruthy()

    const kuriId = kuri as string

    const { data: generated, error: generateError } = await adminA.rpc(
      'generate_cycles_for_admin',
      { target_kuri_id: kuriId },
    )
    expect(generateError).toBeNull()
    expect(generated).toBe(3)

    const { data: opened, error: openError } = await adminA.rpc(
      'transition_kuri_status_for_admin',
      { target_kuri_id: kuriId, target_status: 'OPEN' },
    )
    expect(openError).toBeNull()
    expect(opened).toBe('OPEN')

    const { data: membership, error: membershipError } = await adminA.rpc(
      'create_membership_for_admin',
      {
        target_kuri_id: kuriId,
        target_person_id: env('TEST_PERSON_A_ID'),
        target_membership_number: `RACE-${suffix}`,
      },
    )
    expect(membershipError).toBeNull()
    expect(membership).toBeTruthy()

    const membershipId = membership as string

    const { data: payment, error: paymentError } = await adminA.rpc('create_payment_for_admin', {
      target_kuri_id: kuriId,
      target_person_id: env('TEST_PERSON_A_ID'),
      payment_amount: 200,
      payment_date: new Date().toISOString(),
      payment_method: 'CASH',
      payment_reference: `RACE-${suffix}`,
      payment_notes: 'Disposable authenticated allocation concurrency fixture',
      idempotency_key: `RACE-PAYMENT-CREATE-${suffix}`,
    })
    expect(paymentError).toBeNull()
    expect(payment).toBeTruthy()

    const paymentId = payment as string
    const keyA = `RACE-PAYMENT-ALLOC-A-${suffix}`
    const keyB = `RACE-PAYMENT-ALLOC-B-${suffix}`

    const attempts = await Promise.all([
      adminA.rpc('allocate_payment_to_oldest_installments_for_admin', {
        target_payment_id: paymentId,
        target_membership_id: membershipId,
        requested_allocation_amount: 150,
        idempotency_key: keyA,
      }),
      adminB.rpc('allocate_payment_to_oldest_installments_for_admin', {
        target_payment_id: paymentId,
        target_membership_id: membershipId,
        requested_allocation_amount: 150,
        idempotency_key: keyB,
      }),
    ])

    const successful = attempts.filter((attempt) => !attempt.error)
    const failed = attempts.filter((attempt) => !!attempt.error)

    expect(successful).toHaveLength(1)
    expect(failed).toHaveLength(1)
    expect(successful[0].data).toBe(150)
    expect(failed[0].error?.message).toContain(
      'payment amount available for allocation',
    )

    const successfulKey = attempts[0].error ? keyB : keyA
    const { data: replayed, error: replayError } = await adminA.rpc(
      'allocate_payment_to_oldest_installments_for_admin',
      {
        target_payment_id: paymentId,
        target_membership_id: membershipId,
        requested_allocation_amount: 150,
        idempotency_key: successfulKey,
      },
    )
    expect(replayError).toBeNull()
    expect(replayed).toBe(150)

    const { data: allocations, error: allocationsError } = await adminA.rpc(
      'list_payment_allocations_for_admin',
      { target_payment_id: paymentId },
    )
    expect(allocationsError).toBeNull()
    expect(allocations).toHaveLength(2)
    expect(allocations.reduce((sum, row) => sum + row.amount, 0)).toBe(150)

    const { data: paymentRow, error: paymentGetError } = await adminA.rpc(
      'get_payment_for_admin',
      { target_payment_id: paymentId },
    )
    expect(paymentGetError).toBeNull()
    expect(paymentRow).toHaveLength(1)
    expect(paymentRow[0].amount).toBe(200)

    const { data: cycles, error: cyclesError } = await adminA.rpc(
      'list_cycles_for_admin',
      { target_kuri_id: kuriId },
    )
    expect(cyclesError).toBeNull()
    expect(cycles).toHaveLength(3)

    const installmentResults = await Promise.all(
      cycles.map((cycle: { id: string }) =>
        adminA.rpc('list_installments_for_cycle_admin', {
          target_cycle_id: cycle.id,
        }),
      ),
    )
    installmentResults.forEach((result) => expect(result.error).toBeNull())

    const ownInstallments = installmentResults
      .flatMap((result) => result.data ?? [])
      .filter((row: { membership_id: string }) => row.membership_id === membershipId)
      .sort((a, b) => a.cycle_number - b.cycle_number)

    expect(ownInstallments).toHaveLength(3)
    expect(ownInstallments.map((row) => row.amount_paid)).toEqual([100, 50, 0])
    expect(ownInstallments.map((row) => row.status)).toEqual([
      'PAID',
      'PARTIAL',
      'UNPAID',
    ])

    expect(
      ownInstallments.reduce(
        (sum, row) => sum + Math.min(row.amount_due, row.amount_paid),
        0,
      ),
    ).toBe(150)
  })
})
