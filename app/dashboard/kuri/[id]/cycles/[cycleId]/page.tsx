import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { prepareDraw, setPoolEntry, runRandomDraw } from "./actions";

export default async function CycleDetailPage({ params, searchParams }: { params: Promise<{ id: string; cycleId: string }>; searchParams: Promise<{ error?: string }> }) {
  const { id, cycleId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: contextRows } = await supabase.rpc("current_user_membership");
  const membership = contextRows?.[0];
  if (!membership?.organization_id || !["MAIN_ADMIN","ADMIN"].includes(membership.role)) redirect("/dashboard");

  const { data: cycleRows, error: cycleError } = await supabase.rpc("get_cycle_for_admin",{target_cycle_id:cycleId});
  if (cycleError) redirect("/dashboard/kuri/"+id+"?error="+encodeURIComponent(cycleError.message));
  const cycle=cycleRows?.[0];
  if(!cycle || cycle.kuri_id!==id) notFound();

  const { data: installmentRows } = await supabase.rpc("list_installments_for_cycle_admin",{target_cycle_id:cycleId});
  const { data: drawSessionRows } = await supabase.rpc("get_draw_session_for_admin",{target_cycle_id:cycleId});
  const { data: poolRows, error: poolError } = await supabase.rpc("list_draw_pool_for_admin",{target_cycle_id:cycleId});
  const query=await searchParams;
  const session=drawSessionRows?.[0];
  const { data: selections } = await supabase.rpc("get_draw_selections_for_admin",{target_cycle_id:cycleId});

  return <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900"><div className="mx-auto max-w-6xl">
    <div className="flex items-center justify-between gap-4"><div><p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p><h1 className="mt-2 text-3xl font-bold">Cycle {cycle.cycle_number}</h1><p className="mt-2 text-sm text-slate-600">{cycle.period_start} → {cycle.period_end}</p></div><Link href={`/dashboard/kuri/${id}`} className="rounded-lg border px-4 py-2.5">Back to Kuri</Link></div>
    {query.error?<div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{query.error}</div>:null}
    <section className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">{[
      ["Due date",cycle.due_date],["Draw date",cycle.draw_date],["Installments",String(installmentRows?.length??0)],["Status",cycle.status]
    ].map(([label,value])=><div key={label} className="rounded-2xl border bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">{label}</p><p className="mt-2 text-lg font-semibold">{value}</p></div>)}</section>
    <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm"><h2 className="text-lg font-semibold">Installments</h2><div className="mt-5 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b text-slate-500"><th className="px-3 py-3">Membership</th><th className="px-3 py-3">Person</th><th className="px-3 py-3">Due</th><th className="px-3 py-3">Paid</th><th className="px-3 py-3">Balance</th><th className="px-3 py-3">Status</th></tr></thead><tbody>{(installmentRows??[]).map(i=><tr key={i.id} className="border-b last:border-0"><td className="px-3 py-3">{i.membership_number}</td><td className="px-3 py-3">{i.display_name||i.registered_name}</td><td className="px-3 py-3">₹{Number(i.amount_due).toLocaleString("en-IN")}</td><td className="px-3 py-3">₹{Number(i.amount_paid).toLocaleString("en-IN")}</td><td className="px-3 py-3">₹{Math.max(Number(i.amount_due)-Number(i.amount_paid),0).toLocaleString("en-IN")}</td><td className="px-3 py-3">{i.status}</td></tr>)}</tbody></table></div></section>
    <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm"><div className="flex items-center justify-between"><div><h2 className="text-lg font-semibold">Monthly Draw</h2><p className="mt-1 text-sm text-slate-600">Prepare the pool, include or exclude memberships, then run the random draw.</p></div>{!session?<form action={prepareDraw}><input type="hidden" name="cycle_id" value={cycleId}/><button className="rounded-lg bg-slate-900 px-4 py-2.5 text-white">Prepare draw</button></form>:null}</div>
      {poolError?<div className="mt-4 text-sm text-red-700">{poolError.message}</div>:session?<><div className="mt-5 flex items-center gap-4 text-sm"><span>Session: <strong>{session.status}</strong></span>{session.status!=="RESULTS_READY"&&session.status!=="FINALIZED"?<form action={runRandomDraw}><input type="hidden" name="cycle_id" value={cycleId}/><input type="hidden" name="selection_count" value="1"/><button className="rounded-lg bg-slate-900 px-4 py-2 text-white">Run random draw</button></form>:null}</div>
      <div className="mt-5 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b text-slate-500"><th className="px-3 py-3">Membership</th><th className="px-3 py-3">Person</th><th className="px-3 py-3">System eligible</th><th className="px-3 py-3">Included</th><th className="px-3 py-3">Override</th><th className="px-3 py-3">Action</th></tr></thead><tbody>{(poolRows??[]).map(e=><tr key={e.entry_id} className="border-b last:border-0"><td className="px-3 py-3">{e.membership_number}</td><td className="px-3 py-3">{e.display_name||e.registered_name}</td><td className="px-3 py-3">{e.system_eligible?"Yes":"No"}</td><td className="px-3 py-3">{e.admin_included?"Yes":"No"}</td><td className="px-3 py-3">{e.override?"Yes":"No"}</td><td className="px-3 py-3"><form action={setPoolEntry}><input type="hidden" name="entry_id" value={e.entry_id}/><input type="hidden" name="cycle_id" value={cycleId}/><input type="hidden" name="include" value={e.admin_included?"false":"true"}/><button className="underline">{e.admin_included?"Exclude":"Include"}</button></form></td></tr>)}</tbody></table></div>
      {selections.length?<div className="mt-5 rounded-xl border p-4"><p className="font-semibold">Random selections</p>{selections.map(s=><p key={s.selection_id} className="mt-2 text-sm">Selection {s.selection_order}: {s.display_name || s.registered_name} · Membership {s.membership_number}</p>)}</div>:null}</>:null}
    </section>
  </div></main>;
}