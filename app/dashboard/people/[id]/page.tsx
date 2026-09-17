import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export default async function PersonDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: contextRows, error: contextError } = await supabase.rpc("current_user_membership");
  if (contextError) redirect("/dashboard?error=Unable%20to%20verify%20workspace%20membership.");
  const membership = contextRows?.[0];
  if (!membership?.organization_id) redirect("/workspace");
  if (membership.role !== "MAIN_ADMIN" && membership.role !== "ADMIN") {
    redirect("/dashboard?error=You%20do%20not%20have%20permission%20to%20view%20people.");
  }

  const { data: rows, error: personError } = await supabase.rpc("get_person_for_admin", {
    target_person_id: id,
  });

  if (personError) {
    console.error("Person lookup failed:", personError);
    redirect("/dashboard/people?error=Unable%20to%20load%20person.");
  }

  const person = rows?.[0];
  if (!person) notFound();

  const phones = Array.isArray(person.phones) ? person.phones : [];
  const emails = Array.isArray(person.emails) ? person.emails : [];

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-4xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Kuri-App</p>
            <h1 className="mt-2 text-3xl font-bold tracking-tight">{person.display_name ?? person.registered_name}</h1>
            {person.display_name ? <p className="mt-1 text-sm text-slate-500">Registered name: {person.registered_name}</p> : null}
          </div>
          <Link href="/dashboard/people" className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-medium">All People</Link>
        </div>

        <div className="mt-6 grid gap-6 md:grid-cols-2">
          <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Contact</h2>
            <div className="mt-4 space-y-3 text-sm">
              <div><p className="text-slate-500">Phone</p><p className="mt-1 font-medium">{phones.map((phone: { phone_number: string }) => phone.phone_number).join(", ") || "—"}</p></div>
              <div><p className="text-slate-500">Email</p><p className="mt-1 break-all font-medium">{emails.map((email: { email: string }) => email.email).join(", ") || "—"}</p></div>
              <div><p className="text-slate-500">Address</p><p className="mt-1 whitespace-pre-wrap">{person.address || "—"}</p></div>
            </div>
          </section>
          <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-lg font-semibold">Notes</h2>
            <p className="mt-4 whitespace-pre-wrap text-sm text-slate-600">{person.notes || "No notes."}</p>
          </section>
        </div>

        <section className="mt-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Memberships</h2>
          <p className="mt-2 text-sm text-slate-600">Kuri membership records will appear here as memberships are added.</p>
        </section>
      </div>
    </main>
  );
}
