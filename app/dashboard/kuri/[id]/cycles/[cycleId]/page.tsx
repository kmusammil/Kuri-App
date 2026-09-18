import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { prepareDraw, setPoolEntry, runRandomDraw, finalizeDraw } from "./actions";

export default async function CycleDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string; cycleId: string }>;
  searchParams: Promise<{ error?: string }>;
}) {
  const { id, cycleId } = await params;
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: cycleRows, error: cycleError } = await supabase.rpc(
    "get_cycle_for_admin",
    { target_cycle_id: cycleId },
  );
  if (cycleError) {
    redirect(
      `/dashboard/kuri/${id}?error=${encodeURIComponent(cycleError.message)}`,
    );
  }

  const cycle = cycleRows?.[0];
  if (!cycle || cycle.kuri_id !== id) notFound();

  const [
    { data: installmentRows },
    { data: drawSessionRows },
    { data: poolRows, error: poolError },
    { data: winnerRows, error: winnerError },
  ] = await Promise.all([
    supabase.rpc("list_installments_for_cycle_admin", {
      target_cycle_id: cycleId,
    }),
    supabase.rpc("get_draw_session_for_admin", {
      target_cycle_id: cycleId,
    }),
    supabase.rpc("list_draw_pool_for_admin", {
      target_cycle_id: cycleId,
    }),
    supabase.rpc("get_monthly_winners_for_admin", {
      target_cycle_id: cycleId,
    }),
  ]);

  const session = drawSessionRows?.[0];
  const { data: selections } = session
    ? await supabase.rpc("get_draw_selections_for_admin", {
        target_cycle_id: cycleId,
      })
    : { data: [] };

  const query = await searchParams;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">
              Kuri-App
            </p>
            <h1 className="mt-2 text-3xl font-bold">Cycle {cycle.cycle_number}</h1>
            <p className="mt-2 text-sm text-slate-600">
              {cycle.period_start} → {cycle.period_end}
            </p>
          </div>
          <Link
            href={`/dashboard/kuri/${id}`}
            className="rounded-lg border px-4 py-2.5"
          >
            Back to Kuri
          </Link>
        </div>

        {query.error ? (
          <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
            {query.error}
          </div>
        ) : null}

        <section className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          {[
            ["Due date", cycle.due_date],
            ["Draw date", cycle.draw_date],
            ["Installments", String(installmentRows?.length ?? 0)],
            ["Status", cycle.status],
          ].map(([label, value]) => (
            <div key={label} className="rounded-2xl border bg-white p-5 shadow-sm">
              <p className="text-sm text-slate-500">{label}</p>
              <p className="mt-2 text-lg font-semibold">{value}</p>
            </div>
          ))}
        </section>

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Installments</h2>
          <div className="mt-5 overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="border-b text-slate-500">
                  <th className="px-3 py-3">Membership</th>
                  <th className="px-3 py-3">Person</th>
                  <th className="px-3 py-3">Due</th>
                  <th className="px-3 py-3">Paid</th>
                  <th className="px-3 py-3">Balance</th>
                  <th className="px-3 py-3">Status</th>
                </tr>
              </thead>
              <tbody>
                {(installmentRows ?? []).map((item) => (
                  <tr key={item.id} className="border-b last:border-0">
                    <td className="px-3 py-3">{item.membership_number}</td>
                    <td className="px-3 py-3">
                      {item.display_name || item.registered_name}
                    </td>
                    <td className="px-3 py-3">
                      ₹{Number(item.amount_due).toLocaleString("en-IN")}
                    </td>
                    <td className="px-3 py-3">
                      ₹{Number(item.amount_paid).toLocaleString("en-IN")}
                    </td>
                    <td className="px-3 py-3">
                      ₹
                      {Math.max(
                        Number(item.amount_due) - Number(item.amount_paid),
                        0,
                      ).toLocaleString("en-IN")}
                    </td>
                    <td className="px-3 py-3">{item.status}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold">Monthly Draw</h2>
              <p className="mt-1 text-sm text-slate-600">
                Prepare the pool, include or exclude memberships, run the random
                draw, then finalize the winner(s).
              </p>
            </div>

            {!session ? (
              <form action={prepareDraw}>
                <input type="hidden" name="cycle_id" value={cycleId} />
                <input type="hidden" name="kuri_id" value={id} />
                <button className="rounded-lg bg-slate-900 px-4 py-2.5 text-white">
                  Prepare draw
                </button>
              </form>
            ) : session.status !== "FINALIZED" ? (
              <div className="flex items-center gap-2">
                <span className="text-sm font-medium">{session.status}</span>
                <form action={prepareDraw}>
                  <input type="hidden" name="cycle_id" value={cycleId} />
                  <input type="hidden" name="kuri_id" value={id} />
                  <button className="rounded-lg border px-4 py-2">
                    Reset pool
                  </button>
                </form>
              </div>
            ) : (
              <span className="text-sm font-medium">FINALIZED</span>
            )}
          </div>

          {poolError ? (
            <div className="mt-4 text-sm text-red-700">{poolError.message}</div>
          ) : session ? (
            <>
              {session.status !== "FINALIZED" ? (
                <div className="mt-5">
                  <form action={runRandomDraw}>
                    <input type="hidden" name="cycle_id" value={cycleId} />
                    <input type="hidden" name="kuri_id" value={id} />
                    <input type="hidden" name="selection_count" value="1" />
                    <button className="rounded-lg bg-slate-900 px-4 py-2 text-white">
                      Run random draw
                    </button>
                  </form>
                </div>
              ) : null}

              <div className="mt-5 overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr className="border-b text-slate-500">
                      <th className="px-3 py-3">Membership</th>
                      <th className="px-3 py-3">Person</th>
                      <th className="px-3 py-3">System eligible</th>
                      <th className="px-3 py-3">Included</th>
                      <th className="px-3 py-3">Override</th>
                      <th className="px-3 py-3">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(poolRows ?? []).map((entry) => (
                      <tr key={entry.entry_id} className="border-b last:border-0">
                        <td className="px-3 py-3">{entry.membership_number}</td>
                        <td className="px-3 py-3">
                          {entry.display_name || entry.registered_name}
                        </td>
                        <td className="px-3 py-3">
                          {entry.system_eligible ? "Yes" : "No"}
                        </td>
                        <td className="px-3 py-3">
                          {entry.admin_included ? "Yes" : "No"}
                        </td>
                        <td className="px-3 py-3">
                          {entry.override ? "Yes" : "No"}
                        </td>
                        <td className="px-3 py-3">
                          {session.status !== "FINALIZED" ? (
                            <form action={setPoolEntry}>
                              <input
                                type="hidden"
                                name="entry_id"
                                value={entry.entry_id}
                              />
                              <input
                                type="hidden"
                                name="cycle_id"
                                value={cycleId}
                              />
                              <input type="hidden" name="kuri_id" value={id} />
                              <input
                                type="hidden"
                                name="include"
                                value={entry.admin_included ? "false" : "true"}
                              />
                              <button className="underline">
                                {entry.admin_included ? "Exclude" : "Include"}
                              </button>
                            </form>
                          ) : (
                            <span>Locked</span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              {selections?.length ? (
                <div className="mt-5 rounded-xl border p-4">
                  <p className="font-semibold">Random selections</p>
                  {selections.map((selection) => (
                    <p
                      key={selection.selection_id}
                      className="mt-2 text-sm"
                    >
                      Selection {selection.selection_order}:{" "}
                      {selection.display_name || selection.registered_name} ·
                      Membership {selection.membership_number}
                    </p>
                  ))}

                  {session.status !== "FINALIZED" ? (
                    <form action={finalizeDraw} className="mt-4">
                      <input type="hidden" name="cycle_id" value={cycleId} />
                      <input type="hidden" name="kuri_id" value={id} />
                      <input
                        type="hidden"
                        name="membership_ids"
                        value={selections.map((s) => s.membership_id).join(",")}
                      />
                      <button className="rounded-lg bg-slate-900 px-4 py-2 text-white">
                        Finalize selected winner(s)
                      </button>
                    </form>
                  ) : null}
                </div>
              ) : null}
            </>
          ) : null}
        </section>

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold">Payouts</h2>
              <p className="mt-1 text-sm text-slate-600">Manage winner payout records from the dedicated payouts area.</p>
            </div>
            <Link href="/dashboard/payouts" className="rounded-lg border px-4 py-2.5">Open Payouts</Link>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Monthly Winners</h2>
          {winnerError ? (
            <p className="mt-4 text-sm text-red-700">{winnerError.message}</p>
          ) : winnerRows?.length ? (
            <div className="mt-4 overflow-x-auto">
              <table className="w-full text-left text-sm">
                <thead>
                  <tr className="border-b text-slate-500">
                    <th className="px-3 py-3">Person</th>
                    <th className="px-3 py-3">Membership(s)</th>
                    <th className="px-3 py-3">Source</th>
                    <th className="px-3 py-3">Finalized</th>
                  </tr>
                </thead>
                <tbody>
                  {winnerRows.map((winner) => (
                    <tr key={winner.winner_id} className="border-b last:border-0">
                      <td className="px-3 py-3">
                        {winner.display_name || winner.registered_name}
                      </td>
                      <td className="px-3 py-3">{winner.membership_numbers}</td>
                      <td className="px-3 py-3">{winner.selection_source}</td>
                      <td className="px-3 py-3">
                        {new Date(winner.finalized_at).toLocaleString("en-IN")}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="mt-4 text-sm text-slate-600">
              No monthly winner finalized for this cycle.
            </p>
          )}
        </section>
      </div>
    </main>
  );
}