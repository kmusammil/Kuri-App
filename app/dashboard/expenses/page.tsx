import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createExpenseRule, markPaid, waive, deduct } from "./actions";

type Kuri = { id: string; name: string; status: string };
type Obligation = {
  expense_obligation_id: string;
  expense_rule_id: string;
  expense_name: string;
  membership_id: string;
  membership_number: string;
  person_id: string;
  registered_name: string;
  cycle_id: string | null;
  cycle_number: number | null;
  amount: number;
  status: string;
  settled_at: string | null;
  settlement_reference: string | null;
  deducted_from_payout_id: string | null;
};
type Rule = {
  expense_rule_id: string;
  kuri_id: string;
  kuri_name: string;
  name: string;
  description: string | null;
  frequency: string;
  amount: number;
  active: boolean;
  recurrence_pattern: string | null;
  recurrence_interval: number | null;
  recurrence_start_date: string | null;
  recurrence_end_date: string | null;
};
type Payout = {
  payout_id: string;
  cycle_number: number;
  person_id: string;
  registered_name: string;
  display_name: string | null;
  gross_amount: number;
  net_amount: number;
  status: string;
};

export default async function ExpensesPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const query = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: kuris } = await supabase.rpc("list_kuris_for_admin");
  const kuriList = (kuris ?? []) as Kuri[];

  const [rulesResults, obligationResults, payoutResults] = await Promise.all([
    Promise.all(kuriList.map((k) => supabase.rpc("list_expense_rules_for_admin", { target_kuri_id: k.id }))),
    Promise.all(kuriList.map((k) => supabase.rpc("list_expense_obligations_for_admin", { target_kuri_id: k.id }))),
    Promise.all(kuriList.map((k) => supabase.rpc("list_payouts_for_admin", { target_kuri_id: k.id }))),
  ]);

  const rules = rulesResults.flatMap((r) => (r.data ?? []) as Rule[]);
  const obligations = obligationResults.flatMap((r) => (r.data ?? []) as Obligation[]);
  const payouts = payoutResults.flatMap((r) => (r.data ?? []) as Payout[]);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-7xl">
        <header className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold">Expenses</h1>
            <p className="mt-2 text-sm text-slate-600">
              Configure Expense rules and settle generated obligations. Historical Muppu records remain separate compatibility data.
            </p>
          </div>
          <Link href="/dashboard" className="rounded-lg border px-4 py-2.5">Dashboard</Link>
        </header>

        {query.error ? (
          <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">{query.error}</div>
        ) : null}

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Create Expense rule</h2>
          <p className="mt-1 text-sm text-slate-600">
            A rule generates Expense obligations for applicable memberships. It does not create a separate per-person Muppu record.
          </p>
          <form action={createExpenseRule} className="mt-5 grid gap-4 md:grid-cols-3">
            <label className="text-sm font-medium">Kuri
              <select name="kuri_id" required className="mt-2 w-full rounded-lg border px-3 py-2.5">
                {kuriList.map((k) => <option key={k.id} value={k.id}>{k.name} — {k.status}</option>)}
              </select>
            </label>
            <label className="text-sm font-medium">Name
              <input name="name" required placeholder="e.g. Prize Expense" className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <label className="text-sm font-medium">Amount (₹)
              <input name="amount" type="number" min="1" step="1" required className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <label className="text-sm font-medium md:col-span-2">Description
              <input name="description" className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <label className="text-sm font-medium">Frequency
              <select name="mode" required className="mt-2 w-full rounded-lg border px-3 py-2.5">
                <option value="ONE_TIME">One-time</option>
                <option value="PER_CYCLE">Per cycle</option>
                <option value="WEEKLY">Weekly</option>
                <option value="MONTHLY">Monthly</option>
                <option value="YEARLY">Yearly</option>
                <option value="CUSTOM">Custom dates</option>
              </select>
            </label>
            <label className="text-sm font-medium">Interval
              <input name="interval" type="number" min="1" step="1" defaultValue="1" className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <label className="text-sm font-medium">Start date
              <input name="start_date" type="date" className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <label className="text-sm font-medium">End date
              <input name="end_date" type="date" className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <label className="text-sm font-medium md:col-span-2">Custom dates
              <input name="custom_dates" placeholder="2026-10-01, 2026-11-01" className="mt-2 w-full rounded-lg border px-3 py-2.5" />
            </label>
            <div className="md:col-span-3">
              <button className="rounded-lg bg-slate-900 px-4 py-2.5 text-white">Create Expense rule</button>
            </div>
          </form>
        </section>

        <section className="mt-6 rounded-2xl border bg-white shadow-sm overflow-x-auto">
          <div className="border-b px-6 py-4">
            <h2 className="text-lg font-semibold">Expense rules</h2>
          </div>
          <table className="w-full text-left text-sm">
            <thead><tr className="border-b text-slate-500">
              <th className="px-4 py-3">Kuri</th><th className="px-4 py-3">Rule</th><th className="px-4 py-3">Frequency</th><th className="px-4 py-3">Amount</th><th className="px-4 py-3">Active</th>
            </tr></thead>
            <tbody>
              {rules.length ? rules.map((r) => (
                <tr key={r.expense_rule_id} className="border-b last:border-0">
                  <td className="px-4 py-3">{r.kuri_name}</td>
                  <td className="px-4 py-3"><span className="font-medium">{r.name}</span>{r.description ? <span className="block text-xs text-slate-500">{r.description}</span> : null}</td>
                  <td className="px-4 py-3">{r.frequency === "RECURRING" ? r.recurrence_pattern : r.frequency}{r.recurrence_interval ? ` × ${r.recurrence_interval}` : ""}</td>
                  <td className="px-4 py-3">₹{Number(r.amount).toLocaleString("en-IN")}</td>
                  <td className="px-4 py-3">{r.active ? "Yes" : "No"}</td>
                </tr>
              )) : <tr><td className="px-4 py-5 text-slate-600" colSpan={5}>No Expense rules.</td></tr>}
            </tbody>
          </table>
        </section>

        <section className="mt-6 rounded-2xl border bg-white shadow-sm overflow-x-auto">
          <div className="border-b px-6 py-4">
            <h2 className="text-lg font-semibold">Expense obligations</h2>
            <p className="mt-1 text-sm text-slate-600">UNPAID obligations can be paid, waived, or deducted from a matching pending payout.</p>
          </div>
          <table className="w-full text-left text-sm">
            <thead><tr className="border-b text-slate-500">
              <th className="px-4 py-3">Kuri / Rule</th><th className="px-4 py-3">Member</th><th className="px-4 py-3">Cycle</th><th className="px-4 py-3">Amount</th><th className="px-4 py-3">Status</th><th className="px-4 py-3">Action</th>
            </tr></thead>
            <tbody>
              {obligations.length ? obligations.map((o) => {
                const matchingPayouts = payouts.filter(
                  (p) => p.person_id === o.person_id && (o.cycle_number == null || p.cycle_number === o.cycle_number) && p.status === "PENDING"
                );
                return (
                  <tr key={o.expense_obligation_id} className="border-b align-top last:border-0">
                    <td className="px-4 py-3">{rules.find((r) => r.expense_rule_id === o.expense_rule_id)?.kuri_name ?? "Kuri"}<span className="block text-xs text-slate-500">{o.expense_name}</span></td>
                    <td className="px-4 py-3">{o.registered_name}<span className="block text-xs text-slate-500">{o.membership_number}</span></td>
                    <td className="px-4 py-3">{o.cycle_number == null ? "Kuri-wide" : `Cycle ${o.cycle_number}`}</td>
                    <td className="px-4 py-3">₹{Number(o.amount).toLocaleString("en-IN")}</td>
                    <td className="px-4 py-3">{o.status}</td>
                    <td className="px-4 py-3">
                      {o.status === "UNPAID" ? (
                        <div className="min-w-[260px] space-y-2">
                          <form action={markPaid} className="flex gap-2">
                            <input type="hidden" name="obligation_id" value={o.expense_obligation_id} />
                            <input name="reference" placeholder="Payment ref" className="w-28 rounded border px-2 py-1" />
                            <button className="underline">Paid</button>
                          </form>
                          <form action={waive} className="flex gap-2">
                            <input type="hidden" name="obligation_id" value={o.expense_obligation_id} />
                            <input name="reason" required placeholder="Waiver reason" className="w-40 rounded border px-2 py-1" />
                            <button className="underline">Waive</button>
                          </form>
                          {matchingPayouts.length ? (
                            <form action={deduct} className="flex gap-2">
                              <input type="hidden" name="obligation_id" value={o.expense_obligation_id} />
                              <select name="payout_id" required className="w-44 rounded border px-2 py-1">
                                {matchingPayouts.map((p) => <option key={p.payout_id} value={p.payout_id}>Cycle {p.cycle_number} — {p.display_name || p.registered_name}</option>)}
                              </select>
                              <input name="reference" placeholder="Deduction ref" className="w-28 rounded border px-2 py-1" />
                              <button className="underline">Deduct</button>
                            </form>
                          ) : null}
                        </div>
                      ) : <span className="text-slate-500">{o.settlement_reference || "Settled"}</span>}
                    </td>
                  </tr>
                );
              }) : <tr><td className="px-4 py-5 text-slate-600" colSpan={6}>No Expense obligations.</td></tr>}
            </tbody>
          </table>
        </section>
      </div>
    </main>
  );
}
