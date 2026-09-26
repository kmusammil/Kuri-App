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

describe('Kuri-App positive end-to-end workflow', () => {
  let adminA: SupabaseClient

  let kuriId: string
  let cycleId: string
  let membershipId: string
  let installmentId: string
  let paymentId: string
  let drawSessionId: string
  let winnerId: string
  let payoutId: string

  beforeAll(async () => {
    adminA = await signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD'))
  })

  it('completes Kuri -> membership -> payment -> draw -> winner -> payout', async () => {
    const suffix = Date.now().toString()
    const startDate = new Date().toISOString().slice(0, 10)

    const { data: createdKuri, error: createKuriError } = await adminA.rpc('create_kuri_for_admin', {
      name: `Integration E2E ${suffix}`,
      description: 'Disposable authenticated integration fixture',
      start_date: startDate,
      number_of_cycles: 1,
      membership_limit: 2,
      installment_amount: 100,
      due_day: 28,
      draw_day: 28,
      gross_prize_amount: 100,
      muppu_amount: 0,
      winner_rule: 'ALL_PERSON_MEMBERSHIPS',
      exit_refund_rule: 'AT_MATURITY',
    })
    expect(createKuriError).toBeNull()
    expect(createdKuri).toBeTruthy()
    kuriId = createdKuri as string

    const { data: generatedCycles, error: generateCyclesError } = await adminA.rpc(
      'generate_cycles_for_admin',
      { target_kuri_id: kuriId },
    )
    expect(generateCyclesError).toBeNull()
    expect(generatedCycles).toBe(1)

    const { data: openedKuri, error: openKuriError } = await adminA.rpc(
      'transition_kuri_status_for_admin',
      { target_kuri_id: kuriId, target_status: 'OPEN' },
    )
    expect(openKuriError).toBeNull()
    expect(openedKuri).toBe('OPEN')

    const { data: cycles, error: cyclesError } = await adminA.rpc('list_cycles_for_admin', {
      target_kuri_id: kuriId,
    })
    expect(cyclesError).toBeNull()
    expect(cycles).toHaveLength(1)
    cycleId = cycles[0].id

    const { data: membership, error: membershipError } = await adminA.rpc(
      'create_membership_for_admin',
      {
        target_kuri_id: kuriId,
        target_person_id: env('TEST_PERSON_A_ID'),
        target_membership_number: `E2E-${suffix}`,
      },
    )
    expect(membershipError).toBeNull()
    expect(membership).toBeTruthy()
    membershipId = membership as string

    const { data: installments, error: installmentsError } = await adminA.rpc(
      'list_installments_for_cycle_admin',
      { target_cycle_id: cycleId },
    )
    expect(installmentsError).toBeNull()
    const ownInstallment = installments.find((row: { membership_id: string }) => row.membership_id === membershipId)
    expect(ownInstallment).toBeTruthy()
    installmentId = ownInstallment.id

    const { data: payment, error: paymentError } = await adminA.rpc('create_payment_for_admin', {
      target_kuri_id: kuriId,
      target_person_id: env('TEST_PERSON_A_ID'),
      payment_amount: 100,
      payment_date: new Date().toISOString(),
      payment_method: 'CASH',
      payment_reference: `E2E-${suffix}`,
      payment_notes: 'Disposable authenticated integration fixture',
      p_idempotency_key: `E2E-PAYMENT-CREATE-${suffix}`,
    })
    expect(paymentError).toBeNull()
    expect(payment).toBeTruthy()
    paymentId = payment as string

    const { data: allocation, error: allocationError } = await adminA.rpc(
      'allocate_payment_for_admin',
      {
        target_payment_id: paymentId,
        target_installment_id: installmentId,
        allocation_amount: 100,
        p_idempotency_key: `E2E-PAYMENT-ALLOC-${suffix}`,
      },
    )
    expect(allocationError).toBeNull()
    expect(allocation).toBe(100)

    const { data: cycleOpen, error: cycleOpenError } = await adminA.rpc(
      'transition_cycle_status_for_admin',
      { target_cycle_id: cycleId, target_status: 'OPEN' },
    )
    expect(cycleOpenError).toBeNull()
    expect(cycleOpen).toBe('OPEN')

    const { data: paymentClosed, error: paymentClosedError } = await adminA.rpc(
      'transition_cycle_status_for_admin',
      { target_cycle_id: cycleId, target_status: 'PAYMENT_CLOSED' },
    )
    expect(paymentClosedError).toBeNull()
    expect(paymentClosed).toBe('PAYMENT_CLOSED')

    const { data: drawPending, error: drawPendingError } = await adminA.rpc(
      'transition_cycle_status_for_admin',
      { target_cycle_id: cycleId, target_status: 'DRAW_PENDING' },
    )
    expect(drawPendingError).toBeNull()
    expect(drawPending).toBe('DRAW_PENDING')

    const { data: drawSession, error: prepareDrawError } = await adminA.rpc(
      'prepare_draw_for_admin',
      { target_cycle_id: cycleId },
    )
    expect(prepareDrawError).toBeNull()
    expect(drawSession).toBeTruthy()
    drawSessionId = drawSession as string

    const drawAttempts = await Promise.all([
      adminA.rpc('run_random_draw_for_admin', {
      target_cycle_id: cycleId,
      selection_count: 1,
      p_idempotency_key: `DRAW-RUN-${suffix}`,
    }),
      adminA.rpc('run_random_draw_for_admin', {
      target_cycle_id: cycleId,
      selection_count: 1,
      p_idempotency_key: `DRAW-RUN-${suffix}`,
    }),
    ])
    const successfulDraws = drawAttempts.filter((attempt) => !attempt.error)
    const failedDraws = drawAttempts.filter((attempt) => !!attempt.error)
    expect(successfulDraws).toHaveLength(2)
    expect(failedDraws).toHaveLength(0)

    const selections = successfulDraws[0].data
    expect(selections).toHaveLength(1)
    expect(selections[0].membership_id).toBe(membershipId)

    const { data: winnerCount, error: finalizeError } = await adminA.rpc('finalize_draw_for_admin', {
        target_cycle_id: cycleId,
        final_membership_ids: [membershipId],
        p_idempotency_key: `DRAW-FINALIZE-${suffix}`,
      })
    expect(finalizeError).toBeNull()
    expect(winnerCount).toBe(1)

    const { data: winners, error: winnersError } = await adminA.rpc('get_monthly_winners_for_admin', {
      target_cycle_id: cycleId,
    })
    expect(winnersError).toBeNull()
    expect(winners).toHaveLength(1)
    winnerId = winners[0].winner_id

    const { data: completedCycle, error: completedCycleError } = await adminA.rpc(
      'get_cycle_for_admin',
      { target_cycle_id: cycleId },
    )
    expect(completedCycleError).toBeNull()
    expect(completedCycle).toBeTruthy()
    expect(completedCycle[0].status).toBe('COMPLETED')

    const { data: preparedPayout, error: payoutPrepareError } = await adminA.rpc(
      'prepare_payout_for_admin',
      { target_winner_id: winnerId },
    )
    expect(payoutPrepareError).toBeNull()
    expect(preparedPayout).toBeTruthy()
    payoutId = preparedPayout as string

    const payoutAttempts = await Promise.all([
      adminA.rpc('mark_payout_paid_for_admin', {
        target_winner_id: winnerId,
        payout_payment_date: '2026-09-25T12:00:00.000Z',
        payout_method: 'CASH',
        p_idempotency_key: `E2E-PAYOUT-${suffix}`,
        payout_reference: `E2E-PAYOUT-${suffix}`,
        payout_notes: 'Disposable authenticated integration fixture',
        payout_other_deductions: 0,
      }),
      adminA.rpc('mark_payout_paid_for_admin', {
        target_winner_id: winnerId,
        payout_payment_date: '2026-09-25T12:00:00.000Z',
        payout_method: 'CASH',
        p_idempotency_key: `E2E-PAYOUT-${suffix}`,
        payout_reference: `E2E-PAYOUT-${suffix}`,
        payout_notes: 'Disposable authenticated integration fixture',
        payout_other_deductions: 0,
      }),
    ])
    expect(payoutAttempts.filter((attempt) => !attempt.error)).toHaveLength(2)
    expect(payoutAttempts.filter((attempt) => !!attempt.error)).toHaveLength(0)

    const { data: payout, error: payoutGetError } = await adminA.rpc('get_payout_for_admin', {
      target_winner_id: winnerId,
    })
    expect(payoutGetError).toBeNull()
    expect(payout).toHaveLength(1)
    expect(payout[0].payout_id).toBe(payoutId)
    expect(payout[0].status).toBe('PAID')
    expect(payout[0].net_amount).toBe(100)
    expect(payout[0].expense_deductions).toBe(0)

    const { data: enrollmentClosedAt, error: enrollmentCloseError } = await adminA.rpc(
      'close_kuri_enrollment_for_admin',
      { target_kuri_id: kuriId },
    )
    expect(enrollmentCloseError).toBeNull()
    expect(enrollmentClosedAt).toBeTruthy()

    const { data: changedPayout, error: changedPayoutError } = await adminA.rpc('mark_payout_paid_for_admin', {
      target_winner_id: winnerId,
      payout_payment_date: '2026-09-25T12:00:00.000Z',
      payout_method: 'CASH',
      p_idempotency_key: `E2E-PAYOUT-${suffix}`,
      payout_reference: `E2E-PAYOUT-DIFFERENT-${suffix}`,
      payout_notes: 'Disposable authenticated integration fixture',
      payout_other_deductions: 0,
    })
    expect(changedPayout).toBeNull()
    expect(changedPayoutError?.message).toContain('Idempotency key was already used for a different payout request.')

    const { data: finalKuri, error: finalKuriError } = await adminA.rpc(
      'transition_kuri_status_for_admin',
      { target_kuri_id: kuriId, target_status: 'ACTIVE' },
    )
    expect(finalKuriError).toBeNull()
    expect(finalKuri).toBe('ACTIVE')

    // The fixture is now in a terminal-safe business state for later cleanup:
    // completed cycle + paid payout + active Kuri.
    expect(drawSessionId).toBeTruthy()
  })
})
