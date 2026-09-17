import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import Link from "next/link";

export default async function SetupPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id, role, organizations(id, name, description)")
    .eq("user_id", user.id);

  const workspaces = (memberships ?? []).map((membership) => ({
    id: membership.organization_id,
    role: membership.role,
    organization: Array.isArray(membership.organizations)
      ? membership.organizations[0]
      : membership.organizations,
  }));

  if (workspaces.length > 0) redirect("/dashboard");

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-4xl">
        <header className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight">Get started</h1>
          <p className="mt-2 text-sm text-slate-600">
            Set up your workspace before creating Kuris, members, payments, or draws.
          </p>
        </header>

        <section className="mt-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">You are ready to create a workspace</h2>
          <p className="mt-2 text-sm text-slate-600">
            A workspace can represent you as an independent Kuri operator or a formal organization.
            You can use whichever name is meaningful for the people you manage.
          </p>

          <div className="mt-6 grid gap-4 md:grid-cols-2">
            <div className="rounded-xl border border-slate-200 p-5">
              <h3 className="font-semibold">Independent operator</h3>
              <p className="mt-2 text-sm text-slate-600">
                For one person managing a Kuri operation independently.
              </p>
            </div>
            <div className="rounded-xl border border-slate-200 p-5">
              <h3 className="font-semibold">Organization</h3>
              <p className="mt-2 text-sm text-slate-600">
                For an association, group, institution, business, or other formal setup.
              </p>
            </div>
          </div>

          <div className="mt-6 flex flex-wrap gap-3">
            <Link
              href="/workspace"
              className="rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white hover:bg-slate-800"
            >
              Create workspace
            </Link>
            <Link
              href="/dashboard"
              className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium hover:bg-slate-50"
            >
              Back to dashboard
            </Link>
          </div>
        </section>
      </div>
    </main>
  );
}
