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

  const { data: person, error: personError } = await supabase
    .from("people")
    .insert({
      registered_name: registeredName,
      display_name: displayName || null,
      address: address || null,
      notes: notes || null,
    })
    .select("id")
    .single();

  if (personError || !person) {
    console.error("createPerson insert failed:", personError);
    redirect(
      `/dashboard/people/new?error=${encodeURIComponent(
        `Unable to create person: ${personError?.message ?? "Unknown error"}`,
      )}`,
    );
  }

  if (phone) {
    const { error } = await supabase.from("person_phones").insert({
      person_id: person.id,
      phone_number: phone,
      is_primary: true,
    });
    if (error) {
      console.error("createPerson phone insert failed:", error);
    }
  }

  if (email) {
    const { error } = await supabase.from("person_emails").insert({
      person_id: person.id,
      email,
      is_primary: true,
    });
    if (error) {
      console.error("createPerson email insert failed:", error);
    }
  }

  revalidatePath("/dashboard");
  revalidatePath("/dashboard/people");
  redirect(`/dashboard/people/${person.id}`);
}
