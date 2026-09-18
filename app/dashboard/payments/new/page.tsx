import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createPayment } from "../actions";

export default async function NewPaymentPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: people, error } = await supabase.rpc("list_people_for_admin");
  if (error) redirect("/dashboard/payments?error=" + encodeURIComponent(error.message));
  const params = await searchParams;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900"><div className="mx-auto max-w-3xl">
      <div className="flex items-center justify-between"><div><p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p><h1 className="mt-2 text-3xl font-bold">Record payment</h1></div><Link href="/dashboard/payments" className="rounded-lg border px-4 py-2.5">Back</Link></div>
      {params.error ? <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{params.error}</div> : null}
      <form action={createPayment} className="mt-6 space-y-5 rounded-2xl border bg-white p-6 shadow-sm">
        <div><label className="text-sm font-medium">Person</label><select name="person_id" required className="mt-2 w-full rounded-lg border px-3 py-2.5"><option value="">Select person</option>{people?.map(p => <option key={p.id} value={p.id}>{p.display_name || p.registered_name}</option>)}</select></div>
        <div className="grid gap-5 sm:grid-cols-2"><div><label className="text-sm font-medium">Amount (₹)</label><input name="amount" type="number" min="1" step="1" required className="mt-2 w-full rounded-lg border px-3 py-2.5"/></div><div><label className="text-sm font-medium">Payment date</label><input name="payment_date" type="datetime-local" required className="mt-2 w-full rounded-lg border px-3 py-2.5"/></div></div>
        <div><label className="text-sm font-medium">Method</label><select name="method" required className="mt-2 w-full rounded-lg border px-3 py-2.5"><option value="">Select method</option><option value="UPI">UPI</option><option value="BANK_TRANSFER">Bank transfer</option><option value="CASH">Cash</option><option value="OTHER">Other</option></select></div>
        <div><label className="text-sm font-medium">Reference number <span className="text-slate-400">(optional)</span></label><input name="reference_number" className="mt-2 w-full rounded-lg border px-3 py-2.5"/></div>
        <div><label className="text-sm font-medium">Notes <span className="text-slate-400">(optional)</span></label><textarea name="notes" rows={3} className="mt-2 w-full rounded-lg border px-3 py-2.5"/></div>
        <button type="submit" className="w-full rounded-lg bg-slate-900 px-4 py-3 text-white">Record payment</button>
      </form>
    </div></main>
  );
}