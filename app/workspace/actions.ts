"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function createWorkspace(formData: FormData) {
  const name = String(formData.get("name") ?? "").trim();
  const description = String(formData.get("description") ?? "").trim();

  if (!name) {
    redirect("/workspace?error=Workspace%20name%20is%20required.");
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: existingMembership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1)
    .maybeSingle();

  if (existingMembership?.organization_id) {
    redirect("/dashboard");
  }

  const { data: organization, error } = await supabase
    .from("organizations")
    .insert({ name, description: description || null })
    .select("id")
    .single();

  if (error || !organization) {
    redirect("/workspace?error=Unable%20to%20create%20workspace.");
  }

  const { error: membershipError } = await supabase
    .from("organization_users")
    .insert({
      organization_id: organization.id,
      user_id: user.id,
      role: "MAIN_ADMIN",
    });

  if (membershipError) {
    await supabase.from("organizations").delete().eq("id", organization.id);
    redirect("/workspace?error=Unable%20to%20assign%20administrator%20role.");
  }

  revalidatePath("/", "layout");
  redirect("/dashboard");
}
