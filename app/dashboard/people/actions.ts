"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function normalizePersonName(value: string) {
  return value.trim().normalize("NFC");
}

function isValidPersonName(value: string) {
  const normalized = normalizePersonName(value);
  return (
    normalized.length > 0 &&
    Array.from(normalized).length <= 200 &&
    /\\p{L}/u.test(normalized) &&
    !/\\p{Cc}/u.test(normalized)
  );
}

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

  const registeredName = normalizePersonName(
    String(formData.get("registered_name") ?? ""),
  );
  const displayName = normalizePersonName(
    String(formData.get("display_name") ?? ""),
  );
  const address = String(formData.get("address") ?? "").trim();
  const phone = String(formData.get("phone") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim();
  const notes = String(formData.get("notes") ?? "").trim();

  if (!isValidPersonName(registeredName)) {
    redirect(
      "/dashboard/people/new?error=Enter%20a%20valid%20Unicode%20name%20(1-200%20characters).",
    );
  }

  if (displayName && !isValidPersonName(displayName)) {
    redirect(
      "/dashboard/people/new?error=Enter%20a%20valid%20display%20name%20(1-200%20characters).",
    );
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
