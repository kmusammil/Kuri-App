import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createKuri } from "../actions";

export default async function NewKuriPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id, role, organizations(name)")
    .eq("user_id", user.id)
    .in("role", ["MAIN_ADMIN", "ADMIN"])
    .limit(1)
    .maybeSingle();

  if (!membership?.organization_id) redirect("/workspace");

  const params = await searchParams;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-3xl">
        <div className="mb-6 flex items-center justify-between">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">Create Kuri</h1>
            <p className="mt-2 text-sm text-slate-600">Set the core rules for a new monthly Kuri scheme.</p>
          </div>
          <Link href="/dashboard" className="text-sm font-medium underline">Back to dashboard</Link>
        </div>

        <form action={createKuri} className="space-y-6">
          {params.error ? (
            <div className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{params.error}</div>
          ) : null}

          <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Basic details</h2>
            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <div className="sm:col-span-2">
                <label htmlFor="name" className="block text-sm font-medium">Kuri name</label>
                <input id="name" name="name" required placeholder="e.g. Family Kuri 2026" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div className="sm:col-span-2">
                <label htmlFor="description" className="block text-sm font-medium">Description <span className="font-normal text-slate-400">(optional)</span></label>
                <textarea id="description" name="description" rows={3} className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div>
                <label htmlFor="start_date" className="block text-sm font-medium">Start date</label>
                <input id="start_date" name="start_date" type="date" required className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div>
                <label htmlFor="number_of_cycles" className="block text-sm font-medium">Number of cycles</label>
                <input id="number_of_cycles" name="number_of_cycles" type="number" min="1" required placeholder="12" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
            </div>
          </section>

          <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Membership and payment</h2>
            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <div>
                <label htmlFor="membership_limit" className="block text-sm font-medium">Membership limit</label>
                <input id="membership_limit" name="membership_limit" type="number" min="1" required placeholder="100" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div>
                <label htmlFor="installment_amount" className="block text-sm font-medium">Installment amount (₹)</label>
                <input id="installment_amount" name="installment_amount" type="number" min="0" required placeholder="10000" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div>
                <label htmlFor="due_day" className="block text-sm font-medium">Monthly due day</label>
                <input id="due_day" name="due_day" type="number" min="1" max="31" required placeholder="10" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div>
                <label htmlFor="draw_day" className="block text-sm font-medium">Monthly draw day</label>
                <input id="draw_day" name="draw_day" type="number" min="1" max="31" required placeholder="15" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
            </div>
          </section>

          <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Prize and rules</h2>
            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <div>
                <label htmlFor="gross_prize_amount" className="block text-sm font-medium">Gross prize per membership (₹)</label>
                <input id="gross_prize_amount" name="gross_prize_amount" type="number" min="0" required placeholder="300000" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div>
                <label htmlFor="muppu_amount" className="block text-sm font-medium">Muppu per winning membership (₹)</label>
                <input id="muppu_amount" name="muppu_amount" type="number" min="0" required defaultValue="0" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <div>
                <label htmlFor="winner_rule" className="block text-sm font-medium">Winner rule</label>
                <select id="winner_rule" name="winner_rule" defaultValue="ALL_PERSON_MEMBERSHIPS" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm">
                  <option value="ALL_PERSON_MEMBERSHIPS">Award all of the person&apos;s memberships</option>
                  <option value="ONE_MEMBERSHIP">Award one membership only</option>
                </select>
              </div>
              <div>
                <label htmlFor="exit_refund_rule" className="block text-sm font-medium">Exit refund policy</label>
                <select id="exit_refund_rule" name="exit_refund_rule" defaultValue="AT_MATURITY" className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm">
                  <option value="AT_MATURITY">Refund at maturity (default)</option>
                  <option value="IMMEDIATE">Refund immediately</option>
                </select>
              </div>
            </div>
            <p className="mt-4 text-xs text-slate-500">Amounts are stored as whole rupees in the current foundation schema.</p>
          </section>

          <div className="flex items-center justify-end gap-3">
            <Link href="/dashboard" className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium">Cancel</Link>
            <button type="submit" className="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-medium text-white">Create Kuri</button>
          </div>
        </form>
      </div>
    </main>
  );
}
