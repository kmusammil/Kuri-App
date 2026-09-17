import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createMembership } from "../actions";

export default async function NewMembershipPage({
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
    redirect(
      "/dashboard?error=Unable%20to%20verify%20workspace%20membership.",
    );
  }

  const context = contextRows?.[0];
  if (!context?.organization_id) redirect("/workspace");
  if (context.role !== "MAIN_ADMIN" && context.role !== "ADMIN") {
    redirect(
      "/dashboard?error=You%20do%20not%20have%20permission%20to%20add%20memberships.",
    );
  }

  const { data: kuriRows, error: kuriError } = await supabase.rpc(
    "get_kuri_for_admin",
    { target_kuri_id: id },
  );
  if (kuriError) {
    redirect("/dashboard?error=Unable%20to%20load%20the%20Kuri.");
  }
  const kuri = kuriRows?.[0];
  if (!kuri) redirect("/dashboard/kuri");

  const { data: peopleRows, error: peopleError } = await supabase.rpc(
    "list_people_for_admin",
  );
  if (peopleError) {
    redirect("/dashboard/people?error=Unable%20to%20load%20people.");
  }

  const paramsData = await searchParams;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-3xl">
        <div className="mb-6 flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">
              Kuri-App
            </p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">
              Add membership
            </h1>
            <p className="mt-2 text-sm text-slate-600">
              Add a person to {kuri.name} with a unique membership number.
            </p>
          </div>
          <Link
            href={`/dashboard/kuri/${id}`}
            className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium"
          >
            Back to Kuri
          </Link>
        </div>

        {paramsData.error ? (
          <div className="mb-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
            {paramsData.error}
          </div>
        ) : null}

        <form action={createMembership} className="space-y-6">
          <input type="hidden" name="kuri_id" value={id} />

          <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Membership details</h2>
            <div className="mt-5 space-y-4">
              <div>
                <label htmlFor="person_id" className="block text-sm font-medium">
                  Person
                </label>
                <select
                  id="person_id"
                  name="person_id"
                  required
                  defaultValue=""
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"
                >
                  <option value="" disabled>
                    Select a person
                  </option>
                  {peopleRows?.map((person) => (
                    <option key={person.id} value={person.id}>
                      {person.display_name
                        ? `${person.display_name} — ${person.registered_name}`
                        : person.registered_name}
                    </option>
                  ))}
                </select>
              </div>

              <div>
                <label
                  htmlFor="membership_number"
                  className="block text-sm font-medium"
                >
                  Membership number
                </label>
                <input
                  id="membership_number"
                  name="membership_number"
                  required
                  placeholder="001"
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"
                />
                <p className="mt-1 text-xs text-slate-500">
                  Must be unique within this Kuri.
                </p>
              </div>
            </div>
          </section>

          <div className="flex items-center justify-end gap-3">
            <Link
              href={`/dashboard/kuri/${id}`}
              className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium"
            >
              Cancel
            </Link>
            <button
              type="submit"
              className="rounded-lg bg-slate-900 px-5 py-2.5 text-sm font-medium text-white"
            >
              Add membership
            </button>
          </div>
        </form>
      </div>
    </main>
  );
}
