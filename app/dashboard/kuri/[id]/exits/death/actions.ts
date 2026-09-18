"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function loadDeathContext() {
  const s = await createClient();
  return s;
}

export async function recordDeathSettlement(formData: FormData) {
  const s = await createClient();
  const {
    data: { user },
  } = await s.auth.getUser();
  if (!user) redirect("/login");

  const kuriId = String(formData.get("kuri_id") || "").trim();
  const exitId = String(formData.get("exit_id") || "").trim();
  const nomineeId = String(formData.get("nominee_id") || "").trim();
  const notes = String(formData.get("notes") || "").trim() || null;

  const { data, error } = await s.rpc("record_death_settlement_for_admin", {
    target_exit_id: exitId,
    target_nominee_id: nomineeId || null,
    settlement_notes: notes,
  });

  if (error) {
    redirect(
      "/dashboard/kuri/" +
        kuriId +
        "/exits/death?exit_id=" +
        encodeURIComponent(exitId) +
        "&error=" +
        encodeURIComponent(error.message),
    );
  }

  void data;
  revalidatePath("/dashboard/kuri/" + kuriId + "/exits");
  revalidatePath("/dashboard/kuri/" + kuriId + "/exits/death");
  redirect("/dashboard/kuri/" + kuriId + "/exits/death?exit_id=" + encodeURIComponent(exitId));
}
