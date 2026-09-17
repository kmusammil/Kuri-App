import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function CycleDetailPage({
  params,
}: {
  params: Promise<{ id: string; cycleId: string }>;
}) {
  const { id, cycleId } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: contextRows, error: contextError } = await supabase.rpc(
    "current_user_membership",
  );
  if (contextError) {
    console.error("Cycle detail workspace lookup failed:", contextError);
    redirect("/dashboard?error=Unable%20to%20verify%20workspace%20membership.");
  }

  const membership = contextRows?.[0];
  if (!membership?.organization_id) redirect("/workspace");
  if (membership.role !== "MAIN_ADMIN" && membership.role !== "ADMIN") {
    redirect(
      "/dashboard?error=You%20do%20not%20have%20permission%20to%20view%20this%20cycle.",
    );
  }

  const { data: cycleRows, error: cycleError } = await supabase.rpc(
    "get_cycle_for_admin",
    { target_cycle_id: cycleId },
  );
  if (cycleError) {
    console.error("Cycle detail RPC failed:", cycleError);
    redirect(`/dashboard/kuri/${id}?error=${encodeURIComponent(`Unable to load cycle: ${cycleError.message}`)}`);
  }

  const cycle = cycleRows?.[0];
  if (!cycle || cycle.kuri_id !== id) notFound();

  const { data: installmentRows, error: installmentsError } = await supabase.rpc(
    "list_installments_for_cycle_admin",
    { target_cycle_id: cycleId },
  );
  const installmentLoadError = installmentsError?.message ?? null;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">
              Kuri-App
            </p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">
              Cycle {cycle.cycle_number}
            </h1>
            <p className="mt-2 text-sm text-slate-600">
              {cycle.period_start} → {cycle.period_end}
            </p>
          </div>
          <Link
            href={`/dashboard/kuri/${id}`}
            className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium"
          >
            Back to Kuri
          </Link>
        </div>

        <section className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Due date</p>
            <p className="mt-2 text-lg font-semibold">{cycle.due_date}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Draw date</p>
            <p className="mt-2 text-lg font-semibold">{cycle.draw_date}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Installments</p>
            <p className="mt-2 text-lg font-semibold">{installmentRows?.length ?? 0}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Status</p>
            <p className="mt-2 text-lg font-semibold">{cycle.status}</p>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Installments</h2>
          <p className="mt-1 text-sm text-slate-600">
            Payment status for every membership in this cycle.
          </p>

          {installmentLoadError ? (
            <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
              Unable to load installments: {installmentLoadError}
            </div>
          ) : installmentRows?.length ? (
            <div className="mt-5 overflow-x-auto">
              <table className="w-full text-left text-sm">
                <thead>
                  <tr className="border-b border-slate-200 text-slate-500">
                    <th className="px-3 py-3 font-medium">Membership</th>
                    <th className="px-3 py-3 font-medium">Person</th>
                    <th className="px-3 py-3 font-medium">Due</th>
                    <th className="px-3 py-3 font-medium">Paid</th>
                    <th className="px-3 py-3 font-medium">Balance</th>
                    <th className="px-3 py-3 font-medium">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {installmentRows.map((item) => {
                    const amountDue = Number(item.amount_due ?? 0);
                    const amountPaid = Number(item.amount_paid ?? 0);
                    return (
                      <tr key={item.id} className="border-b border-slate-100 last:border-0">
                        <td className="px-3 py-3 font-medium">{item.membership_number}</td>
                        <td className="px-3 py-3">
                          {item.display_name || item.registered_name}
                          {item.display_name ? (
                            <span className="ml-2 text-slate-400">({item.registered_name})</span>
                          ) : null}
                        </td>
                        <td className="px-3 py-3">₹{amountDue.toLocaleString("en-IN")}</td>
                        <td className="px-3 py-3">₹{amountPaid.toLocaleString("en-IN")}</td>
                        <td className="px-3 py-3">₹{Math.max(amountDue - amountPaid, 0).toLocaleString("en-IN")}</td>
                        <td className="px-3 py-3">{item.status}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="mt-5 rounded-xl border border-dashed border-slate-300 p-8 text-center text-sm text-slate-600">
              No installments found for this cycle.
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
