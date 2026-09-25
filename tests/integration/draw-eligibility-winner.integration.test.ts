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

describe('Kuri-App draw eligibility and winner invariants', () => {
  let adminA: SupabaseClient
  let adminB: SupabaseClient

  beforeAll(async () => {
    ;[adminA, adminB] = await Promise.all([
      signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD')),
      signIn(env('TEST_ADMIN_A_EMAIL'), env('TEST_ADMIN_A_PASSWORD')),
    ])
  })

  it('freezes draw eligibility, handles concurrent preparation, and enforces winner invariants', async () => {
    const suffix = Date.now().toString()
    const startDate = new Date().toISOString().slice(0, 10)

    const { data: kuri, error: kuriError } = await adminA.rpc('create_kuri_for_admin', {
      name: `Draw Invariants ${suffix}`,
      description: 'Disposable draw eligibility and winner invariant fixture',
      start_date: startDate,
      number_of_cycles: 2,
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
    expect(generated).toBe(2)

    const { error: openError } = await adminA.rpc('transition_kuri_status_for_admin', {
      target_kuri_id: kuriId,
      target_status: 'OPEN',
    })
    expect(openError).toBeNull()

    const memberships = await Promise.all([
      adminA.rpc('create_membership_for_admin', {
        target_kuri_id: kuriId,
        target_person_id: env('TEST_PERSON_A_ID'),
        target_membership_number: `DRAW-A-${suffix}`,
      }),
      adminA.rpc('create_membership_for_admin', {
        target_kuri_id: kuriId,
        target_person_id: env('TEST_PERSON_B_ID'),
        target_membership_number: `DRAW-B-${suffix}`,
      }),
    ])
    memberships.forEach((result) => {
      expect(result.error).toBeNull()
      expect(result.data).toBeTruthy()
    })
    const membershipA = memberships[0].data as string
    const membershipB = memberships[1].data as string

    const { data: cycles, error: cyclesError } = await adminA.rpc('list_cycles_for_admin', {
      target_kuri_id: kuriId,
    })
    expect(cyclesError).toBeNull()
    expect(cycles).toHaveLength(2)
    const cycle1 = cycles.find((row: { cycle_number: number }) => row.cycle_number === 1)
    const cycle2 = cycles.find((row: { cycle_number: number }) => row.cycle_number === 2)
    expect(cycle1).toBeTruthy()
    expect(cycle2).toBeTruthy()

    const setCycleState = async (cycleId: string, status: 'OPEN' | 'PAYMENT_CLOSED' | 'DRAW_PENDING') => {
      for (const target of ['OPEN', 'PAYMENT_CLOSED', 'DRAW_PENDING'] as const) {
        const { error } = await adminA.rpc('transition_cycle_status_for_admin', {
          target_cycle_id: cycleId,
          target_status: target,
        })
        expect(error).toBeNull()
      }
      expect(status).toBe('DRAW_PENDING')
    }

    await setCycleState(cycle1.id, 'DRAW_PENDING')

    const listInstallments = async (cycleId: string) => {
      const { data, error } = await adminA.rpc('list_installments_for_cycle_admin', {
        target_cycle_id: cycleId,
      })
      expect(error).toBeNull()
      return data as Array<{ id: string; membership_id: string; amount_due: number }>
    }

    const cycle1Installments = await listInstallments(cycle1.id)

    const payAndAllocate = async (membershipId: string, installmentId: string, label: string) => {
      const { data: payment, error: paymentError } = await adminA.rpc('create_payment_for_admin', {
        target_kuri_id: kuriId,
        target_person_id: membershipId === membershipA ? env('TEST_PERSON_A_ID') : env('TEST_PERSON_B_ID'),
        payment_amount: 100,
        payment_date: new Date().toISOString(),
        payment_method: 'CASH',
        payment_reference: label,
        payment_notes: 'Disposable draw invariant fixture',
        idempotency_key: `${label}-CREATE`,
      })
      expect(paymentError).toBeNull()
      expect(payment).toBeTruthy()

      const { data: paid, error: allocationError } = await adminA.rpc('allocate_payment_for_admin', {
        target_payment_id: payment,
        target_installment_id: installmentId,
        allocation_amount: 100,
        idempotency_key: `${label}-ALLOC`,
      })
      expect(allocationError).toBeNull()
      expect(paid).toBe(100)
      return payment as string
    }

    const i1a = cycle1Installments.find((row) => row.membership_id === membershipA)
    const i1b = cycle1Installments.find((row) => row.membership_id === membershipB)
    expect(i1a).toBeTruthy()
    expect(i1b).toBeTruthy()

    await Promise.all([
      payAndAllocate(membershipA, i1a.id, `DRAW-${suffix}-A1`),
      payAndAllocate(membershipB, i1b.id, `DRAW-${suffix}-B1`),
    ])

    const prepareAttempts = await Promise.all([
      adminA.rpc('prepare_draw_for_admin', { target_cycle_id: cycle1.id }),
      adminB.rpc('prepare_draw_for_admin', { target_cycle_id: cycle1.id }),
    ])
    prepareAttempts.forEach((result) => {
      expect(result.error).toBeNull()
      expect(result.data).toBeTruthy()
    })
    expect(prepareAttempts[0].data).toBe(prepareAttempts[1].data)

    const { data: poolBefore, error: poolBeforeError } = await adminA.rpc(
      'list_draw_pool_for_admin',
      { target_cycle_id: cycle1.id },
    )
    expect(poolBeforeError).toBeNull()
    const poolB = poolBefore.find((row: { membership_id: string }) => row.membership_id === membershipB)
    expect(poolB?.system_eligible).toBe(true)
    expect(poolB?.admin_included).toBe(true)

    const paymentB1 = await adminA.rpc('list_payment_allocations_for_admin', {
      target_payment_id: (await adminA.rpc('list_payments_for_admin', { target_kuri_id: kuriId })).data
        .find((row: { reference_number: string }) => row.reference_number === `DRAW-${suffix}-B1`).id,
    })
    expect(paymentB1.error).toBeNull()
    const allocationB1 = paymentB1.data[0]

    const reversal = await adminA.rpc('create_payment_reversal_request_for_admin', {
      target_payment_id: (await adminA.rpc('list_payments_for_admin', { target_kuri_id: kuriId })).data
        .find((row: { reference_number: string }) => row.reference_number === `DRAW-${suffix}-B1`).id,
      reversal_amount: 100,
      target_allocation_id: allocationB1.id,
      reason: 'Test eligibility freeze after POOL_READY',
    })
    expect(reversal.error).toBeNull()
    expect(reversal.data).toBeTruthy()

    const approve = await adminA.rpc('approve_payment_adjustment_request_for_admin', {
      target_request_id: reversal.data,
    })
    expect(approve.error).toBeNull()

    const execute = await adminA.rpc('execute_payment_adjustment_request_for_admin', {
      target_request_id: reversal.data,
    })
    expect(execute.error).toBeNull()

    const { data: poolAfter, error: poolAfterError } = await adminA.rpc(
      'list_draw_pool_for_admin',
      { target_cycle_id: cycle1.id },
    )
    expect(poolAfterError).toBeNull()
    const poolBAfter = poolAfter.find((row: { membership_id: string }) => row.membership_id === membershipB)
    expect(poolBAfter?.system_eligible).toBe(true)
    expect(poolBAfter?.admin_included).toBe(true)

    const { data: preparedAgain, error: prepareAgainError } = await adminA.rpc(
      'prepare_draw_for_admin',
      { target_cycle_id: cycle1.id },
    )
    expect(prepareAgainError).toBeNull()
    expect(preparedAgain).toBe(prepareAttempts[0].data)

    const drawAfterFreeze = await adminA.rpc('run_random_draw_for_admin', {
      target_cycle_id: cycle1.id,
      selection_count: 2,
    })
    expect(drawAfterFreeze.error).toBeNull()
    expect(drawAfterFreeze.data).toHaveLength(2)

    const selected = drawAfterFreeze.data as Array<{ membership_id: string }>
    expect(selected.map((row) => row.membership_id).sort()).toEqual([membershipA, membershipB].sort())

    const tooManyWinners = await adminA.rpc('finalize_draw_for_admin', {
      target_cycle_id: cycle1.id,
      final_membership_ids: [membershipA, membershipB],
    })
    expect(tooManyWinners.data).toBeNull()
    expect(tooManyWinners.error?.message).toContain('maximum feasible winner count')

    const winner = selected[0].membership_id
    const losingMembership = selected[1].membership_id

    const finalizeRace = await Promise.all([
      adminA.rpc('finalize_draw_for_admin', {
        target_cycle_id: cycle1.id,
        final_membership_ids: [winner],
      }),
      adminB.rpc('finalize_draw_for_admin', {
        target_cycle_id: cycle1.id,
        final_membership_ids: [winner],
      }),
    ])
    expect(finalizeRace.filter((result) => !result.error)).toHaveLength(1)
    expect(finalizeRace.filter((result) => !!result.error)).toHaveLength(1)

    const winnerForCycle2 = winner
    const otherForCycle2 = losingMembership

    await setCycleState(cycle2.id, 'DRAW_PENDING')

    const cycle2Installments = await listInstallments(cycle2.id)
    const i2winner = cycle2Installments.find((row) => row.membership_id === winnerForCycle2)
    const i2other = cycle2Installments.find((row) => row.membership_id === otherForCycle2)
    expect(i2winner).toBeTruthy()
    expect(i2other).toBeTruthy()

    await Promise.all([
      payAndAllocate(winnerForCycle2, i2winner.id, `DRAW-${suffix}-A2`),
      payAndAllocate(otherForCycle2, i2other.id, `DRAW-${suffix}-B2`),
    ])

    const prepared2 = await adminA.rpc('prepare_draw_for_admin', { target_cycle_id: cycle2.id })
    expect(prepared2.error).toBeNull()

    const draw2 = await adminA.rpc('run_random_draw_for_admin', {
      target_cycle_id: cycle2.id,
      selection_count: 2,
    })
    expect(draw2.error).toBeNull()
    expect(draw2.data).toHaveLength(2)

    const repeatAttempt = await adminA.rpc('finalize_draw_for_admin', {
      target_cycle_id: cycle2.id,
      final_membership_ids: [winnerForCycle2],
    })
    expect(repeatAttempt.data).toBeNull()
    expect(repeatAttempt.error?.message).toContain('already won in this Kuri')

    const validCycle2Winner = draw2.data.find(
      (row: { membership_id: string }) => row.membership_id === otherForCycle2,
    )
    expect(validCycle2Winner).toBeTruthy()

    const finalizeCycle2 = await adminA.rpc('finalize_draw_for_admin', {
      target_cycle_id: cycle2.id,
      final_membership_ids: [otherForCycle2],
    })
    expect(finalizeCycle2.error).toBeNull()
    expect(finalizeCycle2.data).toBe(1)
  })
})
