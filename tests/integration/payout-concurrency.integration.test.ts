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

describe('Kuri-App payout concurrency and idempotency', () => {
  let adminA: SupabaseClient
  let adminB: SupabaseClient

  beforeAll(async () => {
    ;[adminA, adminB] = await Promise.all([
      signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD')),
      signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD')),
    ])
  })

  it('serializes concurrent payout preparation/payment and replays the same request safely', async () => {
    const suffix = Date.now().toString()
    const startDate = new Date().toISOString().slice(0, 10)

    const { data: kuri, error: kuriError } = await adminA.rpc('create_kuri_for_admin', {
      name: `Payout Race ${suffix}`,
      description: 'Disposable authenticated payout concurrency fixture',
      start_date: startDate,
      number_of_cycles: 1,
      membership_limit: 1,
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

    expect(
      (
        await adminA.rpc('generate_cycles_for_admin', {
          target_kuri_id: kuriId,
        })
      ).error,
    ).toBeNull()

    expect(
      (
        await adminA.rpc('transition_kuri_status_for_admin', {
          target_kuri_id: kuriId,
          target_status: 'OPEN',
        })
      ).error,
    ).toBeNull()

    const { data: membership, error: membershipError } = await adminA.rpc(
      'create_membership_for_admin',
      {
        target_kuri_id: kuriId,
        target_person_id: env('TEST_PERSON_A_ID'),
        target_membership_number: `PAYOUT-${suffix}`,
      },
    )
    expect(membershipError).toBeNull()
    expect(membership).toBeTruthy()

    const { data: cycles, error: cyclesError } = await adminA.rpc('list_cycles_for_admin', {
      target_kuri_id: kuriId,
    })
    expect(cyclesError).toBeNull()
    expect(cycles).toHaveLength(1)
    const cycleId = cycles[0].id as string

    for (const target of ['OPEN', 'PAYMENT_CLOSED', 'DRAW_PENDING'] as const) {
      const { error } = await adminA.rpc('transition_cycle_status_for_admin', {
        target_cycle_id: cycleId,
        target_status: target,
      })
      expect(error).toBeNull()
    }

    const { data: installments, error: installmentsError } = await adminA.rpc(
      'list_installments_for_cycle_admin',
      { target_cycle_id: cycleId },
    )
    expect(installmentsError).toBeNull()
    const installment = installments.find(
      (row: { membership_id: string }) => row.membership_id === membership,
    )
    expect(installment).toBeTruthy()

    const { data: payment, error: paymentError } = await adminA.rpc('create_payment_for_admin', {
      target_kuri_id: kuriId,
      target_person_id: env('TEST_PERSON_A_ID'),
      payment_amount: 100,
      payment_date: new Date().toISOString(),
      payment_method: 'CASH',
      payment_reference: `PAYOUT-${suffix}`,
      payment_notes: 'Disposable authenticated payout concurrency fixture',
      p_idempotency_key: `PAYOUT-PAYMENT-CREATE-${suffix}`,
    })
    expect(paymentError).toBeNull()
    expect(payment).toBeTruthy()

    const { data: paid, error: allocationError } = await adminA.rpc(
      'allocate_payment_for_admin',
      {
        target_payment_id: payment,
        target_installment_id: installment.id,
        allocation_amount: 100,
        p_idempotency_key: `PAYOUT-ALLOC-${suffix}`,
      },
    )
    expect(allocationError).toBeNull()
    expect(paid).toBe(100)

    const { data: prepared, error: drawPrepError } = await adminA.rpc(
      'prepare_draw_for_admin',
      { target_cycle_id: cycleId },
    )
    expect(drawPrepError).toBeNull()
    expect(prepared).toBeTruthy()

    const { data: draw, error: drawError } = await adminA.rpc(
      'run_random_draw_for_admin',
      { target_cycle_id: cycleId, selection_count: 1 },
    )
    expect(drawError).toBeNull()
    expect(draw).toHaveLength(1)

    const { data: finalized, error: finalizeError } = await adminA.rpc(
      'finalize_draw_for_admin',
      {
        target_cycle_id: cycleId,
        final_membership_ids: [membership],
      },
    )
    expect(finalizeError).toBeNull()
    expect(finalized).toBe(1)

    const { data: winners, error: winnersError } = await adminA.rpc(
      'get_monthly_winners_for_admin',
      { target_cycle_id: cycleId },
    )
    expect(winnersError).toBeNull()
    expect(winners).toHaveLength(1)
    const winnerId = winners[0].winner_id as string

    const preparedPayouts = await Promise.all([
      adminA.rpc('prepare_payout_for_admin', {
        target_winner_id: winnerId,
      }),
      adminB.rpc('prepare_payout_for_admin', {
        target_winner_id: winnerId,
      }),
    ])
    preparedPayouts.forEach((result) => {
      expect(result.error).toBeNull()
      expect(result.data).toBeTruthy()
    })
    expect(preparedPayouts[0].data).toBe(preparedPayouts[1].data)

    const requestKey = `PAYOUT-PAY-${suffix}`
    const payoutDate = new Date().toISOString()

    const paymentAttempts = await Promise.all([
      adminA.rpc('mark_payout_paid_for_admin', {
        target_winner_id: winnerId,
        payout_payment_date: payoutDate,
        payout_method: 'CASH',
        p_idempotency_key: requestKey,
        payout_reference: `PAYOUT-${suffix}`,
        payout_notes: 'Concurrent idempotent payout payment',
        payout_other_deductions: 10,
      }),
      adminB.rpc('mark_payout_paid_for_admin', {
        target_winner_id: winnerId,
        payout_payment_date: payoutDate,
        payout_method: 'CASH',
        p_idempotency_key: requestKey,
        payout_reference: `PAYOUT-${suffix}`,
        payout_notes: 'Concurrent idempotent payout payment',
        payout_other_deductions: 10,
      }),
    ])

    paymentAttempts.forEach((result) => expect(result.error).toBeNull())

    const { data: payout, error: payoutError } = await adminA.rpc('get_payout_for_admin', {
      target_winner_id: winnerId,
    })
    expect(payoutError).toBeNull()
    expect(payout).toHaveLength(1)
    expect(payout[0].status).toBe('PAID')
    expect(payout[0].gross_amount).toBe(100)
    expect(payout[0].other_deductions).toBe(10)
    expect(payout[0].net_amount).toBe(90)

    const { data: payouts, error: listError } = await adminA.rpc('list_payouts_for_admin', {
      target_kuri_id: kuriId,
    })
    expect(listError).toBeNull()
    expect(payouts).toHaveLength(1)

    const replayMismatch = await adminA.rpc('mark_payout_paid_for_admin', {
      target_winner_id: winnerId,
      payout_payment_date: payoutDate,
      payout_method: 'CASH',
      p_idempotency_key: requestKey,
      payout_reference: `PAYOUT-${suffix}`,
      payout_notes: 'Different payload must be rejected',
      payout_other_deductions: 11,
    })
    expect(replayMismatch.data).toBeNull()
    expect(replayMismatch.error?.message).toContain('different payout request')
  })
})
