import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { signOut } from "../login/actions";

export default async function DashboardPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <header className="flex flex-col gap-4 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">Dashboard</h1>
            <p className="mt-3 flex flex-wrap gap-4"><a href="/dashboard/payments" className="text-sm font-medium underline">Open Payments</a><a href="/dashboard/expenses" className="text-sm font-medium underline">Open Expenses</a></p>
            <p className="mt-2 text-sm text-slate-600">Your Kuri administration workspace.</p>
          </div>
          <form action={signOut}>
            <button
              type="submit"
              className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium hover:bg-slate-50"
            >
              Sign out
            </button>
          </form>
        </header>

        <section className="mt-6 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          {[
            ["Kuris", "0", "Create and manage Kuri schemes"],
            ["Members", "0", "People and their memberships"],
            ["Payments", "0", "Track current payment activity"],
            ["Draws", "0", "Prepare and finalize monthly draws"],
          ].map(([label, value, description]) => (
            <div key={label} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
              <p className="text-sm text-slate-500">{label}</p>
              <p className="mt-2 text-3xl font-bold">{value}</p>
              <p className="mt-2 text-sm text-slate-600">{description}</p>
            </div>
          ))}
        </section>

        <section className="mt-6 grid gap-6 lg:grid-cols-[1.4fr_1fr]">
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <div className="flex items-center justify-between gap-4">
              <div>
                <h2 className="text-lg font-semibold">Get started</h2>
                <p className="mt-1 text-sm text-slate-600">Set up the organization before creating Kuri schemes.</p>
              </div>
            </div>

            <div className="mt-5 space-y-3">
              <div className="rounded-xl border border-slate-200 p-4">
                <p className="font-medium">1. Organization</p>
                <p className="mt-1 text-sm text-slate-600">Create the organization that will own your Kuri records.</p>
              </div>
              <div className="rounded-xl border border-slate-200 p-4">
                <p className="font-medium">2. Members</p>
                <p className="mt-1 text-sm text-slate-600">Add people using their registered name and optional display name.</p>
              </div>
              <div className="rounded-xl border border-slate-200 p-4">
                <p className="font-medium">3. Kuri schemes</p>
                <p className="mt-1 text-sm text-slate-600">Define memberships, cycles, installments, prizes, and rules.</p>
              </div>
            </div>
          </div>

          <aside className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Account</h2>
            <p className="mt-4 text-sm text-slate-500">Signed-in email</p>
            <p className="mt-1 break-all font-medium">{user.email ?? "Email unavailable"}</p>
            <div className="mt-6 rounded-xl bg-slate-50 p-4">
              <p className="text-sm font-medium">Authentication status</p>
              <p className="mt-1 text-sm text-slate-600">Authenticated with Supabase.</p>
            </div>
          </aside>
        </section>
      </div>
    </main>
  );
}
