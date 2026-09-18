import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { recordDeathSettlement } from "./actions";

export default async function DeathSettlementPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ exit_id?: string; error?: string }>;
}) {
  const { id } = await params;
  const query = await searchParams;
  const exitId = String(query.exit_id || "").trim();

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");
  if (!exitId) redirect("/dashboard/kuri/" + id + "/exits");

  const { data: membershipId, error: membershipIdError } = await supabase.rpc(
    "get_membership_exit_membership_id_for_admin",
    { target_exit_id: exitId },
  );

  if (membershipIdError || !membershipId) {
    redirect(
      "/dashboard/kuri/" +
        id +
        "/exits?error=" +
        encodeURIComponent(
          membershipIdError?.message || "Death exit not found.",
        ),
    );
  }

  const { data: context, error } = await supabase.rpc(
    "get_death_settlement_context_for_admin",
    { target_membership_id: membershipId },
  );

  const row = context?.[0];

  if (error || !row) {
    redirect(
      "/dashboard/kuri/" +
        id +
        "/exits?error=" +
        encodeURIComponent(error?.message || "Death settlement context not found."),
    );
  }

  const nominees = (context ?? []).filter((n) => n.nominee_id);
  const selectedNominee = row.settled_to_nominee_id
    ? nominees.find((n) => n.nominee_id === row.settled_to_nominee_id)
    : null;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-10 text-slate-900">
      <div className="mx-auto max-w-4xl">
        <div className="flex items-center justify-between gap-4">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">
              Kuri-App
            </p>
            <h1 className="mt-2 text-3xl font-bold">Death Settlement</h1>
            <p className="mt-2 text-sm text-slate-600">
              {row.membership_number} — {row.display_name || row.registered_name}
            </p>
          </div>
          <Link
            href={"/dashboard/kuri/" + id + "/exits"}
            className="rounded-lg border px-4 py-2.5"
          >
            Back to Exits
          </Link>
        </div>

        {query.error ? (
          <div className="mt-5 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-700">
            {query.error}
          </div>
        ) : null}

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Settlement summary</h2>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <div>
              <p className="text-sm text-slate-500">Reason</p>
              <p className="mt-1 font-medium">Death</p>
            </div>
            <div>
              <p className="text-sm text-slate-500">Exit status</p>
              <p className="mt-1 font-medium">{row.exit_status}</p>
            </div>
            <div>
              <p className="text-sm text-slate-500">Refund policy</p>
              <p className="mt-1 font-medium">{row.refund_policy}</p>
            </div>
            <div>
              <p className="text-sm text-slate-500">Refund amount</p>
              <p className="mt-1 font-medium">
                ₹{Number(row.refund_amount).toLocaleString("en-IN")}
              </p>
            </div>
            <div>
              <p className="text-sm text-slate-500">Amount contributed</p>
              <p className="mt-1 font-medium">
                ₹{Number(row.amount_contributed).toLocaleString("en-IN")}
              </p>
            </div>
          </div>
        </section>

        <section className="mt-6 rounded-2xl border bg-white p-6 shadow-sm">
          <h2 className="text-lg font-semibold">Nominee</h2>

          {selectedNominee ? (
            <div className="mt-4 rounded-xl bg-slate-50 p-4 text-sm">
              <p className="font-medium">
                {selectedNominee.nominee_name}
                {selectedNominee.nominee_relationship
                  ? " — " + selectedNominee.nominee_relationship
                  : ""}
              </p>
              <p className="mt-2">
                <span className="font-medium">Phone:</span>{" "}
                {selectedNominee.nominee_phone || "—"}
              </p>
              <p className="mt-1">
                <span className="font-medium">Address:</span>{" "}
                {selectedNominee.nominee_address || "—"}
              </p>
              <p className="mt-3 text-slate-600">
                Settlement recorded to this nominee.
              </p>
              {row.settlement_notes ? (
                <p className="mt-2 text-slate-600">
                  <span className="font-medium">Notes:</span>{" "}
                  {row.settlement_notes}
                </p>
              ) : null}
            </div>
          ) : nominees.length ? (
            <form action={recordDeathSettlement} className="mt-5 space-y-5">
              <input type="hidden" name="kuri_id" value={id} />
              <input type="hidden" name="exit_id" value={exitId} />
              <label className="block text-sm font-medium">
                Select nominee
                <select
                  name="nominee_id"
                  required
                  className="mt-2 w-full rounded-lg border px-3 py-2.5"
                  defaultValue={nominees[0].nominee_id}
                >
                  {nominees.map((n) => (
                    <option key={n.nominee_id} value={n.nominee_id}>
                      {n.nominee_name}
                      {n.nominee_relationship ? " — " + n.nominee_relationship : ""}
                    </option>
                  ))}
                </select>
              </label>

              <div className="rounded-xl bg-slate-50 p-4 text-sm">
                <p>
                  <span className="font-medium">Phone:</span>{" "}
                  {nominees[0].nominee_phone || "—"}
                </p>
                <p className="mt-1">
                  <span className="font-medium">Address:</span>{" "}
                  {nominees[0].nominee_address || "—"}
                </p>
              </div>

              <label className="block text-sm font-medium">
                Settlement notes
                <textarea
                  name="notes"
                  rows={4}
                  className="mt-2 w-full rounded-lg border px-3 py-2.5"
                />
              </label>

              {row.exit_status === "APPROVED" ? (
                <button className="rounded-lg bg-slate-900 px-4 py-2.5 text-white">
                  Settle to nominee
                </button>
              ) : (
                <p className="text-sm text-slate-600">
                  This death case is already {String(row.exit_status).toLowerCase()}.
                </p>
              )}
            </form>
          ) : (
            <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
              No nominee is registered for this person. Add a nominee on the person profile before settling this death case.
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
