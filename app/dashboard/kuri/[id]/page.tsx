import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function KuriDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ error?: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: contextRows, error: contextError } = await supabase.rpc(
    "current_user_membership",
  );

  if (contextError) {
    console.error("Kuri detail workspace lookup failed:", contextError);
    redirect("/dashboard?error=Unable%20to%20verify%20workspace%20membership.");
  }

  const membership = contextRows?.[0];
  if (!membership?.organization_id) redirect("/workspace");
  if (membership.role !== "MAIN_ADMIN" && membership.role !== "ADMIN") {
    redirect(
      "/dashboard?error=You%20do%20not%20have%20permission%20to%20view%20this%20Kuri.",
    );
  }

  const { data: rows, error: kuriError } = await supabase.rpc(
    "get_kuri_for_admin",
    { target_kuri_id: id },
  );

  if (kuriError) {
    console.error("Kuri detail RPC failed:", kuriError);
    redirect("/dashboard?error=Unable%20to%20load%20the%20Kuri.");
  }

  const kuri = rows?.[0];
  if (!kuri) notFound();

  const { data: memberships, error: membershipsError } = await supabase.rpc(
    "list_memberships_for_admin",
    { target_kuri_id: id },
  );

  const membershipLoadError = membershipsError?.message ?? null;

  const { data: cycles, error: cyclesError } = await supabase.rpc(
    "list_cycles_for_admin",
    { target_kuri_id: id },
  );

  const cycleLoadError = cyclesError?.message ?? null;
  const paramsData = await searchParams;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">
              Kuri-App
            </p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">{kuri.name}</h1><p className="mt-3"><Link href={`/dashboard/payments`} className="text-sm font-medium underline">Payments</Link></p>
            {kuri.description ? (
              <p className="mt-2 text-sm text-slate-600">{kuri.description}</p>
            ) : null}
          </div>
          <Link
            href="/dashboard/kuri"
            className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium"
          >
            All Kuris
          </Link>
        </div>

        {paramsData.error ? (
          <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
            {paramsData.error}
          </div>
        ) : null}

        <section className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Status</p>
            <p className="mt-2 text-xl font-semibold">{kuri.status}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Cycles</p>
            <p className="mt-2 text-xl font-semibold">{kuri.number_of_cycles}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Membership limit</p>
            <p className="mt-2 text-xl font-semibold">{kuri.membership_limit}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Frequency</p>
            <p className="mt-2 text-xl font-semibold">{kuri.frequency}</p>
          </div>
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
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold">Memberships</h2>
              <p className="mt-1 text-sm text-slate-600">Add people to this Kuri and assign membership numbers.</p>
            </div>
            <Link href={`/dashboard/kuri/${id}/memberships/new`} className="rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white">Add membership</Link>
            <Link href={`/dashboard/kuri/${id}/exits`} className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium">Membership exits</Link>
          </div>
          {membershipLoadError ? (
            <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">Unable to load memberships: {membershipLoadError}</div>
          ) : memberships?.length ? (
            <div className="mt-5 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b border-slate-200 text-slate-500"><th className="px-3 py-3 font-medium">No.</th><th className="px-3 py-3 font-medium">Person</th><th className="px-3 py-3 font-medium">Status</th></tr></thead><tbody>{memberships.map((item) => <tr key={item.id} className="border-b border-slate-100 last:border-0"><td className="px-3 py-3 font-medium">{item.membership_number}</td><td className="px-3 py-3">{item.display_name || item.registered_name}{item.display_name ? <span className="ml-2 text-slate-400">({item.registered_name})</span> : null}</td><td className="px-3 py-3">{item.status}</td></tr>)}</tbody></table></div>
          ) : <div className="mt-5 rounded-xl border border-dashed border-slate-300 p-8 text-center text-sm text-slate-600">No memberships yet.</div>}
        </section>

        <section className="mt-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold">Cycles & Installments</h2>
              <p className="mt-1 text-sm text-slate-600">Generate the monthly schedule after memberships are added.</p>
            </div>
            {!cycles?.length ? (
              <form action={generateSchedule}>
                <input type="hidden" name="kuri_id" value={id} />
                <button type="submit" className="rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white">Generate schedule</button>
              </form>
            ) : null}
          </div>
          {cycleLoadError ? (
            <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">Unable to load cycles: {cycleLoadError}</div>
          ) : cycles?.length ? (
            <div className="mt-5 overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b border-slate-200 text-slate-500"><th className="px-3 py-3 font-medium">Cycle</th><th className="px-3 py-3 font-medium">Period</th><th className="px-3 py-3 font-medium">Due</th><th className="px-3 py-3 font-medium">Draw</th><th className="px-3 py-3 font-medium">Installments</th><th className="px-3 py-3 font-medium">Status</th></tr></thead><tbody>{cycles.map((cycle) => <tr key={cycle.id} className="border-b border-slate-100 last:border-0"><td className="px-3 py-3 font-medium"><Link className="underline underline-offset-2" href={`/dashboard/kuri/${id}/cycles/${cycle.id}`}>Cycle {cycle.cycle_number}</Link></td><td className="px-3 py-3">{cycle.period_start} → {cycle.period_end}</td><td className="px-3 py-3">{cycle.due_date}</td><td className="px-3 py-3">{cycle.draw_date}</td><td className="px-3 py-3">{cycle.installment_count}</td><td className="px-3 py-3">{cycle.status}</td></tr>)}</tbody></table></div>
          ) : <div className="mt-5 rounded-xl border border-dashed border-slate-300 p-8 text-center text-sm text-slate-600">No cycles generated yet.</div>}
        </section>
      </div>
    </main>
  );
}

async function generateSchedule(formData: FormData) {
  "use server";
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const kuriId = String(formData.get("kuri_id") ?? "").trim();
  if (!kuriId) redirect("/dashboard/kuri");

  const { error } = await supabase.rpc("generate_kuri_schedule_for_admin", {
    target_kuri_id: kuriId,
  });

  if (error) {
    console.error("Kuri schedule generation failed:", error);
    redirect(`/dashboard/kuri/${kuriId}?error=${encodeURIComponent(`Unable to generate schedule: ${error.message}`)}`);
  }

  redirect(`/dashboard/kuri/${kuriId}`);
}
