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

  const { data: organizationId, error } = await supabase.rpc("bootstrap_kuri_admin", {
    target_organization_name: name,
  });

  if (error || !organizationId) {
    console.error("createWorkspace bootstrap failed:", error);
    redirect(
      "/workspace?error=Unable%20to%20create%20workspace.%20Please%20check%20the%20database%20setup."
    );
  }

  if (description) {
    const { error: descriptionError } = await supabase
      .from("organizations")
      .update({ description })
      .eq("id", organizationId);

    if (descriptionError) {
      console.error("createWorkspace description update failed:", descriptionError);
    }
  }

  revalidatePath("/", "layout");
  redirect("/dashboard");
}
