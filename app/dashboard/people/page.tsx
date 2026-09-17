import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function PeoplePage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: contextRows, error: contextError } = await supabase.rpc(
    "current_user_membership",
  );
  if (contextError) {
    console.error("People workspace lookup failed:", contextError);
    redirect("/dashboard?error=Unable%20to%20verify%20workspace%20membership.");
  }

  const membership = contextRows?.[0];
  if (!membership?.organization_id) redirect("/workspace");
  if (membership.role !== "MAIN_ADMIN" && membership.role !== "ADMIN") {
    redirect(
      "/dashboard?error=You%20do%20not%20have%20permission%20to%20view%20people.",
    );
  }

  const { data: people, error } = await supabase.rpc("list_people_for_admin");

  if (error) {
    console.error("People admin RPC failed:", error);
    const message = encodeURIComponent(`Unable to load people: ${error.message}`);
    redirect(`/dashboard?error=${message}`);
  }

  const params = await searchParams;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-6xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">People</h1>
            <p className="mt-2 text-sm text-slate-600">Manage registered people and their contact details.</p>
          </div>
          <div className="flex gap-3">
            <Link href="/dashboard" className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium">Dashboard</Link>
            <Link href="/dashboard/people/new" className="rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white">Add person</Link>
          </div>
        </div>

        {params.error ? (
          <div className="mt-6 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
            {params.error}
          </div>
        ) : null}

        {people?.length ? (
          <div className="mt-6 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
            <div className="grid grid-cols-[1fr_1fr_auto] gap-4 border-b border-slate-200 px-5 py-3 text-xs font-semibold uppercase tracking-wide text-slate-500">
              <div>Registered name</div><div>Display name</div><div></div>
            </div>
            {people.map((person: { id: string; registered_name: string; display_name: string | null; created_at: string }) => (
              <Link key={person.id} href={`/dashboard/people/${person.id}`} className="grid grid-cols-[1fr_1fr_auto] items-center gap-4 border-b border-slate-100 px-5 py-4 last:border-b-0 hover:bg-slate-50">
                <div><p className="font-medium">{person.registered_name}</p><p className="mt-1 text-xs text-slate-500">Added {new Date(person.created_at).toLocaleDateString("en-IN")}</p></div>
                <div className="text-sm text-slate-600">{person.display_name ?? "—"}</div>
                <div className="text-sm font-medium underline">View</div>
              </Link>
            ))}
          </div>
        ) : (
          <div className="mt-6 rounded-2xl border border-dashed border-slate-300 bg-white p-10 text-center">
            <h2 className="text-lg font-semibold">No people yet</h2>
            <p className="mt-2 text-sm text-slate-600">Add the first person before creating Kuri memberships.</p>
            <Link href="/dashboard/people/new" className="mt-5 inline-block rounded-lg bg-slate-900 px-4 py-2.5 text-sm font-medium text-white">Add first person</Link>
          </div>
        )}
      </div>
    </main>
  );
}
