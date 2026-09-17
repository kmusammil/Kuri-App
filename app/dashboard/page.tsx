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
      <div className="mx-auto max-w-5xl">
        <div className="flex items-center justify-between rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
          <div>
            <p className="text-sm text-slate-500">Kuri-App</p>
            <h1 className="mt-1 text-2xl font-bold">Dashboard</h1>
          </div>
          <form action={signOut}>
            <button
              type="submit"
              className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-medium hover:bg-slate-50"
            >
              Sign out
            </button>
          </form>
        </div>

        <section className="mt-6 grid gap-4 md:grid-cols-3">
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Signed-in account</p>
            <p className="mt-2 break-all font-medium">{user.email ?? "Email unavailable"}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Kuri management</p>
            <p className="mt-2 font-medium">Ready for setup</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-sm text-slate-500">Next layer</p>
            <p className="mt-2 font-medium">Organization administration</p>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Application shell</h2>
          <p className="mt-2 text-sm text-slate-600">
            Authentication is working. Kuri-App can now move into the real
            organization, member, payment, draw, winner, and payout workflows.
          </p>
        </section>
      </div>
    </main>
  );
}
