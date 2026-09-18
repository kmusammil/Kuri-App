import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createMuppu, markPaid, waive, deduct } from "./actions";

export default async function MuppuPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const query = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: records, error } = await supabase.rpc("list_muppu_records_for_admin");
  const { data: kuris } = await supabase.rpc("list_kuris_for_admin");
  const { data: people } = await supabase.rpc("list_people_for_admin");

  const cycleResults = await Promise.all(
    (kuris ?? []).map(async (k) => {
      const { data } = await supabase.rpc("list_cycles_for_admin", {
        target_kuri_id: k.id,
      });
      return (data ?? []).map((c) => ({ ...c, kuriName: k.name }));
    }),
  );
  const cycles = cycleResults.flat();

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold">Muppu</h1>
            <p className="mt-2 text-sm text-slate-600">Manage Muppu dues and settlements.</p>
          </div>
          <Link href="/dashboard" className="rounded-lg border px-4 py-2.5">Dashboard</Link>
        </div>

        {query.error ? <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{query.error}</div> : null}

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Create Muppu record</h2>
          <form action={createMuppu} className="mt-5 grid gap-4 md:grid-cols-4">
            <label className="text-sm font-medium">Kuri
              <select name="kuri_id" required className="mt-2 w-full rounded-lg border px-3 py-2.5">
                {(kuris ?? []).map((k) => <option key={k.id} value={k.id}>{k.name}</option>)}
              </select>
            </label>
            <label className="text-sm font-medium">Cycle
              <select name="cycle_id" required className="mt-2 w-full rounded-lg border px-3 py-2.5">
                <option value="">Select cycle</option>
                {cycles.map((c) => (
                  <option key={c.id} value={c.id}>{c.kuriName} — Cycle {c.cycle_number}</option>
                ))}
              </select>
            </label>
            <label className="text-sm font-medium">Person
              <select name="person_id" required className="mt-2 w-full rounded-lg border px-3 py-2.5">
                {(people ?? []).map((p) => <option key={p.id} value={p.id}>{p.display_name || p.registered_name}</option>)}
              </select>
            </label>
            <label className="text-sm font-medium">Amount
              <input name="amount" type="number" min="0" step="1" required className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <button className="w-fit rounded-lg bg-slate-900 px-4 py-2.5 text-white">Create</button>
          </form>
        </section>

        <section className="mt-6 overflow-x-auto rounded-2xl border bg-white shadow-sm">
          <table className="w-full text-left text-sm">
            <thead><tr className="border-b text-slate-500"><th className="px-4 py-3">Person</th><th className="px-4 py-3">Cycle</th><th className="px-4 py-3">Amount</th><th className="px-4 py-3">Status</th><th className="px-4 py-3">Action</th></tr></thead>
            <tbody>
              {error ? <tr><td className="px-4 py-4 text-red-700" colSpan={5}>{error.message}</td></tr> :
              records?.length ? records.map((r) => (
                <tr key={r.muppu_id} className="border-b last:border-0">
                  <td className="px-4 py-3">{r.display_name || r.registered_name}</td>
                  <td className="px-4 py-3">{r.cycle_number}</td>
                  <td className="px-4 py-3">₹{Number(r.amount).toLocaleString("en-IN")}</td>
                  <td className="px-4 py-3">{r.status}</td>
                  <td className="px-4 py-3">
                    {r.status === "UNPAID" ? <div className="flex flex-wrap gap-3">
                      <form action={markPaid}><input type="hidden" name="muppu_id" value={r.muppu_id}/><input name="reference" placeholder="Payment ref" className="w-32 rounded border px-2 py-1"/><button className="underline">Paid</button></form>
                      <form action={waive}><input type="hidden" name="muppu_id" value={r.muppu_id}/><input name="reference" placeholder="Waiver ref" className="w-32 rounded border px-2 py-1"/><button className="underline">Waive</button></form>
                      <form action={deduct}><input type="hidden" name="muppu_id" value={r.muppu_id}/><input name="reference" placeholder="Deduction ref" className="w-32 rounded border px-2 py-1"/><button className="underline">Deduct</button></form>
                    </div> : <span className="text-slate-500">{r.settlement_method || "Settled"}</span>}
                  </td>
                </tr>
              )) : <tr><td className="px-4 py-5 text-slate-600" colSpan={5}>No Muppu records.</td></tr>}
            </tbody>
          </table>
        </section>
      </div>
    </main>
  );
}
