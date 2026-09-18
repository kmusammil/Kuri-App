import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function PaymentsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: payments, error } = await supabase.rpc("list_payments_for_admin");

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div><p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p><h1 className="mt-2 text-3xl font-bold">Payments</h1><p className="mt-2 text-sm text-slate-600">Record payments and allocate them to installments.</p></div>
          <div className="flex gap-3"><Link href="/dashboard" className="rounded-lg border px-4 py-2.5">Dashboard</Link><Link href="/dashboard/payments/new" className="rounded-lg bg-slate-900 px-4 py-2.5 text-white">Record payment</Link></div>
        </div>
        {error ? <div className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{error.message}</div> : payments?.length ? (
          <div className="mt-6 overflow-x-auto rounded-2xl border bg-white shadow-sm"><table className="w-full text-left text-sm"><thead><tr className="border-b text-slate-500"><th className="px-4 py-3">Person</th><th className="px-4 py-3">Amount</th><th className="px-4 py-3">Date</th><th className="px-4 py-3">Method</th><th className="px-4 py-3">Status</th></tr></thead><tbody>
            {payments.map((p) => <tr key={p.id} className="border-b last:border-0"><td className="px-4 py-3 font-medium"><Link className="underline" href={"/dashboard/payments/" + p.id}>{p.display_name || p.registered_name}</Link></td><td className="px-4 py-3">₹{Number(p.amount).toLocaleString("en-IN")}</td><td className="px-4 py-3">{new Date(p.payment_date).toLocaleString("en-IN")}</td><td className="px-4 py-3">{p.method}</td><td className="px-4 py-3">{p.status}</td></tr>)}
          </tbody></table></div>
        ) : <div className="mt-6 rounded-2xl border border-dashed bg-white p-10 text-center text-sm text-slate-600">No payments recorded yet.</div>}
      </div>
    </main>
  );
}