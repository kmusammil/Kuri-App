import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createExit, approveExit, recordImmediateRefund, settleExit } from "./actions";

export default async function MembershipExitsPage({
  params, searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ error?: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: kuriRows } = await supabase.rpc("get_kuri_for_admin",{target_kuri_id:id});
  const kuri=kuriRows?.[0];
  if(!kuri) redirect("/dashboard/kuri");
  const [{data:memberships},{data:exits,error}]=await Promise.all([
    supabase.rpc("list_memberships_for_admin",{target_kuri_id:id}),
    supabase.rpc("list_membership_exits_for_admin",{target_kuri_id:id}),
  ]);
  const query=await searchParams;
  return <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900"><div className="mx-auto max-w-6xl">
    <div className="flex items-center justify-between gap-4"><div><p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p><h1 className="mt-2 text-3xl font-bold">Membership Exits</h1><p className="mt-2 text-sm text-slate-600">{kuri.name}</p></div><Link href={`/dashboard/kuri/${id}`} className="rounded-lg border px-4 py-2.5">Back to Kuri</Link></div>
    {query.error?<div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{query.error}</div>:null}
    <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm"><h2 className="text-lg font-semibold">Create exit</h2><p className="mt-1 text-sm text-slate-600">Record a voluntary exit, death, or other membership settlement case. The default refund policy is at maturity.</p>
      <form action={createExit} className="mt-5 grid gap-4 md:grid-cols-2"><input type="hidden" name="kuri_id" value={id}/>
        <label className="text-sm font-medium">Membership<select name="membership_id" required className="mt-2 w-full rounded-lg border px-3 py-2.5">{(memberships??[]).filter(m=>m.status!=="EXITED").map(m=><option key={m.id} value={m.id}>{m.membership_number} — {m.display_name||m.registered_name} ({m.status})</option>)}</select></label>
        <label className="text-sm font-medium">Reason<select name="reason" className="mt-2 w-full rounded-lg border px-3 py-2.5"><option value="VOLUNTARY_EXIT">Voluntary exit</option><option value="DEATH">Death</option><option value="OTHER">Other</option></select></label>
        <label className="text-sm font-medium">Exit date<input name="exit_date" type="date" required className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label>
        <label className="text-sm font-medium">Refund policy<select name="refund_policy" className="mt-2 w-full rounded-lg border px-3 py-2.5"><option value="AT_MATURITY">At maturity</option><option value="IMMEDIATE">Immediate</option></select></label>
        <label className="text-sm font-medium">Refund amount (optional)<input name="refund_amount" type="number" min="0" step="1" className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label>
        <label className="text-sm font-medium md:col-span-2">Notes<textarea name="notes" rows={3} className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label>
        <button className="w-fit rounded-lg bg-slate-900 px-4 py-2.5 text-white">Create exit</button>
      </form>
    </section>
    <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm"><h2 className="text-lg font-semibold">Exit records</h2>{error?<p className="mt-4 text-sm text-red-700">{error.message}</p>:exits?.length?<div className="mt-5 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b text-slate-500"><th className="px-3 py-3">Membership</th><th className="px-3 py-3">Person</th><th className="px-3 py-3">Reason</th><th className="px-3 py-3">Contributed</th><th className="px-3 py-3">Refund</th><th className="px-3 py-3">Policy</th><th className="px-3 py-3">Status</th><th className="px-3 py-3">Action</th></tr></thead><tbody>{exits.map(e=><tr key={e.exit_id} className="border-b last:border-0"><td className="px-3 py-3">{e.membership_number}</td><td className="px-3 py-3">{e.display_name||e.registered_name}</td><td className="px-3 py-3">{e.reason}</td><td className="px-3 py-3">₹{Number(e.amount_contributed).toLocaleString("en-IN")}</td><td className="px-3 py-3">₹{Number(e.refund_amount).toLocaleString("en-IN")}</td><td className="px-3 py-3">{e.refund_policy}</td><td className="px-3 py-3">{e.status}</td><td className="px-3 py-3"><div className="flex flex-wrap items-center gap-3">{e.status==="PENDING"?<form action={approveExit}><input type="hidden" name="kuri_id" value={id}/><input type="hidden" name="exit_id" value={e.exit_id}/><button className="underline">Approve</button></form>:null}{e.status==="APPROVED"&&e.refund_policy==="IMMEDIATE"?<form action={recordImmediateRefund} className="flex flex-wrap items-center gap-2"><input type="hidden" name="kuri_id" value={id}/><input type="hidden" name="exit_id" value={e.exit_id}/><input name="refund_amount" type="number" min="1" step="1" defaultValue={e.refund_amount} className="w-28 rounded border px-2 py-1" placeholder="Amount" required/><select name="refund_method" className="rounded border px-2 py-1" defaultValue="UPI"><option value="UPI">UPI</option><option value="BANK_TRANSFER">Bank transfer</option><option value="CASH">Cash</option><option value="OTHER">Other</option></select><input name="refund_reference" className="w-36 rounded border px-2 py-1" placeholder="Reference"/><input name="refund_notes" className="w-40 rounded border px-2 py-1" placeholder="Notes"/><button className="underline">Record refund</button></form>:null}{e.status==="APPROVED"&&e.refund_policy==="AT_MATURITY"?<form action={settleExit}><input type="hidden" name="kuri_id" value={id}/><input type="hidden" name="exit_id" value={e.exit_id}/><input name="settlement_reference" className="w-36 rounded border px-2 py-1" placeholder="Reference"/><button className="underline">Settle</button></form>:null}{e.status==="SETTLED"?<span className="text-slate-500">Settled</span>:null}</div></td></tr>)}</tbody></table></div>:<p className="mt-4 text-sm text-slate-600">No exit records.</p>}</section>
  </div></main>;
}