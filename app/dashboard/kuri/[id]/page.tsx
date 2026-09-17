import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function KuriDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
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

  const { data: kuri } = await supabase
    .from("kuris")
    .select("id, name, description, start_date, number_of_cycles, membership_limit, installment_amount, frequency, due_day, draw_day, gross_prize_amount, muppu_amount, winner_rule, exit_refund_rule, status")
    .eq("id", id)
    .eq("organization_id", membership.organization_id)
    .maybeSingle();

  if (!kuri) notFound();

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">{kuri.name}</h1>
            {kuri.description ? <p className="mt-2 text-sm text-slate-600">{kuri.description}</p> : null}
          </div>
          <Link href="/dashboard/kuri" className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium">All Kuris</Link>
        </div>

        <section className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Status</p><p className="mt-2 text-xl font-semibold">{kuri.status}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Cycles</p><p className="mt-2 text-xl font-semibold">{kuri.number_of_cycles}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Membership limit</p><p className="mt-2 text-xl font-semibold">{kuri.membership_limit}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm text-slate-500">Frequency</p><p className="mt-2 text-xl font-semibold">{kuri.frequency}</p></div>
        </section>

        <section className="mt-6 grid gap-6 lg:grid-cols-2">
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Financial rules</h2>
            <dl className="mt-4 space-y-3 text-sm">
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Installment</dt><dd className="font-medium">₹{kuri.installment_amount.toLocaleString("en-IN")}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Gross prize</dt><dd className="font-medium">₹{kuri.gross_prize_amount.toLocaleString("en-IN")}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Muppu</dt><dd className="font-medium">₹{kuri.muppu_amount.toLocaleString("en-IN")}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Due day</dt><dd className="font-medium">Day {kuri.due_day}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Draw day</dt><dd className="font-medium">Day {kuri.draw_day}</dd></div>
            </dl>
          </div>

          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Rules</h2>
            <dl className="mt-4 space-y-3 text-sm">
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Winner rule</dt><dd className="text-right font-medium">{kuri.winner_rule}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Exit refund</dt><dd className="text-right font-medium">{kuri.exit_refund_rule}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Start date</dt><dd className="font-medium">{kuri.start_date}</dd></div>
            </dl>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Next</h2>
          <p className="mt-2 text-sm text-slate-600">The next layers will create memberships, generate cycles and installments, record payments, and run monthly draws.</p>
        </section>
      </div>
    </main>
  );
}
