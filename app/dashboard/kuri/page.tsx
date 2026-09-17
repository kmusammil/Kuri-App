import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function KuriListPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: membership } = await supabase
    .from("organization_users")
    .select("organization_id, role")
    .eq("user_id", user.id)
    .in("role", ["MAIN_ADMIN", "ADMIN"])
    .limit(1)
    .maybeSingle();

  if (!membership?.organization_id) redirect("/workspace");

  const { data: kuris } = await supabase
    .from("kuris")
    .select("id, name, description, start_date, number_of_cycles, membership_limit, installment_amount, gross_prize_amount, status")
    .eq("organization_id", membership.organization_id)
    .order("created_at", { ascending: false });

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">Kuri schemes</h1>
            <p className="mt-2 text-sm text-slate-600">Create and manage your Kuri schemes.</p>
          </div>
          <div className="flex gap-3">
            <Link href="/dashboard" className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium">Dashboard</Link>
            <Link href="/dashboard/kuri/new" className="rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white">Create Kuri</Link>
          </div>
        </div>

        {kuris?.length ? (
          <div className="mt-6 grid gap-4 md:grid-cols-2">
            {kuris.map((kuri) => (
              <Link key={kuri.id} href={`/dashboard/kuri/${kuri.id}`} className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm hover:border-slate-400">
                <div className="flex items-start justify-between gap-4">
                  <div>
                    <h2 className="text-lg font-semibold">{kuri.name}</h2>
                    {kuri.description ? <p className="mt-1 text-sm text-slate-600">{kuri.description}</p> : null}
                  </div>
                  <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-medium">{kuri.status}</span>
                </div>
                <div className="mt-5 grid grid-cols-2 gap-3 text-sm">
                  <div><p className="text-slate-500">Starts</p><p className="font-medium">{kuri.start_date}</p></div>
                  <div><p className="text-slate-500">Cycles</p><p className="font-medium">{kuri.number_of_cycles}</p></div>
                  <div><p className="text-slate-500">Membership limit</p><p className="font-medium">{kuri.membership_limit}</p></div>
                  <div><p className="text-slate-500">Installment</p><p className="font-medium">₹{kuri.installment_amount.toLocaleString("en-IN")}</p></div>
                </div>
              </Link>
            ))}
          </div>
        ) : (
          <div className="mt-6 rounded-2xl border border-dashed border-slate-300 bg-white p-10 text-center">
            <h2 className="text-lg font-semibold">No Kuri schemes yet</h2>
            <p className="mt-2 text-sm text-slate-600">Create your first scheme to begin adding memberships and cycles.</p>
            <Link href="/dashboard/kuri/new" className="mt-5 inline-block rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white">Create your first Kuri</Link>
          </div>
        )}
      </div>
    </main>
  );
}
