import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { allocatePayment } from "../actions";

export default async function PaymentDetailPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ error?: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const [{ data: paymentRows, error: paymentError }, { data: allocations, error: allocationError }] = await Promise.all([
    supabase.rpc("get_payment_for_admin", { target_payment_id: id }),
    supabase.rpc("list_payment_allocations_for_admin", { target_payment_id: id }),
  ]);
  if (paymentError) redirect("/dashboard/payments?error=" + encodeURIComponent(paymentError.message));
  const payment = paymentRows?.[0];
  if (!payment) notFound();

  const { data: installments, error: installmentsError } = await supabase.rpc("list_installments_for_person_payment_admin", { target_person_id: payment.person_id });
  const query = await searchParams;
  const allocated = (allocations || []).reduce((sum, item) => sum + Number(item.amount || 0), 0);
  const remaining = Math.max(Number(payment.amount) - allocated, 0);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900"><div className="mx-auto max-w-5xl">
      <div className="flex items-center justify-between"><div><p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p><h1 className="mt-2 text-3xl font-bold">Payment</h1><p className="mt-2 text-sm text-slate-600">{payment.display_name || payment.registered_name}</p></div><Link href="/dashboard/payments" className="rounded-lg border px-4 py-2.5">Back</Link></div>
      {query.error ? <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{query.error}</div> : null}
      <section className="mt-6 grid gap-4 sm:grid-cols-4">
        <div className="rounded-2xl border bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Amount</p><p className="mt-2 text-xl font-semibold">₹{Number(payment.amount).toLocaleString("en-IN")}</p></div>
        <div className="rounded-2xl border bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Allocated</p><p className="mt-2 text-xl font-semibold">₹{allocated.toLocaleString("en-IN")}</p></div>
        <div className="rounded-2xl border bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Remaining</p><p className="mt-2 text-xl font-semibold">₹{remaining.toLocaleString("en-IN")}</p></div>
        <div className="rounded-2xl border bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Method</p><p className="mt-2 text-xl font-semibold">{payment.method}</p></div>
      </section>
      <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm"><h2 className="text-lg font-semibold">Allocations</h2>{allocationError ? <p className="mt-4 text-sm text-red-700">{allocationError.message}</p> : allocations?.length ? <div className="mt-4 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b text-slate-500"><th className="px-3 py-3">Kuri</th><th className="px-3 py-3">Cycle</th><th className="px-3 py-3">Membership</th><th className="px-3 py-3">Amount</th></tr></thead><tbody>{allocations.map(a => <tr key={a.id} className="border-b last:border-0"><td className="px-3 py-3">{a.kuri_name}</td><td className="px-3 py-3">Cycle {a.cycle_number}</td><td className="px-3 py-3">{a.membership_number}</td><td className="px-3 py-3">₹{Number(a.amount).toLocaleString("en-IN")}</td></tr>)}</tbody></table></div> : <p className="mt-4 text-sm text-slate-600">Nothing allocated yet.</p>}</section>
      <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm"><h2 className="text-lg font-semibold">Allocate to installment</h2><p className="mt-1 text-sm text-slate-600">Outstanding installments for this person.</p>{installmentsError ? <p className="mt-4 text-sm text-red-700">{installmentsError.message}</p> : installments?.length ? <form action={allocatePayment} className="mt-5 grid gap-4 sm:grid-cols-[1fr_180px_auto] sm:items-end"><input type="hidden" name="payment_id" value={id}/><div><label className="text-sm font-medium">Installment</label><select name="installment_id" required className="mt-2 w-full rounded-lg border px-3 py-2.5">{installments.map(i => <option key={i.id} value={i.id}>{i.kuri_name} · Cycle {i.cycle_number} · {i.membership_number} · Balance ₹{Number(i.balance).toLocaleString("en-IN")}</option>)}</select></div><div><label className="text-sm font-medium">Amount (₹)</label><input name="allocation_amount" type="number" min="1" max={remaining} required disabled={remaining <= 0} className="mt-2 w-full rounded-lg border px-3 py-2.5"/></div><button type="submit" disabled={remaining <= 0} className="rounded-lg bg-slate-900 px-4 py-2.5 text-white disabled:opacity-50">Allocate</button></form> : <p className="mt-4 text-sm text-slate-600">No outstanding installments for this person.</p>}</section>
    </div></main>
  );
}