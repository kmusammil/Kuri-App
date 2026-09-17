"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function createPerson(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: contextRows, error: contextError } = await supabase.rpc(
    "current_user_membership",
  );
  if (contextError) {
    console.error("createPerson workspace lookup failed:", contextError);
    redirect("/dashboard?error=Unable%20to%20verify%20workspace%20membership.");
  }

  const membership = contextRows?.[0];
  if (!membership?.organization_id) redirect("/workspace");
  if (membership.role !== "MAIN_ADMIN" && membership.role !== "ADMIN") {
    redirect("/dashboard?error=You%20do%20not%20have%20permission%20to%20add%20people.");
  }

  const registeredName = String(formData.get("registered_name") ?? "").trim();
  const displayName = String(formData.get("display_name") ?? "").trim();
  const address = String(formData.get("address") ?? "").trim();
  const phone = String(formData.get("phone") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim();
  const notes = String(formData.get("notes") ?? "").trim();

  if (!registeredName) {
    redirect("/dashboard/people/new?error=Registered%20name%20is%20required.");
  }

  const { data: personId, error: personError } = await supabase.rpc(
    "create_person_for_admin",
    {
      registered_name: registeredName,
      display_name: displayName || null,
      address: address || null,
      notes: notes || null,
      phone: phone || null,
      email: email || null,
    },
  );

  if (personError || !personId) {
    console.error("createPerson RPC failed:", personError);
    redirect(
      `/dashboard/people/new?error=${encodeURIComponent(
        `Unable to create person: ${personError?.message ?? "Unknown error"}`,
      )}`,
    );
  }

  revalidatePath("/dashboard");
  revalidatePath("/dashboard/people");
  redirect(`/dashboard/people/${personId}`);
}
