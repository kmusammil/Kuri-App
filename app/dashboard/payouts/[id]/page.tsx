import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { markPayoutPaid } from "../actions";

export default async function PayoutDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ error?: string }>;
}) {
  const { id } = await params;
  const query = await searchParams;
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  let { data: rows, error } = await supabase.rpc("get_payout_for_admin", {
    target_winner_id: id,
  });

  if (error) {
    redirect("/dashboard/payouts?error=" + encodeURIComponent(error.message));
  }

  if (!rows?.[0]) {
    const { error: prepareError } = await supabase.rpc("prepare_payout_for_admin", {
      target_winner_id: id,
    });

    if (prepareError) {
      redirect(
        "/dashboard/payouts?error=" + encodeURIComponent(prepareError.message),
      );
    }

    const refreshed = await supabase.rpc("get_payout_for_admin", {
      target_winner_id: id,
    });

    if (refreshed.error) {
      redirect(
        "/dashboard/payouts?error=" +
          encodeURIComponent(refreshed.error.message),
      );
    }

    rows = refreshed.data;
  }

  const payout = rows?.[0];
  if (!payout) notFound();

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-3xl">
        <header className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">
              Kuri-App
            </p>
            <h1 className="mt-2 text-3xl font-bold">Payout</h1>
            <p className="mt-2 text-sm">
              {payout.display_name || payout.registered_name}
            </p>
          </div>
          <Link
            href="/dashboard/payouts"
            className="rounded-lg border px-4 py-2.5"
          >
            Back
          </Link>
        </header>

        {query.error ? (
          <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
            {query.error}
          </div>
        ) : null}

        <section className="mt-6 grid gap-4 sm:grid-cols-4">
          <div className="rounded-2xl border bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Gross</p>
            <p className="mt-2 text-xl font-semibold">
              ₹{Number(payout.gross_amount).toLocaleString("en-IN")}
            </p>
          </div>
          <div className="rounded-2xl border bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Muppu</p>
            <p className="mt-2 text-xl font-semibold">
              ₹{Number(payout.muppu_amount).toLocaleString("en-IN")}
            </p>
          </div>
          <div className="rounded-2xl border bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Other deductions</p>
            <p className="mt-2 text-xl font-semibold">
              ₹{Number(payout.other_deductions).toLocaleString("en-IN")}
            </p>
          </div>
          <div className="rounded-2xl border bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Net</p>
            <p className="mt-2 text-xl font-semibold">
              ₹{Number(payout.net_amount).toLocaleString("en-IN")}
            </p>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <p>
            Status: <strong>{payout.status}</strong>
          </p>
          {payout.status !== "PAID" ? (
            <form action={markPayoutPaid} className="mt-5 space-y-4">
              <input type="hidden" name="winner_id" value={id} />
              <label className="block text-sm font-medium">
                Payment date
                <input
                  className="mt-2 w-full rounded-lg border px-3 py-2.5"
                  type="datetime-local"
                  name="payment_date"
                  required
                />
              </label>
              <label className="block text-sm font-medium">
                Method
                <select
                  className="mt-2 w-full rounded-lg border px-3 py-2.5"
                  name="method"
                  required
                >
                  <option value="UPI">UPI</option>
                  <option value="BANK_TRANSFER">Bank transfer</option>
                  <option value="CASH">Cash</option>
                  <option value="OTHER">Other</option>
                </select>
              </label>
              <label className="block text-sm font-medium">
                Other deductions (₹)
                <input
                  className="mt-2 w-full rounded-lg border px-3 py-2.5"
                  type="number"
                  min="0"
                  step="1"
                  defaultValue="0"
                  name="other_deductions"
                />
              </label>
              <label className="block text-sm font-medium">
                Reference
                <input
                  className="mt-2 w-full rounded-lg border px-3 py-2.5"
                  name="reference"
                />
              </label>
              <label className="block text-sm font-medium">
                Notes
                <textarea
                  className="mt-2 w-full rounded-lg border px-3 py-2.5"
                  rows={3}
                  name="notes"
                />
              </label>
              <button
                className="rounded-lg bg-slate-900 px-4 py-3 text-white"
                type="submit"
              >
                Mark payout paid
              </button>
            </form>
          ) : (
            <p className="mt-4 text-sm text-slate-600">
              This payout has been completed.
            </p>
          )}
        </section>
      </div>
    </main>
  );
}