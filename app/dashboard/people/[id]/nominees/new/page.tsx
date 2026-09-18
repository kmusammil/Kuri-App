import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createNominee } from "../actions";

export default async function NewNomineePage({params,searchParams}:{params:Promise<{id:string}>;searchParams:Promise<{error?:string}>}) {
  const {id}=await params;
  const s=await createClient();
  const {data:{user}}=await s.auth.getUser();
  if(!user) redirect("/login");
  const {data:rows}=await s.rpc("get_person_for_admin",{target_person_id:id});
  const person=rows?.[0];
  if(!person) redirect("/dashboard/people");
  const q=await searchParams;
  return <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900"><div className="mx-auto max-w-3xl">
    <div className="flex items-center justify-between"><div><p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p><h1 className="mt-2 text-3xl font-bold">Add nominee</h1><p className="mt-2 text-sm text-slate-600">For {person.display_name||person.registered_name}</p></div><Link href={"/dashboard/people/"+id} className="rounded-lg border px-4 py-2.5">Back</Link></div>
    {q.error?<div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{q.error}</div>:null}
    <form action={createNominee} className="mt-6 space-y-5 rounded-2xl border bg-white p-6 shadow-sm"><input type="hidden" name="person_id" value={id}/><label className="block text-sm font-medium">Name<input required name="name" className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label><label className="block text-sm font-medium">Relationship<input name="relationship" className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label><label className="block text-sm font-medium">Phone<input name="phone" className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label><label className="block text-sm font-medium">Address<textarea name="address" rows={3} className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label><label className="block text-sm font-medium">Notes<textarea name="notes" rows={3} className="mt-2 w-full rounded-lg border px-3 py-2.5"/></label><button className="rounded-lg bg-slate-900 px-4 py-2.5 text-white">Save nominee</button></form>
  </div></main>;
}