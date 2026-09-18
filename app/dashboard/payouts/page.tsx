import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function PayoutsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: payouts, error } = await supabase.rpc("list_payouts_for_admin");

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <header className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold">Payouts</h1>
            <p className="mt-2 text-sm text-slate-600">Manage finalized winner payouts.</p>
          </div>
          <Link href="/dashboard" className="rounded-lg border px-4 py-2.5">Dashboard</Link>
        </header>

        {error ? <div className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error.message}</div> : null}

        {payouts?.length ? (
          <div className="mt-6 overflow-x-auto rounded-2xl border bg-white shadow-sm">
            <table className="w-full text-left text-sm">
              <thead><tr className="border-b text-slate-500"><th className="px-4 py-3">Person</th><th className="px-4 py-3">Cycle</th><th className="px-4 py-3">Gross</th><th className="px-4 py-3">Net</th><th className="px-4 py-3">Status</th></tr></thead>
              <tbody>
                {payouts.map((p) => (
                  <tr key={p.payout_id} className="border-b last:border-0">
                    <td className="px-4 py-3 font-medium"><Link className="underline" href={"/dashboard/payouts/" + p.winner_id}>{p.display_name || p.registered_name}</Link></td>
                    <td className="px-4 py-3">Cycle {p.cycle_number}</td>
                    <td className="px-4 py-3">₹{Number(p.gross_amount).toLocaleString("en-IN")}</td>
                    <td className="px-4 py-3">₹{Number(p.net_amount).toLocaleString("en-IN")}</td>
                    <td className="px-4 py-3">{p.status}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="mt-6 rounded-2xl border border-dashed bg-white p-10 text-center">
            <p className="font-medium">No payouts created yet.</p>
            <p className="mt-2 text-sm text-slate-600">Open a finalized winner from a cycle and create its payout.</p>
          </div>
        )}
      </div>
    </main>
  );
}