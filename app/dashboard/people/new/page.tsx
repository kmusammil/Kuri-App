import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createPerson } from "../actions";

export default async function NewPersonPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: contextRows, error: contextError } = await supabase.rpc(
    "current_user_membership",
  );
  if (contextError) {
    redirect("/dashboard?error=Unable%20to%20verify%20workspace%20membership.");
  }

  const membership = contextRows?.[0];
  if (!membership?.organization_id) redirect("/workspace");
  const canManagePeople = membership.role === "MAIN_ADMIN" || membership.role === "ADMIN";
  const params = await searchParams;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-3xl">
        <div className="mb-6 flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">Add person</h1>
            <p className="mt-2 text-sm text-slate-600">Register a person who can later hold one or more Kuri memberships.</p>
          </div>
          <Link href="/dashboard" className="text-sm font-medium underline">Dashboard</Link>
        </div>

        {params.error ? (
          <div className="mb-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{params.error}</div>
        ) : null}

        {!canManagePeople ? (
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-sm text-amber-800">Your workspace role does not permit adding people.</div>
        ) : (
          <form action={createPerson} className="space-y-6">
            <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
              <h2 className="text-lg font-semibold">Identity</h2>
              <div className="mt-5 space-y-4">
                <div>
                  <label htmlFor="registered_name" className="block text-sm font-medium">Registered / original name</label>
                  <input id="registered_name" name="registered_name" required className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" placeholder="Full legal or registered name" />
                  <p className="mt-1 text-xs text-slate-500">Required and treated as the private/original name.</p>
                </div>
                <div>
                  <label htmlFor="display_name" className="block text-sm font-medium">Display / alias name <span className="font-normal text-slate-400">(optional)</span></label>
                  <input id="display_name" name="display_name" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" placeholder="Name to show in everyday views" />
                </div>
              </div>
            </section>

            <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
              <h2 className="text-lg font-semibold">Contact details</h2>
              <div className="mt-5 grid gap-4 sm:grid-cols-2">
                <div>
                  <label htmlFor="phone" className="block text-sm font-medium">Phone <span className="font-normal text-slate-400">(optional)</span></label>
                  <input id="phone" name="phone" type="tel" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" placeholder="Phone number" />
                </div>
                <div>
                  <label htmlFor="email" className="block text-sm font-medium">Email <span className="font-normal text-slate-400">(optional)</span></label>
                  <input id="email" name="email" type="email" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" placeholder="Email address" />
                </div>
                <div className="sm:col-span-2">
                  <label htmlFor="address" className="block text-sm font-medium">Address <span className="font-normal text-slate-400">(optional)</span></label>
                  <textarea id="address" name="address" rows={3} className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
                </div>
              </div>
            </section>

            <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
              <label htmlFor="notes" className="block text-sm font-medium">Notes <span className="font-normal text-slate-400">(optional)</span></label>
              <textarea id="notes" name="notes" rows={4} className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
            </section>

            <div className="flex items-center justify-end gap-3">
              <Link href="/dashboard/people" className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium">Cancel</Link>
              <button type="submit" className="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-medium text-white">Save person</button>
            </div>
          </form>
        )}
      </div>
    </main>
  );
}
