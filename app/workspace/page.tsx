import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createWorkspace } from "./actions";

export default async function WorkspacePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id, role, organizations(id, name, description)")
    .eq("user_id", user.id);

  const organizations = (memberships ?? []).map((membership) => ({
    id: membership.organization_id,
    role: membership.role,
    organization: Array.isArray(membership.organizations)
      ? membership.organizations[0]
      : membership.organizations,
  }));

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-4xl">
        <header className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight">Workspace setup</h1>
          <p className="mt-2 text-sm text-slate-600">
            A workspace can represent an independent Kuri operator or a formal organization.
          </p>
        </header>

        <section className="mt-6 grid gap-6 lg:grid-cols-2">
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Your workspaces</h2>
            {organizations.length === 0 ? (
              <p className="mt-3 text-sm text-slate-600">No workspace has been set up yet.</p>
            ) : (
              <div className="mt-4 space-y-3">
                {organizations.map(({ id, role, organization }) => (
                  <div key={id} className="rounded-xl border border-slate-200 p-4">
                    <p className="font-medium">{organization?.name ?? "Unnamed workspace"}</p>
                    <p className="mt-1 text-sm text-slate-500">Role: {role}</p>
                    {organization?.description ? (
                      <p className="mt-2 text-sm text-slate-600">{organization.description}</p>
                    ) : null}
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Create a workspace</h2>
            <p className="mt-2 text-sm text-slate-600">
              Use this for a personal Kuri operation or for an institution, group, or business.
            </p>

            <form action={createWorkspace} className="mt-5 space-y-4">
              <div>
                <label htmlFor="name" className="block text-sm font-medium text-slate-700">
                  Workspace name
                </label>
                <input
                  id="name"
                  name="name"
                  required
                  placeholder="e.g. My Kuri or Noor Kuri Association"
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-slate-500"
                />
              </div>

              <div>
                <label htmlFor="description" className="block text-sm font-medium text-slate-700">
                  Description <span className="font-normal text-slate-400">(optional)</span>
                </label>
                <textarea
                  id="description"
                  name="description"
                  rows={3}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm outline-none focus:border-slate-500"
                />
              </div>

              <button
                type="submit"
                className="w-full rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white hover:bg-slate-800"
              >
                Create workspace
              </button>
            </form>
          </div>
        </section>
      </div>
    </main>
  );
}
